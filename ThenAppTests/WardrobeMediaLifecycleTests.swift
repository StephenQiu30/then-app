import Foundation
import GRDB
import Testing

struct WardrobeMediaLifecycleTests {
  typealias Probe = WardrobeMediaLifecycleProbe

  @Test func usesProductionWALModeAndKeepsImageBytesOutOfSQLite() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    let sql = try DatabaseQueue(path: fixture.root.appendingPathComponent("probe.sqlite").path)
    let mode = try await sql.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
    #expect(mode == "wal")
    let columns = try await sql.read { db in try db.columns(in: "photos").map(\.type) }
    #expect(!columns.contains("BLOB"))
    try sql.close()
    try await store.close()
    let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("probe.sqlite"))
    #expect(bytes.range(of: photo.normalized) == nil)
    #expect(bytes.range(of: photo.thumbnail) == nil)
  }

  @Test func saveRetryRestartAndRemoveKeepStructuredItem() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    #expect(try await store.revision(item) == 2)
    #expect(try await store.read(item) == photo)
    try await store.close()
    let reopened = try Probe(root: fixture.root)
    try await reopened.recover()
    #expect(try await reopened.read(item) == photo)
    try await reopened.removePhoto(itemID: item, expectedRevision: 2)
    try await reopened.removePhoto(itemID: item, expectedRevision: 2)
    #expect(try await reopened.read(item) == nil)
    #expect(try await reopened.revision(item) == 3)
    #expect(try await reopened.pendingCount() == 0)
    #expect(try fixture.photoFolders().isEmpty)
    try await reopened.close()
  }

  @Test(arguments: [Probe.Point.afterIntent, .afterNormalized, .afterPublish, .beforeCommit])
  func interruptedReplacementKeepsOldPhoto(point: Probe.Point) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), old = fixture.photo(), next = fixture.photo()
    let initial = try Probe(root: fixture.root)
    try await initial.createItem(item)
    try await initial.save(old, itemID: item, expectedRevision: 1)
    try await initial.close()
    let failing = try Probe(root: fixture.root, interrupt: point)
    await #expect(throws: Probe.Failure.interrupted) {
      try await failing.save(next, itemID: item, expectedRevision: 2)
    }
    #expect(try await failing.read(item) == old)
    #expect(try await failing.revision(item) == 2)
    #expect(try await failing.pendingCount() == 1)
    try await failing.close()
    let reopened = try Probe(root: fixture.root)
    try await reopened.recover()
    #expect(try await reopened.read(item) == old)
    #expect(try await reopened.pendingCount() == 0)
    #expect(try fixture.photoFolders() == ["photo-" + old.id.uuidString])
    try await reopened.close()
  }

  @Test func committedReplacementRecoversOldPhotoDeletion() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), old = fixture.photo(), next = fixture.photo()
    let initial = try Probe(root: fixture.root)
    try await initial.createItem(item)
    try await initial.save(old, itemID: item, expectedRevision: 1)
    try await initial.close()
    let failing = try Probe(root: fixture.root, interrupt: .afterCommit)
    await #expect(throws: Probe.Failure.interrupted) {
      try await failing.save(next, itemID: item, expectedRevision: 2)
    }
    #expect(try await failing.read(item) == next)
    #expect(try await failing.revision(item) == 3)
    try await failing.close()
    let reopened = try Probe(root: fixture.root)
    try await reopened.recover()
    try await reopened.save(next, itemID: item, expectedRevision: 2)
    #expect(try await reopened.revision(item) == 3)
    #expect(try fixture.photoFolders() == ["photo-" + next.id.uuidString])
    try await reopened.close()
  }

  @Test(arguments: [false, true])
  func interruptedDeletionStaysHiddenAndRetainsCleanupIntent(deleteItem: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo(), other = UUID(), kept = fixture.photo()
    let initial = try Probe(root: fixture.root)
    try await initial.createItem(item)
    try await initial.createItem(other)
    try await initial.save(photo, itemID: item, expectedRevision: 1)
    try await initial.save(kept, itemID: other, expectedRevision: 1)
    try await initial.close()
    let failing = try Probe(root: fixture.root, interrupt: .duringDelete)
    await #expect(throws: Probe.Failure.interrupted) {
      if deleteItem { try await failing.deleteItem(item, expectedRevision: 2) }
      else { try await failing.removePhoto(itemID: item, expectedRevision: 2) }
    }
    #expect(try await failing.read(item) == nil)
    #expect(try await failing.pendingCount() == 1)
    #expect(try await failing.revision(item) == (deleteItem ? nil : 3))
    try await failing.close()
    let reopened = try Probe(root: fixture.root)
    try await reopened.recover()
    #expect(try await reopened.pendingCount() == 0)
    #expect(try await reopened.read(other) == kept)
    #expect(try fixture.photoFolders() == ["photo-" + kept.id.uuidString])
    try await reopened.close()
  }

  @Test func rejectedSQLCommitPreservesOldPhotoAndRevision() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), old = fixture.photo(), next = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(old, itemID: item, expectedRevision: 1)
    let sql = try DatabaseQueue(path: fixture.root.appendingPathComponent("probe.sqlite").path)
    try await sql.write { db in
      try db.execute(sql: """
        CREATE TRIGGER fail_publish BEFORE UPDATE ON photos
        WHEN NEW.state = 'ready' AND OLD.state = 'importing'
        BEGIN SELECT RAISE(ABORT, 'synthetic commit failure'); END;
        """)
    }
    await #expect(throws: (any Error).self) { try await store.save(next, itemID: item, expectedRevision: 2) }
    #expect(try await store.read(item) == old)
    #expect(try await store.revision(item) == 2)
    try await store.recover()
    #expect(try fixture.photoFolders() == ["photo-" + old.id.uuidString])
    try sql.close()
    try await store.close()
  }

  @Test func staleSaveRemoveAndDeleteCannotChangeCurrentPhoto() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    await #expect(throws: Probe.Failure.conflict) { try await store.save(fixture.photo(), itemID: item, expectedRevision: 1) }
    await #expect(throws: Probe.Failure.conflict) { try await store.removePhoto(itemID: item, expectedRevision: 1) }
    await #expect(throws: Probe.Failure.conflict) { try await store.deleteItem(item, expectedRevision: 1) }
    #expect(try await store.read(item) == photo)
    #expect(try await store.pendingCount() == 0)
    try await store.close()
  }

  @Test(arguments: ["missing", "corrupt", "oversized", "symlink", "hardlink", "dangling"])
  func badFilesNeverBecomeUsableOrDeleteTheItem(kind: String) async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    let url = fixture.root.appendingPathComponent("photo-" + photo.id.uuidString).appendingPathComponent("normalized.bin")
    try FileManager.default.removeItem(at: url)
    let outside = fixture.container.appendingPathComponent("outside")
    try photo.normalized.write(to: outside)
    switch kind {
    case "corrupt": try Data(repeating: 0, count: photo.normalized.count).write(to: url)
    case "oversized": try Data(repeating: 0, count: 1_048_577).write(to: url)
    case "symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
    case "hardlink": try FileManager.default.linkItem(at: outside, to: url)
    case "dangling": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside.appendingPathExtension("absent"))
    default: break
    }
    if ["symlink", "hardlink", "dangling"].contains(kind) {
      await #expect(throws: Probe.Failure.unsafePath) { _ = try await store.read(item) }
      await #expect(throws: Probe.Failure.unsafePath) { try await store.removePhoto(itemID: item, expectedRevision: 2) }
      #expect(try await store.pendingCount() == 1)
    } else { #expect(try await store.read(item) == nil) }
    #expect(try await store.revision(item) != nil)
    #expect(try Data(contentsOf: outside) == photo.normalized)
    try await store.close()
  }

  @Test(arguments: [false, true])
  func symlinkRootIsRejectedWithoutOpeningOrCleaningTarget(dangling: Bool) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outside = fixture.container.appendingPathComponent("outside", isDirectory: true)
    if !dangling { try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false) }
    try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: outside)
    #expect(throws: Probe.Failure.unsafePath) { _ = try Probe(root: fixture.root) }
    if dangling { #expect(!FileManager.default.fileExists(atPath: outside.path)) }
    else { #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty) }
  }

  @Test func sameCommandIDWithDifferentBytesCannotOverwrite() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    let changed = Probe.Photo(id: photo.id, normalized: Data("changed".utf8), thumbnail: photo.thumbnail)
    await #expect(throws: Probe.Failure.conflict) { try await store.save(changed, itemID: item, expectedRevision: 2) }
    #expect(try await store.read(item) == photo)
    #expect(try await store.revision(item) == 2)
    try await store.close()
  }

  @Test func cleanupObstructionKeepsIntentUntilRemoved() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    let obstruction = fixture.root.appendingPathComponent("photo-" + photo.id.uuidString).appendingPathComponent("unexpected")
    try Data("synthetic obstruction".utf8).write(to: obstruction)
    await #expect(throws: Probe.Failure.unsafePath) { try await store.removePhoto(itemID: item, expectedRevision: 2) }
    #expect(try await store.read(item) == nil)
    #expect(try await store.pendingCount() == 1)
    #expect(FileManager.default.fileExists(atPath: obstruction.path))
    try FileManager.default.removeItem(at: obstruction)
    try await store.recover()
    #expect(try await store.pendingCount() == 0)
    #expect(try fixture.photoFolders().isEmpty)
    #expect(try await store.revision(item) == 3)
    try await store.close()
  }

  @Test func cancelledSaveDoesNotCreateIntentOrFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await store.save(fixture.photo(), itemID: item, expectedRevision: 1)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.pendingCount() == 0)
    #expect(try await store.revision(item) == 1)
    #expect(try fixture.photoFolders().isEmpty)
    try await store.close()
  }

  @Test func danglingPhotoDirectoryDoesNotEraseCleanupIntent() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID(), photo = fixture.photo()
    let store = try Probe(root: fixture.root)
    try await store.createItem(item)
    try await store.save(photo, itemID: item, expectedRevision: 1)
    let folder = fixture.root.appendingPathComponent("photo-" + photo.id.uuidString)
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: fixture.container.appendingPathComponent("absent"))
    await #expect(throws: Probe.Failure.unsafePath) { _ = try await store.read(item) }
    await #expect(throws: Probe.Failure.unsafePath) { try await store.removePhoto(itemID: item, expectedRevision: 2) }
    #expect(try await store.pendingCount() == 1)
    try FileManager.default.removeItem(at: folder)
    try await store.recover()
    #expect(try await store.pendingCount() == 0)
    #expect(try await store.revision(item) == 3)
    try await store.close()
  }

  @Test func cancellationAfterFirstFileRecoversWithoutPublishing() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let item = UUID()
    let store = try Probe(root: fixture.root, cancelAt: .afterNormalized)
    try await store.createItem(item)
    let task = Task { try await store.save(fixture.photo(), itemID: item, expectedRevision: 1) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.read(item) == nil)
    #expect(try await store.pendingCount() == 1)
    #expect(try await store.revision(item) == 1)
    try await store.close()
    let reopened = try Probe(root: fixture.root)
    try await reopened.recover()
    #expect(try fixture.photoFolders().isEmpty)
    #expect(try await reopened.pendingCount() == 0)
    try await reopened.close()
  }

  private nonisolated struct Fixture: Sendable {
    let container: URL
    var root: URL { container.appendingPathComponent("media", isDirectory: true) }
    init() throws {
      container = FileManager.default.temporaryDirectory.appendingPathComponent("ThenMediaPOC-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    }
    func photo() -> Probe.Photo {
      let id = UUID()
      return Probe.Photo(id: id, normalized: Data(("synthetic normalized " + id.uuidString).utf8),
                         thumbnail: Data(("synthetic thumbnail " + id.uuidString).utf8))
    }
    func photoFolders() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
        $0.hasPrefix("photo-") || $0.hasPrefix("staging-")
      }.sorted()
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
  }
}
