import Foundation
import GRDB
import Testing
@testable import ThenApp

struct WardrobeRepositoryTests {
  @Test(arguments: ["", "   ", "a\nb", String(repeating: "衣", count: 81)])
  func invalidName(_ name: String) {
    #expect(throws: WardrobeError.invalidName) {
      try WardrobeInput(name: name, category: .top, availability: .wearable)
    }
  }

  @Test func normalizationAndUnicodeLength() throws {
    let input = try WardrobeInput(name: "  白色 T 恤  ", category: .top, availability: .wearable)
    #expect(input.name == "白色 T 恤")
    let family = String(repeating: "👨‍👩‍👧‍👦", count: 80)
    #expect(try WardrobeInput(name: family, category: .top, availability: .wearable).name.count == 80)
  }

  @Test func createRetryAndSameNameItemsHaveIndependentIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let input = try fixture.input()
    let id = UUID()
    let first = try await store.create(id: id, input: input, source: .wardrobe)
    #expect(try await store.create(id: id, input: input, source: .wardrobe) == first)
    let another = try await store.create(id: UUID(), input: input, source: .quickAdd)
    #expect(first.id != another.id)
    #expect(try await store.list(WardrobeFilter()).count == 2)
    await #expect(throws: WardrobeError.conflict) {
      try await store.create(id: id, input: fixture.input("另一件"), source: .wardrobe)
    }
    try await store.close()
  }

  @Test func restartPreservesIdentityRevisionAndStatus() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = fixture.store()
    let original = try await first.create(id: UUID(), input: fixture.input(), source: .quickAdd)
    let edited = try await first.update(id: original.id, expectedRevision: 1,
                                       input: fixture.input("改名", availability: .laundry))
    #expect(edited.revision == 2)
    #expect(edited.createdAt == original.createdAt)
    #expect(edited.source == .quickAdd)
    try await first.close()
    let reopened = fixture.store()
    #expect(try await reopened.list(WardrobeFilter()).isEmpty)
    #expect(try await reopened.list(WardrobeFilter(availability: nil)) == [edited])
    try await reopened.close()
  }

  @Test func staleEditAndDeleteCannotOverwriteNewerRecord() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let original = try await store.create(id: UUID(), input: fixture.input(), source: .wardrobe)
    let edited = try await store.update(id: original.id, expectedRevision: 1, input: fixture.input("新值"))
    await #expect(throws: WardrobeError.conflict) {
      try await store.update(id: original.id, expectedRevision: 1, input: fixture.input("旧值"))
    }
    await #expect(throws: WardrobeError.conflict) {
      try await store.delete(id: original.id, expectedRevision: 1, impact: .init(plans: []), policy: .redactSnapshots)
    }
    #expect(try await store.list(WardrobeFilter()) == [edited])
    try await store.close()
  }

  @Test func literalSearchAndCategoryStatusFilters() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    _ = try await store.create(id: UUID(), input: fixture.input("100%_T 恤"), source: .wardrobe)
    _ = try await store.create(id: UUID(), input: fixture.input("普通 T 恤", availability: .lentOut), source: .wardrobe)
    #expect(try await store.list(WardrobeFilter(search: "%_t")).count == 1)
    #expect(try await store.list(WardrobeFilter(search: "' OR 1=1 --", availability: nil)).isEmpty)
    #expect(try await store.list(WardrobeFilter(category: .shoes, availability: nil)).isEmpty)
    #expect(try await store.list(WardrobeFilter(availability: .lentOut)).count == 1)
    try await store.close()
  }

  @Test func actualSQLFailureRollsBackWithoutChangingRevision() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let original = try await store.create(id: UUID(), input: fixture.input(), source: .wardrobe)
    let database = try DatabaseQueue(path: fixture.database.path)
    try await database.write { db in
      try db.execute(sql: "CREATE TRIGGER reject_update AFTER UPDATE ON wardrobe_items BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
    }
    await #expect(throws: WardrobeError.storageUnavailable) {
      try await store.update(id: original.id, expectedRevision: 1, input: fixture.input("不能写入"))
    }
    #expect(try await store.list(WardrobeFilter()) == [original])
    try database.close()
    try await store.close()
  }

  @Test func failedOpenKeepsBytesAndCanRetryAfterCauseIsRemoved() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let blockedDirectory = fixture.root.appendingPathComponent("blocked")
    let bytes = Data("synthetic obstruction".utf8)
    try bytes.write(to: blockedDirectory)
    let store = GRDBWardrobeRepository(directory: blockedDirectory)
    await #expect(throws: WardrobeError.storageUnavailable) { try await store.prepare() }
    #expect(try Data(contentsOf: blockedDirectory) == bytes)
    try FileManager.default.removeItem(at: blockedDirectory)
    try await store.prepare()
    #expect(try await store.list(WardrobeFilter()).isEmpty)
    try await store.close()
  }

  @Test func deleteIsIdempotentAndDoesNotReappearAfterRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let deleted = try await store.create(id: UUID(), input: fixture.input("删除标记_Z19"), source: .wardrobe)
    let kept = try await store.create(id: UUID(), input: fixture.input("保留标记"), source: .wardrobe)
    try await store.delete(id: deleted.id, expectedRevision: 1, impact: .init(plans: []), policy: .redactSnapshots)
    try await store.delete(id: deleted.id, expectedRevision: 1, impact: .init(plans: []), policy: .redactSnapshots)
    #expect(try await store.list(WardrobeFilter()) == [kept])
    let bytes = try Data(contentsOf: fixture.database)
    #expect(bytes.range(of: Data("删除标记_Z19".utf8)) == nil)
    try await store.close()
    let reopened = fixture.store()
    #expect(try await reopened.list(WardrobeFilter()) == [kept])
    try await reopened.close()
  }

  @Test func newerSchemaIsRejectedWithoutErasingData() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let saved = try await store.create(id: UUID(), input: fixture.input(), source: .wardrobe)
    try await store.close()
    let database = try DatabaseQueue(path: fixture.database.path)
    try await database.write { db in
      try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)", arguments: ["ootd_future_test"])
    }
    try database.close()
    await #expect(throws: WardrobeError.newerDatabase) { try await store.prepare() }
    let readOnly = try DatabaseQueue(path: fixture.database.path)
    #expect(try await readOnly.read { db in try String.fetchOne(db, sql: "SELECT id FROM wardrobe_items") } == saved.id.uuidString)
    try readOnly.close()
  }

  @Test func busyReaderMakesDeletionCleanupRetryable() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let item = try await store.create(id: UUID(), input: fixture.input(), source: .wardrobe)
    // This fixture deliberately holds a read transaction across calls to exercise WAL busy cleanup.
    var configuration = Configuration()
    configuration.allowsUnsafeTransactions = true
    let reader = try DatabaseQueue(path: fixture.database.path, configuration: configuration)
    try await reader.writeWithoutTransaction { db in
      try db.execute(sql: "BEGIN DEFERRED TRANSACTION")
      _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM wardrobe_items")
    }
    await #expect(throws: WardrobeError.deletionCleanupPending) {
      try await store.delete(id: item.id, expectedRevision: 1, impact: .init(plans: []), policy: .redactSnapshots)
    }
    #expect(try await store.list(WardrobeFilter()).isEmpty)
    try await reader.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
    try reader.close()
    try await store.delete(id: item.id, expectedRevision: 1, impact: .init(plans: []), policy: .redactSnapshots)
    try await store.close()
    #expect(try Data(contentsOf: fixture.database).range(of: Data(item.input.name.utf8)) == nil)
  }

  @Test func concurrentRetriesCommitOnlyOneIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let id = UUID()
    let input = try fixture.input()
    try await withThrowingTaskGroup(of: WardrobeItem.self) { group in
      for _ in 0..<12 {
        group.addTask { try await store.create(id: id, input: input, source: .wardrobe) }
      }
      for try await result in group { #expect(result.id == id && result.revision == 1) }
    }
    #expect(try await store.list(WardrobeFilter()).count == 1)
    try await store.close()
  }

  @Test func schemaAndLongUnicodeName() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let name = String(repeating: "👨‍👩‍👧‍👦", count: 80)
    let item = try await store.create(id: UUID(), input: fixture.input(name), source: .wardrobe)
    #expect(try await store.list(WardrobeFilter()).first == item)
    #expect(try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    let database = try DatabaseQueue(path: fixture.database.path)
    let tables = try await database.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    }
    #expect(tables == ["grdb_migrations", "outfit_plan_items", "outfit_plan_mutations", "outfit_plans", "wardrobe_items", "wardrobe_photos"])
    #expect(try await database.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") } == "wal")
    try database.close()
    try await store.close()
  }

  @Test(.enabled(if: Self.hasPhysicalDataProtection,
                 "Complete 文件保护需真机验证；模拟器不提供该属性，不能据此认领通过"))
  func physicalFilesUseCompleteProtection() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = fixture.store()
    _ = try await store.create(id: UUID(), input: fixture.input(), source: .wardrobe)
    let files = FileManager.default
    let urls = [fixture.directory] + (try files.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil))
    for url in urls {
      let attributes = try files.attributesOfItem(atPath: url.path)
      #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
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

  private nonisolated struct Fixture {
    let root: URL
    var directory: URL { root.appendingPathComponent("OOTD") }
    var database: URL { directory.appendingPathComponent("wardrobe.sqlite") }
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func store() -> GRDBWardrobeRepository { GRDBWardrobeRepository(directory: directory) }
    func input(_ name: String = "白色 T 恤", availability: WardrobeAvailability = .wearable) throws -> WardrobeInput {
      try WardrobeInput(name: name, category: .top, availability: availability)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
