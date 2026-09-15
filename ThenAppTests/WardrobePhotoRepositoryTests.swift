import Foundation
import GRDB
import Testing
@testable import ThenApp

struct WardrobePhotoRepositoryTests {
  @Test func inputRejectsInvalidBudgetDimensionsAndSharedIdentity() throws {
    #expect(throws: WardrobePhotoInputError.invalidImage) {
      try WardrobeEncodedImage(bytes: Data([1]), format: .png, width: Int.max, height: 2, maximumBytes: 1)
    }
    #expect(throws: WardrobePhotoInputError.invalidImage) {
      try WardrobeEncodedImage(bytes: Data([1, 2]), format: .png, width: 1, height: 1, maximumBytes: 1)
    }
    let image = try Self.image("small", width: 1)
    let id = UUID()
    #expect(throws: WardrobePhotoInputError.invalidImage) {
      try WardrobePhotoWrite(id: id, thumbnailID: id, normalized: image, thumbnail: image, quality: .catalogReady)
    }
  }

  @Test func v1UpgradePreservesExistingWardrobeData() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
    let db = try DatabaseQueue(path: fixture.database.path)
    try OOTDSchema.migrator.migrate(db, upTo: "ootd_v1_wardrobe")
    let id = UUID()
    try await db.write { db in
      try db.execute(sql: "INSERT INTO wardrobe_items VALUES (?, 'v1 synthetic item', 'top', 'laundry', 'wardrobe', 7, 1000, 2000)", arguments: [id.uuidString])
    }
    try db.close()
    let store = fixture.store()
    try await store.prepare()
    let item = try #require(try await store.list(WardrobeFilter(availability: nil)).first)
    #expect(item.id == id && item.revision == 7 && item.input.name == "v1 synthetic item")
    #expect(item.input.availability == .laundry)
    #expect(item.input.attributes == .init())
    let sql = try fixture.sql()
    let versions = try await sql.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
    #expect(versions == ["ootd_v1_wardrobe", "ootd_v2_wardrobe_photos", "ootd_v3_unattached_photo_imports",
      "ootd_v4_outfit_plans", "ootd_wardrobe_attributes_v1", "ootd_wear_events_v1"])
    let columns = try await sql.read { db in try db.columns(in: "wardrobe_photos").map(\.type) }
    #expect(!columns.contains("BLOB"))
    try sql.close()
    try await store.close()
  }

  @Test func saveRetryAndReopenPreserveMetadataAndFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    let saved = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    let repeated = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    #expect(saved.itemRevision == 2 && repeated.itemRevision == 2)
    #expect(saved.metadata == repeated.metadata)
    #expect(!saved.cleanupPending)
    #expect(saved.metadata.normalized.id == photo.id && saved.metadata.thumbnail.id == photo.thumbnailID)
    #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)?.bytes == photo.normalized.bytes)
    #expect(try await store.readPhoto(itemID: itemID, purpose: .thumbnail, maximumBytes: 1) == nil)
    try await store.close()
    let reopened = fixture.store()
    #expect(try await reopened.readPhoto(itemID: itemID, purpose: .thumbnail, maximumBytes: 1024)?.metadata == saved.metadata)
    #expect(try await reopened.list(WardrobeFilter()).first?.revision == 2)
    #expect(try fixture.photoFolders() == ["photo-" + photo.id.uuidString])
    #expect(try fixture.media.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    try await reopened.close()
  }

  @Test func concurrentRetriesAndConflictingIDsDoNotDuplicate() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<8 { group.addTask { try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1).itemRevision } }
      for try await revision in group { #expect(revision == 2) }
    }
    let changed = try WardrobePhotoWrite(id: photo.id, thumbnailID: photo.thumbnailID,
      normalized: Self.image("different", width: 8), thumbnail: photo.thumbnail, quality: .catalogReady)
    await #expect(throws: WardrobeError.conflict) { try await store.savePhoto(changed, itemID: itemID, expectedRevision: 2) }
    await #expect(throws: WardrobeError.conflict) { try await store.savePhoto(Self.photo(), itemID: itemID, expectedRevision: 1) }
    #expect(try await store.list(WardrobeFilter()).first?.revision == 2)
    #expect(try fixture.photoFolders().count == 1)
    try await store.close()
  }

  @Test func failedSQLPublicationKeepsOldPhotoAndCleansAttempt() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), old = try Self.photo(), next = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(old, itemID: itemID, expectedRevision: 1)
    let sql = try fixture.sql()
    try await sql.write { db in
      try db.execute(sql: """
        CREATE TRIGGER fail_photo_commit BEFORE UPDATE ON wardrobe_photos
        WHEN NEW.state = 'ready' AND OLD.state = 'importing'
        BEGIN SELECT RAISE(ABORT, 'synthetic commit failure'); END;
        """)
    }
    await #expect(throws: WardrobeError.storageUnavailable) { try await store.savePhoto(next, itemID: itemID, expectedRevision: 2) }
    #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)?.metadata.id == old.id)
    #expect(try await store.list(WardrobeFilter()).first?.revision == 2)
    #expect(try await store.hasPendingPhotoCleanup() == false)
    #expect(try fixture.photoFolders() == ["photo-" + old.id.uuidString])
    try sql.close()
    try await store.close()
  }

  @Test func committedReplacementReportsCleanupAndOldRetryCannotRemoveNewPhoto() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), old = try Self.photo(), next = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(old, itemID: itemID, expectedRevision: 1)
    let obstruction = fixture.folder(old.id).appendingPathComponent("unexpected")
    try Data("obstruction".utf8).write(to: obstruction)
    let saved = try await store.savePhoto(next, itemID: itemID, expectedRevision: 2)
    #expect(saved.itemRevision == 3 && saved.cleanupPending)
    #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)?.metadata.id == next.id)
    #expect(try await store.hasPendingPhotoCleanup())
    try await store.close()
    let reopened = fixture.store()
    try await reopened.prepare()
    #expect(try await reopened.list(WardrobeFilter()).first?.revision == 3)
    #expect(try await reopened.hasPendingPhotoCleanup())
    try FileManager.default.removeItem(at: obstruction)
    try await reopened.removePhoto(id: old.id, itemID: itemID, expectedRevision: 2)
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    #expect(try await reopened.readPhoto(itemID: itemID, purpose: .thumbnail, maximumBytes: 1024)?.metadata.id == next.id)
    #expect(try await reopened.list(WardrobeFilter()).first?.revision == 3)
    try await reopened.close()
  }

  @Test func removePhotoHidesImmediatelyAndPreservesItemAcrossRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    let obstruction = fixture.folder(photo.id).appendingPathComponent("unexpected")
    try Data([0]).write(to: obstruction)
    await #expect(throws: WardrobeError.deletionCleanupPending) {
      try await store.removePhoto(id: photo.id, itemID: itemID, expectedRevision: 2)
    }
    #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024) == nil)
    #expect(try await store.list(WardrobeFilter()).first?.revision == 3)
    try await store.close()
    try FileManager.default.removeItem(at: obstruction)
    let reopened = fixture.store()
    try await reopened.prepare()
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    #expect(try fixture.photoFolders().isEmpty)
    #expect(try await reopened.list(WardrobeFilter()).first?.id == itemID)
    try await reopened.removePhoto(id: photo.id, itemID: itemID, expectedRevision: 2)
    #expect(try await reopened.list(WardrobeFilter()).first?.revision == 3)
    try await reopened.close()
  }

  @Test func itemDeletionRetainsMediaJournalAndDoesNotDeleteOtherItem() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), otherID = UUID(), photo = try Self.photo(), kept = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.create(id: otherID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    _ = try await store.savePhoto(kept, itemID: otherID, expectedRevision: 1)
    let obstruction = fixture.folder(photo.id).appendingPathComponent("unexpected")
    try Data([0]).write(to: obstruction)
    await #expect(throws: WardrobeError.deletionCleanupPending) { try await store.delete(id: itemID, expectedRevision: 2, impact: .init(plans: []), policy: .redactSnapshots) }
    #expect(try await store.list(WardrobeFilter()).map(\.id) == [otherID])
    let sql = try fixture.sql()
    let orphan = try await sql.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM wardrobe_photos WHERE itemID IS NULL AND state = 'deleting'")
    }
    #expect(orphan == 1)
    try sql.close()
    try await store.close()
    try FileManager.default.removeItem(at: obstruction)
    let reopened = fixture.store()
    try await reopened.prepare()
    #expect(try await reopened.readPhoto(itemID: otherID, purpose: .normalized, maximumBytes: 1024)?.metadata.id == kept.id)
    #expect(try fixture.photoFolders() == ["photo-" + kept.id.uuidString])
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    try await reopened.close()
  }

  @Test(arguments: ["intent", "first-file", "published"])
  func startupRemovesInterruptedImportsWhileKeepingReadyPhoto(stage: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), old = try Self.photo(), incoming = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(old, itemID: itemID, expectedRevision: 1)
    try await store.close()
    let sql = try fixture.sql()
    try await sql.write { db in
      try db.execute(sql: """
        INSERT INTO wardrobe_photos SELECT ?,itemID,?,'importing',version,quality,
        normalizedFormat,normalizedWidth,normalizedHeight,normalizedByteCount,normalizedHash,?,
        thumbnailFormat,thumbnailWidth,thumbnailHeight,thumbnailByteCount,thumbnailHash,?,createdAt
        FROM wardrobe_photos WHERE id = ?
        """, arguments: [incoming.id.uuidString, incoming.thumbnailID.uuidString,
          "photo-\(incoming.id.uuidString)/normalized.image", "photo-\(incoming.id.uuidString)/thumbnail.image", old.id.uuidString])
    }
    try sql.close()
    if stage != "intent" {
      let folder = fixture.folder(incoming.id, staging: stage == "first-file")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      try old.normalized.bytes.write(to: folder.appendingPathComponent("normalized.image"))
      if stage == "published" { try old.thumbnail.bytes.write(to: folder.appendingPathComponent("thumbnail.image")) }
    }
    let reopened = fixture.store()
    try await reopened.prepare()
    #expect(try await reopened.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)?.metadata.id == old.id)
    #expect(try await reopened.list(WardrobeFilter()).first?.revision == 2)
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    #expect(try fixture.photoFolders() == ["photo-" + old.id.uuidString])
    try await reopened.close()
  }

  @Test(arguments: ["missing", "corrupt", "oversized", "symlink", "dangling", "hardlink"])
  func missingOrUnsafeFileNeverDropsTheWardrobeItem(kind: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    let url = fixture.folder(photo.id).appendingPathComponent("normalized.image")
    try FileManager.default.removeItem(at: url)
    let outside = fixture.root.appendingPathComponent("outside")
    try photo.normalized.bytes.write(to: outside)
    switch kind {
    case "corrupt": try Data(repeating: 0, count: photo.normalized.bytes.count).write(to: url)
    case "oversized": try Data(repeating: 0, count: 2048).write(to: url)
    case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
    case "dangling": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside.appendingPathExtension("absent"))
    case "hardlink": try FileManager.default.linkItem(at: outside, to: url)
    default: break
    }
    if ["symlink", "dangling", "hardlink"].contains(kind) {
      await #expect(throws: WardrobeError.storageUnavailable) {
        try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)
      }
    } else { #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024) == nil) }
    #expect(try await store.list(WardrobeFilter()).first?.id == itemID)
    #expect(try Data(contentsOf: outside) == photo.normalized.bytes)
    try await store.close()
  }

  @Test func storedPathCannotEscapeAssetGroup() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    let sql = try fixture.sql()
    try await sql.write { db in try db.execute(sql: "UPDATE wardrobe_photos SET normalizedPath = '../outside'") }
    await #expect(throws: WardrobeError.invalidStoredData) {
      try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)
    }
    try await store.removePhoto(id: photo.id, itemID: itemID, expectedRevision: 2)
    #expect(try fixture.photoFolders().isEmpty)
    #expect(try await store.list(WardrobeFilter()).first?.id == itemID)
    try sql.close()
    try await store.close()
  }

  @Test func unsafeMediaRootFailsBeforeImportWithoutBlockingWardrobe() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: fixture.media, withDestinationURL: outside)
    await #expect(throws: WardrobeError.storageUnavailable) {
      try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    }
    #expect(try await store.hasPendingPhotoCleanup() == false)
    #expect(try await store.list(WardrobeFilter()).first?.revision == 1)
    try await store.close()
    let reopened = fixture.store()
    try await reopened.prepare()
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    try FileManager.default.removeItem(at: fixture.media)
    try await reopened.retryPhotoCleanup()
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    let saved = try await reopened.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    #expect(saved.itemRevision == 2)
    try await reopened.close()
  }

  @Test func stalePhotoDeleteAndWrongOwnerCannotRemoveCurrentPhoto() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    await #expect(throws: WardrobeError.conflict) { try await store.removePhoto(id: photo.id, itemID: itemID, expectedRevision: 1) }
    await #expect(throws: WardrobeError.conflict) { try await store.removePhoto(id: photo.id, itemID: UUID(), expectedRevision: 2) }
    #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)?.metadata.id == photo.id)
    try await store.close()
  }

  @Test func cancelledSaveDoesNotChangeTheItem() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.list(WardrobeFilter()).first?.revision == 1)
    #expect(try await store.hasPendingPhotoCleanup() == false)
    try await store.close()
  }

  @Test func rejectedImportMustNotDeleteAPreexistingAssetDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    let folder = fixture.folder(photo.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let existing = folder.appendingPathComponent("normalized.image")
    try Data("preexisting bytes".utf8).write(to: existing)
    await #expect(throws: WardrobeError.storageUnavailable) { try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1) }
    #expect(FileManager.default.fileExists(atPath: existing.path))
    #expect(try await store.hasPendingPhotoCleanup() == false)
    #expect(try await store.list(WardrobeFilter()).first?.revision == 1)
    try await store.close()
  }

  @Test func normalizedAndThumbnailIdentitiesCannotOverlapAcrossGroups() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    let collision = try WardrobePhotoWrite(id: UUID(), thumbnailID: photo.id,
      normalized: photo.normalized, thumbnail: photo.thumbnail, quality: .catalogReady)
    await #expect(throws: WardrobeError.conflict) { try await store.savePhoto(collision, itemID: itemID, expectedRevision: 2) }
    #expect(try await store.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1024)?.metadata.id == photo.id)
    #expect(try await store.list(WardrobeFilter()).first?.revision == 2)
    try await store.close()
  }

  @Test func changedMediaRootCannotCleanOutsideFilesAndKeepsDeletionIntent() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    let held = fixture.root.appendingPathComponent("held-media")
    try FileManager.default.moveItem(at: fixture.media, to: held)
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: fixture.media, withDestinationURL: outside)
    await #expect(throws: WardrobeError.deletionCleanupPending) {
      try await store.removePhoto(id: photo.id, itemID: itemID, expectedRevision: 2)
    }
    #expect(try await store.hasPendingPhotoCleanup())
    try await store.close()
    let reopened = fixture.store()
    try await reopened.prepare()
    #expect(try await reopened.list(WardrobeFilter()).first?.revision == 3)
    #expect(try await reopened.hasPendingPhotoCleanup())
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    try FileManager.default.removeItem(at: fixture.media)
    try FileManager.default.moveItem(at: held, to: fixture.media)
    try await reopened.retryPhotoCleanup()
    #expect(try await reopened.hasPendingPhotoCleanup() == false)
    #expect(try fixture.photoFolders().isEmpty)
    try await reopened.close()
  }

  @Test(.enabled(if: Self.hasPhysicalDataProtection,
                 "Media Complete protection requires a physical iOS device"))
  func physicalMediaFilesHaveCompleteProtection() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store(), itemID = UUID(), photo = try Self.photo()
    _ = try await store.create(id: itemID, input: fixture.input(), source: .wardrobe)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    for url in [fixture.directory, fixture.media, fixture.folder(photo.id),
                fixture.folder(photo.id).appendingPathComponent("normalized.image"),
                fixture.folder(photo.id).appendingPathComponent("thumbnail.image")] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
      #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
    try await store.close()
  }

  private nonisolated static var hasPhysicalDataProtection: Bool {
    #if targetEnvironment(simulator)
    false
    #else
    true
    #endif
  }

  private nonisolated static func image(_ value: String, width: Int) throws -> WardrobeEncodedImage {
    try WardrobeEncodedImage(bytes: Data(value.utf8), format: .png, width: width, height: width, maximumBytes: 1024)
  }
  private nonisolated static func photo() throws -> WardrobePhotoWrite {
    let id = UUID()
    return try WardrobePhotoWrite(id: id, thumbnailID: UUID(),
      normalized: image("synthetic normalized \(id)", width: 8), thumbnail: image("synthetic thumbnail \(id)", width: 2),
      quality: .catalogReady)
  }
  private nonisolated struct Fixture: Sendable {
    let root: URL
    var directory: URL { root.appendingPathComponent("OOTD", isDirectory: true) }
    var database: URL { directory.appendingPathComponent("wardrobe.sqlite") }
    var media: URL { directory.appendingPathComponent("WardrobeMedia", isDirectory: true) }
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("ThenPhotoData-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func store() -> GRDBWardrobeRepository { GRDBWardrobeRepository(directory: directory) }
    func input() throws -> WardrobeInput {
      try WardrobeInput(name: "synthetic garment", category: .top, availability: .wearable,
        attributes: .init())
    }
    func sql() throws -> DatabaseQueue { try DatabaseQueue(path: database.path) }
    func folder(_ id: UUID, staging: Bool = false) -> URL {
      media.appendingPathComponent((staging ? "staging-" : "photo-") + id.uuidString, isDirectory: true)
    }
    func photoFolders() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: media.path).sorted()
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
