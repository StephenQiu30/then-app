import CryptoKit
import Foundation
import GRDB

/// Synchronous I/O owned exclusively by GRDBWardrobeRepository's actor and its existing pool.
nonisolated struct WardrobePhotoPersistence {
  let pool: DatabasePool
  let directory: URL
  private var root: URL { directory.appendingPathComponent("WardrobeMedia", isDirectory: true) }

  func save(_ input: WardrobePhotoWrite, itemID: UUID, expectedRevision: Int?,
            edit: WardrobeItemPhotoEdit? = nil) throws -> WardrobePhotoSaveResult {
    try Task.checkCancellation()
    guard expectedRevision != nil || edit != nil else { throw WardrobeError.conflict }
    let record = WardrobePhotoRecord(input, itemID: expectedRevision == nil ? nil : itemID)
    if let existing = try pool.read({ db in try WardrobePhotoRecord.fetchOne(db, key: input.id.uuidString) }) {
      guard existing.state == "ready", existing.itemID == itemID.uuidString,
            existing.matches(record) else { throw WardrobeError.conflict }
      if let edit {
        let item = try pool.read { db in
          guard let record = try WardrobeRecord.fetchOne(db, key: itemID.uuidString) else { throw WardrobeError.notFound }
          return try record.domain()
        }
        guard item.input == edit.input, item.source == edit.source else { throw WardrobeError.conflict }
      }
      // Idempotency never reports unusable or modified bytes as a successfully stored image.
      guard try read(itemID: itemID, purpose: .normalized, maximumBytes: input.normalized.bytes.count)?.bytes == input.normalized.bytes,
            try read(itemID: itemID, purpose: .thumbnail, maximumBytes: input.thumbnail.bytes.count)?.bytes == input.thumbnail.bytes
      else { throw WardrobeError.storageUnavailable }
      let revision = try pool.read { db in try Self.revision(db, itemID) }
      return WardrobePhotoSaveResult(metadata: try existing.metadata(), itemRevision: revision,
                                     cleanupPending: try hasPendingCleanup())
    }
    // A newly written intent must not claim files that already existed before this attempt.
    try validateRootIfPresent()
    guard try Self.attributes(folder(input.id, staging: true)) == nil,
          try Self.attributes(folder(input.id)) == nil else { throw WardrobeError.storageUnavailable }
    try pool.write { db in
      try Self.checkTarget(db, itemID, expectedRevision)
      let collisions = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM wardrobe_photos WHERE id IN (?,?) OR thumbnailID IN (?,?))
        """, arguments: [input.id.uuidString, input.thumbnailID.uuidString,
                         input.id.uuidString, input.thumbnailID.uuidString]) ?? false
      guard !collisions else { throw WardrobeError.conflict }
      try record.insert(db)
    }
    do {
      try ensureRoot()
      let staging = folder(input.id, staging: true)
      guard try Self.attributes(staging) == nil, try Self.attributes(folder(input.id)) == nil else {
        throw WardrobeError.storageUnavailable
      }
      try Self.ensureDirectory(staging, create: true)
      try Self.write(input.normalized.bytes, to: staging.appendingPathComponent("normalized.image"))
      try Task.checkCancellation()
      try Self.write(input.thumbnail.bytes, to: staging.appendingPathComponent("thumbnail.image"))
      try Task.checkCancellation()
      try FileManager.default.moveItem(at: staging, to: folder(input.id))
      // Validate the actual files, not only the data that was handed to the writer.
      guard try readBytes(record, purpose: .normalized, maximumBytes: input.normalized.bytes.count) == input.normalized.bytes,
            try readBytes(record, purpose: .thumbnail, maximumBytes: input.thumbnail.bytes.count) == input.thumbnail.bytes
      else { throw WardrobeError.storageUnavailable }
      try Task.checkCancellation()
      try pool.write { db in
        try Self.checkTarget(db, itemID, expectedRevision)
        if let edit { try WardrobeRecord.applyPhotoEdit(edit, db: db) }
        try Self.markForDeletion(db, itemID: itemID, readyOnly: true)
        try db.execute(sql: "UPDATE wardrobe_photos SET state = 'ready', itemID = ? WHERE id = ? AND state = 'importing'",
                       arguments: [itemID.uuidString, input.id.uuidString])
        guard db.changesCount == 1 else { throw WardrobeError.conflict }
        if edit == nil { try Self.advanceRevision(db, itemID) }
      }
    } catch {
      let original = error
      // Only this attempt is withdrawn. The old ready photo has not been changed if commit failed.
      do { try cleanGroup(input.id) }
      catch { throw WardrobeError.deletionCleanupPending }
      throw original
    }
    // Commit is final even if cancellation/cleanup follows it. Report the two facts separately.
    var cleanupPending = false
    do { try recover() } catch { cleanupPending = true }
    let revision = try pool.read { db in try Self.revision(db, itemID) }
    return WardrobePhotoSaveResult(metadata: try record.metadata(), itemRevision: revision,
                                   cleanupPending: cleanupPending)
  }

  func read(itemID: UUID, purpose: WardrobePhotoPurpose, maximumBytes: Int) throws -> WardrobePhotoRead? {
    guard maximumBytes > 0 else { throw WardrobePhotoInputError.invalidImage }
    guard let record = try pool.read({ db in
      try WardrobePhotoRecord.fetchOne(db, sql: "SELECT * FROM wardrobe_photos WHERE itemID = ? AND state = 'ready'",
                                      arguments: [itemID.uuidString])
    }), let bytes = try readBytes(record, purpose: purpose, maximumBytes: maximumBytes) else { return nil }
    return WardrobePhotoRead(metadata: try record.metadata(), purpose: purpose, bytes: bytes)
  }

  func metadata(itemID: UUID) throws -> WardrobePhotoMetadata? {
    try pool.read { db in
      try WardrobePhotoRecord.fetchOne(db, sql: "SELECT * FROM wardrobe_photos WHERE itemID = ? AND state = 'ready'",
                                      arguments: [itemID.uuidString])?.metadata()
    }
  }

  func remove(id: UUID, itemID: UUID, expectedRevision: Int) throws {
    try pool.write { db in
      guard let record = try WardrobePhotoRecord.fetchOne(db, key: id.uuidString) else { return }
      guard record.itemID == itemID.uuidString || (record.itemID == nil && record.state == "deleting") else {
        throw WardrobeError.conflict
      }
      if record.state == "ready" {
        try Self.checkRevision(db, itemID, expectedRevision)
        try Self.advanceRevision(db, itemID)
      }
      try db.execute(sql: "UPDATE wardrobe_photos SET state = 'deleting' WHERE id = ?", arguments: [id.uuidString])
    }
    do { try cleanGroup(id); try checkpoint() }
    catch { throw WardrobeError.deletionCleanupPending }
  }

  static func markForDeletion(_ db: Database, itemID: UUID, readyOnly: Bool = false) throws {
    let condition = readyOnly ? " AND state = 'ready'" : ""
    try db.execute(sql: "UPDATE wardrobe_photos SET state = 'deleting' WHERE itemID = ?" + condition,
                   arguments: [itemID.uuidString])
  }

  func hasPendingCleanup() throws -> Bool {
    try pool.read { db in
      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wardrobe_photos WHERE state != 'ready')") ?? false
    }
  }

  func recover() throws {
    let ids = try pool.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM wardrobe_photos WHERE state != 'ready'")
    }
    var failed = false
    for value in ids {
      guard let id = UUID(uuidString: value), id.uuidString == value else { failed = true; continue }
      do { try cleanGroup(id) } catch { failed = true }
    }
    // Do not lose a failed cleanup while allowing unrelated groups to finish.
    if failed { throw WardrobeError.deletionCleanupPending }
    try checkpoint()
  }

  private func cleanGroup(_ id: UUID) throws {
    guard try pool.read({ db in
      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wardrobe_photos WHERE id = ? AND state != 'ready')",
                        arguments: [id.uuidString]) ?? false
    }) else { return }
    try validateRootIfPresent()
    for staging in [true, false] {
      let url = folder(id, staging: staging)
      guard try Self.attributes(url) != nil else { continue }
      try Self.ensureDirectory(url, create: false)
      let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
      for child in children {
        guard ["normalized.image", "thumbnail.image"].contains(child.lastPathComponent) else {
          throw WardrobeError.storageUnavailable
        }
        try Self.regular(child)
      }
      try FileManager.default.removeItem(at: url)
    }
    try pool.write { db in
      try db.execute(sql: "DELETE FROM wardrobe_photos WHERE id = ? AND state != 'ready'", arguments: [id.uuidString])
    }
  }

  private func readBytes(_ record: WardrobePhotoRecord, purpose: WardrobePhotoPurpose, maximumBytes: Int) throws -> Data? {
    let metadata = try record.metadata()
    let variant = purpose == .normalized ? metadata.normalized : metadata.thumbnail
    guard variant.byteCount <= maximumBytes else { return nil }
    try validateRootIfPresent()
    let dir = folder(metadata.id)
    guard try Self.attributes(dir) != nil else { return nil }
    try Self.ensureDirectory(dir, create: false)
    let url = dir.appendingPathComponent(purpose.rawValue + ".image")
    guard try Self.attributes(url) != nil else { return nil }
    try Self.regular(url)
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    guard size?.intValue == variant.byteCount else { return nil }
    // Bounded reads remain bounded if a file changes between stat and opening it.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let bytes = try handle.read(upToCount: variant.byteCount), bytes.count == variant.byteCount,
          (try handle.read(upToCount: 1) ?? Data()).isEmpty,
          Self.hash(bytes) == variant.sha256 else { return nil }
    return bytes
  }

  private func ensureRoot() throws {
    try Self.ensureDirectory(directory, create: false)
    try Self.ensureDirectory(root, create: true)
  }
  private func validateRootIfPresent() throws {
    try Self.ensureDirectory(directory, create: false)
    if try Self.attributes(root) != nil { try Self.ensureDirectory(root, create: false) }
  }
  private func folder(_ id: UUID, staging: Bool = false) -> URL {
    root.appendingPathComponent((staging ? "staging-" : "photo-") + id.uuidString, isDirectory: true)
  }
  private func checkpoint() throws {
    _ = try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
  }
  private static func revision(_ db: Database, _ itemID: UUID) throws -> Int {
    guard let value = try Int.fetchOne(db, sql: "SELECT revision FROM wardrobe_items WHERE id = ?", arguments: [itemID.uuidString]) else {
      throw WardrobeError.notFound
    }
    return value
  }
  private static func checkRevision(_ db: Database, _ itemID: UUID, _ expected: Int) throws {
    guard expected > 0, expected < Int.max, try revision(db, itemID) == expected else { throw WardrobeError.conflict }
  }
  private static func checkTarget(_ db: Database, _ itemID: UUID, _ expected: Int?) throws {
    if let expected { try checkRevision(db, itemID, expected) }
    else {
      guard try !WardrobeRecord.exists(db, key: itemID.uuidString) else { throw WardrobeError.conflict }
    }
  }
  private static func advanceRevision(_ db: Database, _ itemID: UUID) throws {
    try db.execute(sql: "UPDATE wardrobe_items SET revision = revision + 1, updatedAt = max(updatedAt, ?) WHERE id = ?",
                   arguments: [Date().timeIntervalSince1970, itemID.uuidString])
  }
  static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
    do { return try FileManager.default.attributesOfItem(atPath: url.path) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
  }
  static func ensureDirectory(_ url: URL, create: Bool) throws {
    guard url.isFileURL else { throw WardrobeError.storageUnavailable }
    if try attributes(url) == nil, create {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
        attributes: [.protectionKey: FileProtectionType.complete])
    }
    guard try attributes(url)?[.type] as? FileAttributeType == .typeDirectory else { throw WardrobeError.storageUnavailable }
    try protect(url)
  }
  static func regular(_ url: URL) throws {
    let attrs = try attributes(url)
    guard attrs?[.type] as? FileAttributeType == .typeRegular,
          (attrs?[.referenceCount] as? NSNumber)?.intValue == 1 else { throw WardrobeError.storageUnavailable }
  }
  static func protect(_ url: URL) throws {
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    var mutable = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutable.setResourceValues(values)
  }
  private static func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
    try protect(url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }
}

private nonisolated struct WardrobePhotoRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "wardrobe_photos"
  let id: String
  let itemID: String?
  let thumbnailID: String
  let state: String
  let version: Int
  let quality: String
  let normalizedFormat: String
  let normalizedWidth: Int
  let normalizedHeight: Int
  let normalizedByteCount: Int
  let normalizedHash: String
  let normalizedPath: String
  let thumbnailFormat: String
  let thumbnailWidth: Int
  let thumbnailHeight: Int
  let thumbnailByteCount: Int
  let thumbnailHash: String
  let thumbnailPath: String
  let createdAt: Double

  init(_ input: WardrobePhotoWrite, itemID: UUID?) {
    id = input.id.uuidString
    self.itemID = itemID?.uuidString
    thumbnailID = input.thumbnailID.uuidString
    state = "importing"
    version = 1
    quality = input.quality.rawValue
    normalizedFormat = input.normalized.format.rawValue
    normalizedWidth = input.normalized.width
    normalizedHeight = input.normalized.height
    normalizedByteCount = input.normalized.bytes.count
    normalizedHash = WardrobePhotoPersistence.hash(input.normalized.bytes)
    normalizedPath = "photo-\(id)/normalized.image"
    thumbnailFormat = input.thumbnail.format.rawValue
    thumbnailWidth = input.thumbnail.width
    thumbnailHeight = input.thumbnail.height
    thumbnailByteCount = input.thumbnail.bytes.count
    thumbnailHash = WardrobePhotoPersistence.hash(input.thumbnail.bytes)
    thumbnailPath = "photo-\(id)/thumbnail.image"
    createdAt = Date().timeIntervalSince1970
  }
  func matches(_ other: Self) -> Bool {
    quality == other.quality && thumbnailID == other.thumbnailID && normalizedFormat == other.normalizedFormat
      && normalizedWidth == other.normalizedWidth && normalizedHeight == other.normalizedHeight
      && normalizedHash == other.normalizedHash && normalizedByteCount == other.normalizedByteCount
      && thumbnailFormat == other.thumbnailFormat && thumbnailWidth == other.thumbnailWidth
      && thumbnailHeight == other.thumbnailHeight && thumbnailHash == other.thumbnailHash
      && thumbnailByteCount == other.thumbnailByteCount
  }
  func metadata() throws -> WardrobePhotoMetadata {
    guard let photoID = UUID(uuidString: id), photoID.uuidString == id,
          let thumbID = UUID(uuidString: thumbnailID), thumbID.uuidString == thumbnailID, thumbID != photoID,
          let quality = WardrobePhotoQuality(rawValue: quality),
          let normalFormat = WardrobeImageFormat(rawValue: normalizedFormat),
          let thumbFormat = WardrobeImageFormat(rawValue: thumbnailFormat), version == 1,
          normalizedPath == "photo-\(id)/normalized.image", thumbnailPath == "photo-\(id)/thumbnail.image",
          normalizedWidth > 0, normalizedHeight > 0, normalizedByteCount > 0,
          thumbnailWidth > 0, thumbnailHeight > 0, thumbnailByteCount > 0,
          thumbnailWidth <= normalizedWidth, thumbnailHeight <= normalizedHeight,
          validHash(normalizedHash), validHash(thumbnailHash), createdAt.isFinite else {
      throw WardrobeError.invalidStoredData
    }
    return WardrobePhotoMetadata(id: photoID, quality: quality,
      normalized: WardrobePhotoVariant(id: photoID, format: normalFormat, width: normalizedWidth,
        height: normalizedHeight, byteCount: normalizedByteCount, sha256: normalizedHash),
      thumbnail: WardrobePhotoVariant(id: thumbID, format: thumbFormat, width: thumbnailWidth,
        height: thumbnailHeight, byteCount: thumbnailByteCount, sha256: thumbnailHash),
      createdAt: Date(timeIntervalSince1970: createdAt))
  }
  private func validHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
