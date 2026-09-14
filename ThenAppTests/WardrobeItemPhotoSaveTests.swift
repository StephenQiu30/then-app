import Foundation
import GRDB
import Testing
@testable import ThenApp

@Suite("衣物与照片一次保存")
struct WardrobeItemPhotoSaveTests {
  private func input(_ name: String = "synthetic shirt") throws -> WardrobeInput {
    try .init(name: name, category: .top, availability: .wearable)
  }
  private func photo(_ byte: UInt8 = 1) throws -> WardrobePhotoWrite {
    let image = try WardrobeEncodedImage(bytes: Data([byte]), format: .png, width: 1, height: 1, maximumBytes: 1)
    return try .init(id: UUID(), thumbnailID: UUID(), normalized: image, thumbnail: image, quality: .catalogReady)
  }
  private func withStore(_ body: (GRDBWardrobeRepository, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = GRDBWardrobeRepository(directory: root)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Could not remove owned atomic-save fixture") }
    }
    do { try await store.prepare(); try await body(store, root); try await store.close() }
    catch { try await store.close(); throw error }
  }
  private func sql(_ root: URL) throws -> DatabaseQueue {
    try DatabaseQueue(path: root.appendingPathComponent("wardrobe.sqlite").path)
  }

  @Test("新增衣物和照片同时成功，重复保存保留一份与同一 revision")
  func createAndRetry() async throws {
    try await withStore { store, _ in
      let edit = try WardrobeItemPhotoEdit(id: UUID(), input: input(), source: .quickAdd, expectedRevision: nil)
      let photo = try photo()
      let saved = try await store.saveItemWithPhoto(edit, photo: photo)
      let retry = try await store.saveItemWithPhoto(edit, photo: photo)
      #expect(saved.item == retry.item && saved.photo == retry.photo)
      #expect(saved.item.revision == 1 && saved.item.source == .quickAdd)
      #expect(!saved.cleanupPending && !retry.cleanupPending)
      #expect(try await store.list(.init()).count == 1)
      let read = try #require(try await store.readPhoto(itemID: edit.id, purpose: .normalized, maximumBytes: 1))
      #expect(read.bytes == photo.normalized.bytes)
      try await store.close()
      try await store.prepare()
      #expect(try await store.list(.init()).first == saved.item)
    }
  }

  @Test("最终衣物或照片 SQL 失败没有半完成新增，原命令可重试", arguments: [false, true])
  func createCommitFailure(_ failPhoto: Bool) async throws {
    try await withStore { store, root in
      let database = try sql(root)
      let trigger = failPhoto
        ? "CREATE TRIGGER reject_save BEFORE UPDATE OF state ON wardrobe_photos WHEN NEW.state = 'ready' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
        : "CREATE TRIGGER reject_save BEFORE INSERT ON wardrobe_items BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
      try await database.write { try $0.execute(sql: trigger) }
      let edit = try WardrobeItemPhotoEdit(id: UUID(), input: input(), source: .wardrobe, expectedRevision: nil)
      let photo = try photo()
      await #expect(throws: WardrobeError.storageUnavailable) { try await store.saveItemWithPhoto(edit, photo: photo) }
      #expect(try await store.list(.init(availability: nil)).isEmpty)
      #expect(try await store.hasPendingPhotoCleanup() == false)
      #expect(try await store.readPhoto(itemID: edit.id, purpose: .normalized, maximumBytes: 1) == nil)
      let media = root.appendingPathComponent("WardrobeMedia")
      let files = try FileManager.default.contentsOfDirectory(atPath: media.path)
      #expect(files.isEmpty)
      try await database.write { try $0.execute(sql: "DROP TRIGGER reject_save") }
      try database.close()
      let saved = try await store.saveItemWithPhoto(edit, photo: photo)
      #expect(saved.item.id == edit.id && saved.item.revision == 1)
    }
  }

  @Test("文件根失败不创建衣物，不认领或删除已有文件")
  func fileFailure() async throws {
    try await withStore { store, root in
      let existing = root.appendingPathComponent("WardrobeMedia")
      let marker = Data([42])
      try marker.write(to: existing)
      let edit = try WardrobeItemPhotoEdit(id: UUID(), input: input(), source: .wardrobe, expectedRevision: nil)
      await #expect(throws: WardrobeError.storageUnavailable) { try await store.saveItemWithPhoto(edit, photo: photo()) }
      #expect(try await store.list(.init()).isEmpty)
      #expect(try Data(contentsOf: existing) == marker)
    }
  }

  @Test("换图提交失败保留旧字段、旧图和 revision，成功只增加一次")
  func replaceCommitFailure() async throws {
    try await withStore { store, root in
      let first = try WardrobeItemPhotoEdit(id: UUID(), input: input("before"), source: .wardrobe, expectedRevision: nil)
      let oldPhoto = try photo()
      let old = try await store.saveItemWithPhoto(first, photo: oldPhoto)
      let edit = try WardrobeItemPhotoEdit(id: first.id, input: input("after"), source: .wardrobe, expectedRevision: old.item.revision)
      let replacement = try photo(2)
      let database = try sql(root)
      try await database.write { db in
        try db.execute(sql: "CREATE TRIGGER reject_save BEFORE UPDATE OF state ON wardrobe_photos WHEN NEW.state = 'ready' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
      }
      await #expect(throws: WardrobeError.storageUnavailable) { try await store.saveItemWithPhoto(edit, photo: replacement) }
      #expect(try await store.list(.init()).first == old.item)
      #expect(try await store.readPhoto(itemID: first.id, purpose: .normalized, maximumBytes: 1)?.metadata.id == oldPhoto.id)
      try await database.write { try $0.execute(sql: "DROP TRIGGER reject_save") }
      try database.close()
      let saved = try await store.saveItemWithPhoto(edit, photo: replacement)
      #expect(saved.item.input.name == "after" && saved.item.revision == old.item.revision + 1)
      #expect(saved.photo.id == replacement.id)
      let retry = try await store.saveItemWithPhoto(edit, photo: replacement)
      #expect(retry.item == saved.item)
      let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("WardrobeMedia").path)
      #expect(files == ["photo-" + replacement.id.uuidString])
    }
  }

  @Test("已提交照片命令不能改字段、source 或绑定对象", arguments: 0..<3)
  func changedRetry(_ change: Int) async throws {
    try await withStore { store, _ in
      let edit = try WardrobeItemPhotoEdit(id: UUID(), input: input(), source: .wardrobe, expectedRevision: nil)
      let photo = try photo()
      let saved = try await store.saveItemWithPhoto(edit, photo: photo)
      let altered = try WardrobeItemPhotoEdit(id: change == 0 ? UUID() : edit.id,
        input: input(change == 1 ? "changed" : "synthetic shirt"),
        source: change == 2 ? .quickAdd : .wardrobe, expectedRevision: nil)
      await #expect(throws: WardrobeError.conflict) { try await store.saveItemWithPhoto(altered, photo: photo) }
      #expect(try await store.list(.init()).first == saved.item)
    }
  }

  @Test("过期更新和误当新增不能覆盖已有衣物", arguments: [false, true])
  func staleRevision(_ create: Bool) async throws {
    try await withStore { store, _ in
      let original = try await store.create(id: UUID(), input: input(), source: .wardrobe)
      let updated = try await store.update(id: original.id, expectedRevision: 1, input: input("newer"))
      let edit = try WardrobeItemPhotoEdit(id: original.id, input: input("stale"), source: .wardrobe, expectedRevision: create ? nil : 1)
      await #expect(throws: WardrobeError.conflict) { try await store.saveItemWithPhoto(edit, photo: photo()) }
      #expect(try await store.list(.init()).first == updated)
      #expect(try await store.hasPendingPhotoCleanup() == false)
    }
  }

  @Test("无绑定 importing 重启清理，ready 无绑定仍被数据库拒绝")
  func unattachedRecovery() async throws {
    try await withStore { store, root in
      let edit = try WardrobeItemPhotoEdit(id: UUID(), input: input(), source: .wardrobe, expectedRevision: nil)
      let photo = try photo()
      let saved = try await store.saveItemWithPhoto(edit, photo: photo)
      try await store.close()
      let database = try sql(root)
      await #expect(throws: (any Error).self) {
        try await database.write { try $0.execute(sql: "UPDATE wardrobe_photos SET itemID = NULL WHERE id = ?", arguments: [photo.id.uuidString]) }
      }
      try await database.write { db in
        try db.execute(sql: "UPDATE wardrobe_photos SET state = 'importing', itemID = NULL WHERE id = ?", arguments: [photo.id.uuidString])
      }
      try database.close()
      try await store.prepare()
      #expect(try await store.list(.init()).first == saved.item)
      #expect(try await store.readPhoto(itemID: edit.id, purpose: .normalized, maximumBytes: 1) == nil)
      #expect(try await store.hasPendingPhotoCleanup() == false)
      let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("WardrobeMedia").path)
      #expect(files.isEmpty)
    }
  }

  @Test("实际 v2 图文数据升级到当前结构后字段、照片与文件不变")
  func v2Upgrade() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Could not remove migration fixture") }
    }
    let id = UUID(), image = try photo()
    let database = try sql(root)
    try OOTDSchema.migrator.migrate(database, upTo: "ootd_v2_wardrobe_photos")
    try await database.write { db in
      try db.execute(sql: "INSERT INTO wardrobe_items VALUES (?, 'v2 garment', 'top', 'wearable', 'wardrobe', 3, 1000, 1000)", arguments: [id.uuidString])
      try db.execute(sql: """
        INSERT INTO wardrobe_photos VALUES (?, ?, ?, 'ready', 1, 'catalog_ready',
          'png', 1, 1, 1, ?, ?, 'png', 1, 1, 1, ?, ?, 1000)
        """, arguments: [image.id.uuidString, id.uuidString, image.thumbnailID.uuidString,
          WardrobePhotoPersistence.hash(image.normalized.bytes), "photo-\(image.id.uuidString)/normalized.image",
          WardrobePhotoPersistence.hash(image.thumbnail.bytes), "photo-\(image.id.uuidString)/thumbnail.image"])
    }
    try database.close()
    let folder = root.appendingPathComponent("WardrobeMedia/photo-" + image.id.uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try image.normalized.bytes.write(to: folder.appendingPathComponent("normalized.image"))
    try image.thumbnail.bytes.write(to: folder.appendingPathComponent("thumbnail.image"))
    let store = GRDBWardrobeRepository(directory: root)
    do {
      try await store.prepare()
      let item = try #require(try await store.list(.init()).first)
      #expect(item.id == id && item.revision == 3 && item.input.name == "v2 garment")
      let read = try #require(try await store.readPhoto(itemID: id, purpose: .normalized, maximumBytes: 1))
      #expect(read.metadata.id == image.id && read.bytes == image.normalized.bytes)
      let upgraded = try sql(root)
      let versions = try await upgraded.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") }
      #expect(versions.last == "ootd_v4_outfit_plans")
      let indexes = try await upgraded.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='wardrobe_photos'") }
      #expect(indexes.contains("wardrobe_one_ready_photo") && indexes.contains("wardrobe_photo_cleanup"))
      try upgraded.close()
      try await store.close()
    } catch { try await store.close(); throw error }
  }
}
