// Isolated persistence POC: compiled only by ThenAppTests, never by the production target.
import CryptoKit
import Foundation
import GRDB

actor WardrobeMediaLifecycleProbe {
  nonisolated enum Failure: Error, Equatable {
    case conflict, invalidInput, unsafePath, interrupted
  }
  nonisolated enum Point: Sendable {
    case afterIntent, afterNormalized, afterPublish, beforeCommit, afterCommit, duringDelete
  }
  nonisolated struct Photo: Equatable, Sendable {
    let id: UUID
    let normalized: Data
    let thumbnail: Data
  }
  private let root: URL
  private let database: DatabasePool
  private let interrupt: Point?
  private let cancelAt: Point?
  private var interrupted = false

  init(root: URL, interrupt: Point? = nil, cancelAt: Point? = nil) throws {
    guard root.isFileURL else { throw Failure.unsafePath }
    self.root = root.standardizedFileURL
    self.interrupt = interrupt
    self.cancelAt = cancelAt
    try Self.directory(self.root, create: true)
    let databaseURL = self.root.appendingPathComponent("probe.sqlite")
    if try Self.attributes(databaseURL) != nil { try Self.regular(databaseURL) }
    var configuration = Configuration()
    configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
    database = try DatabasePool(path: databaseURL.path, configuration: configuration)
    try database.write { db in
      try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS photos (
          id TEXT PRIMARY KEY NOT NULL,
          itemID TEXT REFERENCES items(id) ON DELETE SET NULL,
          state TEXT NOT NULL CHECK(state IN ('importing','ready','deleting')),
          normalizedHash TEXT NOT NULL, thumbnailHash TEXT NOT NULL,
          normalizedBytes INTEGER NOT NULL, thumbnailBytes INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS one_ready_photo ON photos(itemID) WHERE state = 'ready';
        """)
    }
  }

  func createItem(_ id: UUID) throws {
    try database.write { db in
      try db.execute(sql: "INSERT INTO items(id,revision) VALUES (?,1)", arguments: [id.uuidString])
    }
  }

  func revision(_ id: UUID) throws -> Int? {
    try database.read { db in try Int.fetchOne(db, sql: "SELECT revision FROM items WHERE id = ?", arguments: [id.uuidString]) }
  }

  func save(_ photo: Photo, itemID: UUID, expectedRevision: Int) throws {
    try Task.checkCancellation()
    // POC storage budget only: these synthetic bytes do not establish an image quality budget.
    guard !photo.normalized.isEmpty, !photo.thumbnail.isEmpty,
          photo.normalized.count <= 1_048_576, photo.thumbnail.count <= 1_048_576 else { throw Failure.invalidInput }
    try Self.directory(root, create: false)
    let mainHash = Self.hash(photo.normalized)
    let thumbHash = Self.hash(photo.thumbnail)
    let existing = try database.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM photos WHERE id = ?", arguments: [photo.id.uuidString])
    }
    if let existing {
      guard existing["state"] as String == "ready", existing["itemID"] as String? == itemID.uuidString,
            existing["normalizedHash"] as String == mainHash, existing["thumbnailHash"] as String == thumbHash,
            try read(itemID) == photo else { throw Failure.conflict }
      return
    }
    try database.write { db in
      try Self.checkRevision(db, itemID, expectedRevision)
      try db.execute(sql: "INSERT INTO photos VALUES (?,?,'importing',?,?,?,?)",
                     arguments: [photo.id.uuidString, itemID.uuidString, mainHash, thumbHash,
                                 photo.normalized.count, photo.thumbnail.count])
    }
    try hit(.afterIntent)
    let staging = folder(photo.id, staging: true)
    try Self.directory(staging, create: true)
    try Self.write(photo.normalized, to: staging.appendingPathComponent("normalized.bin"))
    try hit(.afterNormalized)
    try Task.checkCancellation()
    try Self.write(photo.thumbnail, to: staging.appendingPathComponent("thumbnail.bin"))
    let published = folder(photo.id)
    guard try Self.attributes(published) == nil else { throw Failure.unsafePath }
    try FileManager.default.moveItem(at: staging, to: published)
    try hit(.afterPublish)
    try Task.checkCancellation()
    try hit(.beforeCommit)
    try database.write { db in
      try Self.checkRevision(db, itemID, expectedRevision)
      try db.execute(sql: "UPDATE photos SET state = 'deleting' WHERE itemID = ? AND state = 'ready'", arguments: [itemID.uuidString])
      try db.execute(sql: "UPDATE photos SET state = 'ready' WHERE id = ? AND state = 'importing'", arguments: [photo.id.uuidString])
      guard db.changesCount == 1 else { throw Failure.conflict }
      try db.execute(sql: "UPDATE items SET revision = revision + 1 WHERE id = ?", arguments: [itemID.uuidString])
    }
    try hit(.afterCommit)
    // A committed save survives caller cancellation. Cleanup is durable and retryable.
    try recover()
  }

  func read(_ itemID: UUID) throws -> Photo? {
    try Self.directory(root, create: false)
    guard let row = try database.read({ db in
      try Row.fetchOne(db, sql: "SELECT * FROM photos WHERE itemID = ? AND state = 'ready'", arguments: [itemID.uuidString])
    }), let id = UUID(uuidString: row["id"]) else { return nil }
    let dir = folder(id)
    guard try Self.attributes(dir) != nil else { return nil }
    try Self.directory(dir, create: false)
    var bytes: [Data] = []
    for (filename, countKey, hashKey) in [("normalized.bin", "normalizedBytes", "normalizedHash"),
                                        ("thumbnail.bin", "thumbnailBytes", "thumbnailHash")] {
      let url = dir.appendingPathComponent(filename)
      guard try Self.attributes(url) != nil else { return nil }
      try Self.regular(url)
      let expected: Int = row[countKey]
      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
      guard (1...1_048_576).contains(expected), size?.intValue == expected else { return nil }
      let data = try Data(contentsOf: url)
      guard data.count == expected, Self.hash(data) == row[hashKey] as String else { return nil }
      bytes.append(data)
    }
    return Photo(id: id, normalized: bytes[0], thumbnail: bytes[1])
  }

  func removePhoto(itemID: UUID, expectedRevision: Int) throws {
    try database.write { db in
      let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM photos WHERE itemID = ? AND state = 'ready'", arguments: [itemID.uuidString])
      if count == 0 { return }
      try Self.checkRevision(db, itemID, expectedRevision)
      try db.execute(sql: "UPDATE photos SET state = 'deleting' WHERE itemID = ?", arguments: [itemID.uuidString])
      try db.execute(sql: "UPDATE items SET revision = revision + 1 WHERE id = ?", arguments: [itemID.uuidString])
    }
    try recover()
  }

  func deleteItem(_ itemID: UUID, expectedRevision: Int) throws {
    try database.write { db in
      let exists = try Int.fetchOne(db, sql: "SELECT revision FROM items WHERE id = ?", arguments: [itemID.uuidString])
      guard exists != nil else { return }
      try Self.checkRevision(db, itemID, expectedRevision)
      try db.execute(sql: "UPDATE photos SET state = 'deleting' WHERE itemID = ?", arguments: [itemID.uuidString])
      try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [itemID.uuidString])
    }
    try recover()
  }

  func recover() throws {
    try Self.directory(root, create: false)
    let pending: [String] = try database.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM photos WHERE state != 'ready'")
    }
    for value in pending {
      guard let id = UUID(uuidString: value) else { throw Failure.unsafePath }
      try hit(.duringDelete)
      for staging in [true, false] { try removeFolder(folder(id, staging: staging)) }
      try database.write { db in
        try db.execute(sql: "DELETE FROM photos WHERE id = ? AND state != 'ready'", arguments: [value])
      }
    }
    _ = try database.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
  }

  func pendingCount() throws -> Int {
    try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM photos WHERE state != 'ready'") ?? 0 }
  }
  func close() throws { try database.close() }

  private func hit(_ point: Point) throws {
    if cancelAt == point { withUnsafeCurrentTask { $0?.cancel() } }
    if interrupt == point && !interrupted { interrupted = true; throw Failure.interrupted }
  }
  private func folder(_ id: UUID, staging: Bool = false) -> URL {
    root.appendingPathComponent((staging ? "staging-" : "photo-") + id.uuidString, isDirectory: true)
  }
  private func removeFolder(_ url: URL) throws {
    guard try Self.attributes(url) != nil else { return }
    try Self.directory(url, create: false)
    for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
      guard ["normalized.bin", "thumbnail.bin"].contains(child.lastPathComponent) else { throw Failure.unsafePath }
      try Self.regular(child)
    }
    try FileManager.default.removeItem(at: url)
  }
  private static func checkRevision(_ db: Database, _ id: UUID, _ expected: Int) throws {
    guard expected < Int.max,
      try Int.fetchOne(db, sql: "SELECT revision FROM items WHERE id = ?", arguments: [id.uuidString]) == expected
    else { throw Failure.conflict }
  }
  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func directory(_ url: URL, create: Bool) throws {
    if try attributes(url) == nil, create {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
        attributes: [.protectionKey: FileProtectionType.complete])
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafePath }
    try protect(url)
  }
  /// Read the directory entry itself. fileExists follows links and conflates inaccessible with absent.
  private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
    do { return try FileManager.default.attributesOfItem(atPath: url.path) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
  }
  private static func regular(_ url: URL) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw Failure.unsafePath }
  }
  private static func protect(_ url: URL) throws {
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    var mutable = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutable.setResourceValues(values)
  }
  private static func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
    try protect(url)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
  }
}
