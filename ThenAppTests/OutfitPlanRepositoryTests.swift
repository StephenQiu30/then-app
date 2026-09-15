import Foundation
import GRDB
import Testing
@testable import ThenApp

@MainActor @Suite("计划真实数据库与删除")
struct OutfitPlanRepositoryTests {
  private func withStore(_ body: (GRDBWardrobeRepository, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = GRDBWardrobeRepository(directory: root)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Could not clean synthetic outfit store") }
    }
    do { try await store.prepare(); try await body(store, root); try await store.close() }
    catch { try await store.close(); throw error }
  }

  private func item(_ store: GRDBWardrobeRepository, name: String = "synthetic shirt",
                    status: WardrobeAvailability = .wearable,
                    attributes: WardrobeAttributes = .init()) async throws -> WardrobeItem {
    try await store.create(id: UUID(), input: WardrobeInput(name: name, category: .top,
      availability: status, attributes: attributes), source: .wardrobe)
  }

  private func input(_ items: [WardrobeItem], day: String = "2080-09-13", summary: String? = nil,
                     confirm: Bool = false) throws -> OutfitPlanInput {
    try OutfitPlanInput(localDate: OutfitLocalDate(day), timeZone: "Asia/Shanghai", contextSummary: summary,
      items: items.map { OutfitSelection(itemID: $0.id, revision: $0.revision) },
      confirmedUnavailable: confirm ? Set(items.map(\.id)) : [])
  }

  private func save(_ store: GRDBWardrobeRepository, items: [WardrobeItem]) async throws -> OutfitPlan {
    try #require(try await store.mutatePlan(.init(id: UUID(), planID: UUID(), action: .save(input(items), expectedRevision: nil))))
  }

  @Test("保存快照、重启、同日多个计划与当前属性分离")
  func snapshotsAndRestart() async throws {
    try await withStore { store, root in
      let originalAttributes = WardrobeAttributes(formalityBand: .casual, warmthBand: .light,
        rainUse: .unsuitable, walkingUse: .suitable)
      let original = try await item(store, attributes: originalAttributes)
      let first = try await save(store, items: [original])
      _ = try await save(store, items: [original])
      let currentAttributes = WardrobeAttributes(formalityBand: .formal, warmthBand: .warm,
        rainUse: .suitable, walkingUse: .unsuitable)
      let updated = try await store.update(id: original.id, expectedRevision: 1,
        input: WardrobeInput(name: "renamed current item", category: .bottom, availability: .laundry,
          attributes: currentAttributes))
      let read = try await store.readPlan(id: first.id)
      #expect(read.items.first?.content?.input.name == original.input.name)
      #expect(read.items.first?.content?.input.attributes == originalAttributes)
      #expect(read.items.first?.content?.revision == 1 && updated.revision == 2)
      #expect(read.status == .active && read.timeZone == "Asia/Shanghai" && read.localDate.value == "2080-09-13")
      let currentPlan = try #require(try await store.mutatePlan(.init(id: UUID(), planID: UUID(),
        action: .save(input([updated], confirm: true), expectedRevision: nil))))
      #expect(currentPlan.items.first?.content?.input.attributes == currentAttributes)
      try await store.close()
      let reopened = GRDBWardrobeRepository(directory: root)
      try await reopened.prepare()
      let page = try await reopened.listPlans(on: first.localDate, after: nil)
      #expect(page.plans.count == 3 && page.nextCursor == nil)
      #expect(page.plans.first(where: { $0.id == currentPlan.id })?.items.first?.content?.input.attributes
        == currentAttributes)
      #expect(try await reopened.readPlan(id: first.id) == read)
      try await reopened.close()
    }
  }

  @Test("幂等重试、不同内容冲突、永久删除后不复活")
  func idempotencyAndDeletion() async throws {
    try await withStore { store, root in
      let selected = try await item(store)
      let command = try OutfitPlanMutation(id: UUID(), planID: UUID(), action: .save(input([selected], summary: "synthetic scene"), expectedRevision: nil))
      let first = try #require(try await store.mutatePlan(command))
      #expect(try await store.mutatePlan(command) == first)
      let altered = try OutfitPlanMutation(id: command.id, planID: command.planID, action: .save(input([selected], summary: "changed"), expectedRevision: nil))
      await #expect(throws: OutfitPlanError.conflict) { try await store.mutatePlan(altered) }
      let update = try OutfitPlanMutation(id: UUID(), planID: first.id, action: .save(input([selected], summary: "updated"), expectedRevision: 1))
      let second = try #require(try await store.mutatePlan(update))
      #expect(second.revision == 2)
      #expect(try await store.mutatePlan(update) == second)
      let deletion = OutfitPlanMutation(id: UUID(), planID: first.id, action: .delete(expectedRevision: 2))
      #expect(try await store.mutatePlan(deletion) == nil)
      #expect(try await store.mutatePlan(deletion) == nil)
      await #expect(throws: OutfitPlanError.notFound) { try await store.mutatePlan(command) }
      await #expect(throws: OutfitPlanError.notFound) { try await store.mutatePlan(update) }
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      #expect(try await store.list(.init()).count == 1)
      let db = try DatabaseQueue(path: root.appendingPathComponent("wardrobe.sqlite").path)
      let erased = try await db.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outfit_plans WHERE status = 'deleted' AND localDate IS NULL AND timeZone IS NULL AND contextSummary IS NULL AND revision IS NULL")
      }
      #expect(erased == 1)
      #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outfit_plan_mutations WHERE fingerprint IS NOT NULL") } == 0)
      try db.close()
    }
  }

  @Test("过期衣物版本和未确认不可用状态拒绝整单")
  func liveChecks() async throws {
    try await withStore { store, _ in
      let original = try await item(store)
      let newer = try await store.update(id: original.id, expectedRevision: 1,
        input: WardrobeInput(name: original.input.name, category: .top, availability: .laundry,
          attributes: .init()))
      let stale = try OutfitPlanMutation(id: UUID(), planID: UUID(), action: .save(input([original]), expectedRevision: nil))
      await #expect(throws: OutfitPlanError.conflict) { try await store.mutatePlan(stale) }
      let unconfirmed = try OutfitPlanMutation(id: UUID(), planID: UUID(), action: .save(input([newer]), expectedRevision: nil))
      await #expect(throws: OutfitPlanError.unavailableItems) { try await store.mutatePlan(unconfirmed) }
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      let confirmed = try OutfitPlanMutation(id: UUID(), planID: UUID(), action: .save(input([newer], confirm: true), expectedRevision: nil))
      #expect(try await store.mutatePlan(confirmed)?.items.first?.content?.input.availability == .laundry)
      let past = try OutfitPlanMutation(id: UUID(), planID: UUID(), action: .save(input([newer], day: "2020-01-01", confirm: true), expectedRevision: nil))
      await #expect(throws: OutfitPlanError.invalidDate) { try await store.mutatePlan(past) }
    }
  }

  @Test("第二个快照写入失败回滚计划与收据，原命令可重试")
  func transactionFailure() async throws {
    try await withStore { store, root in
      let first = try await item(store), second = try await item(store, name: "synthetic second")
      let command = try OutfitPlanMutation(id: UUID(), planID: UUID(), action: .save(input([first, second]), expectedRevision: nil))
      let db = try DatabaseQueue(path: root.appendingPathComponent("wardrobe.sqlite").path)
      try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_second BEFORE INSERT ON outfit_plan_items WHEN NEW.ordinal = 1 BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
      await #expect(throws: WardrobeError.storageUnavailable) { try await store.mutatePlan(command) }
      let counts = try await db.read { db in
        try ["outfit_plans", "outfit_plan_items", "outfit_plan_mutations"].map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM " + $0) }
      }
      #expect(counts == [0, 0, 0])
      try await db.write { try $0.execute(sql: "DROP TRIGGER reject_second") }
      #expect(try await store.mutatePlan(command)?.items.count == 2)
      try db.close()
    }
  }

  @Test("衣物彻底删除分别执行占位与删除关联计划", arguments: [false, true])
  func wardrobeDeletion(_ erasePlans: Bool) async throws {
    try await withStore { store, root in
      let first = try await item(store, name: "synthetic erased attributes",
        attributes: .init(formalityBand: .formal, warmthBand: .warm,
          rainUse: .suitable, walkingUse: .unsuitable))
      let kept = try await item(store, name: "synthetic kept")
      let plan = try await save(store, items: [first, kept])
      let impact = try await store.deletionImpact(id: first.id)
      #expect(impact.plans == [.init(id: plan.id, revision: 1)])
      try await store.delete(id: first.id, expectedRevision: 1, impact: impact,
                             policy: erasePlans ? .deleteAffectedPlans : .redactSnapshots)
      if erasePlans {
        await #expect(throws: OutfitPlanError.notFound) { try await store.readPlan(id: plan.id) }
      } else {
        let read = try await store.readPlan(id: plan.id)
        #expect(read.revision == 2 && read.items[0].content == nil)
        #expect(read.items[1].content?.input.name == kept.input.name)
      }
      let db = try DatabaseQueue(path: root.appendingPathComponent("wardrobe.sqlite").path)
      let remains = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM outfit_plan_items WHERE wardrobeItemID = ? OR name = ?",
                                                        arguments: [first.id.uuidString, first.input.name]) }
      #expect(remains == 0)
      if !erasePlans {
        let fullyRedacted = try await db.read { db in
          guard let row = try Row.fetchOne(db,
            sql: "SELECT * FROM outfit_plan_items WHERE planID = ? AND ordinal = 0",
            arguments: [plan.id.uuidString]) else { return false }
          return (row["redacted"] as Int) == 1
            && ["formalityBand", "warmthBand", "rainUse", "walkingUse"]
              .allSatisfy { row[$0] == DatabaseValue.null }
        }
        #expect(fullyRedacted)
        do {
          try await db.write { db in
            try db.execute(sql: "UPDATE outfit_plan_items SET formalityBand = 'formal' WHERE planID = ? AND ordinal = 0",
              arguments: [plan.id.uuidString])
          }
          Issue.record("Expected redacted attribute trigger to reject the update")
        } catch {}
      }
      #expect(try await store.list(.init()).map(\.id) == [kept.id])
      try db.close()
    }
  }

  @Test("确认后新增关联使删除失败，不部分处理历史")
  func deletionImpactRace() async throws {
    try await withStore { store, _ in
      let selected = try await item(store)
      let reviewed = try await store.deletionImpact(id: selected.id)
      let plan = try await save(store, items: [selected])
      await #expect(throws: WardrobeError.conflict) {
        try await store.delete(id: selected.id, expectedRevision: 1, impact: reviewed, policy: .deleteAffectedPlans)
      }
      #expect(try await store.readPlan(id: plan.id).revision == 1)
      #expect(try await store.list(.init()).count == 1)
    }
  }

  @Test("取消只改变计划状态，稳定游标不漏同日记录")
  func cancelAndPages() async throws {
    try await withStore { store, _ in
      let selected = try await item(store)
      for _ in 0..<51 { _ = try await save(store, items: [selected]) }
      let first = try await store.listPlans(on: nil, after: nil)
      #expect(first.plans.count == 50)
      let cursor = try #require(first.nextCursor)
      let second = try await store.listPlans(on: nil, after: cursor)
      #expect(second.plans.count == 1 && second.nextCursor == nil)
      #expect(Set((first.plans + second.plans).map(\.id)).count == 51)
      let plan = try #require(first.plans.first)
      let cancel = OutfitPlanMutation(id: UUID(), planID: plan.id, action: .cancel(expectedRevision: 1))
      let result = try #require(try await store.mutatePlan(cancel))
      #expect(result.status == .cancelled && result.revision == 2 && result.items == plan.items)
      #expect(try await store.mutatePlan(cancel) == result)
      let saveCancelled = try OutfitPlanMutation(id: UUID(), planID: plan.id, action: .save(input([selected]), expectedRevision: 2))
      await #expect(throws: OutfitPlanError.conflict) { try await store.mutatePlan(saveCancelled) }
    }
  }
  private func photo(_ marker: String) throws -> WardrobePhotoWrite {
    let image = try WardrobeEncodedImage(bytes: Data(marker.utf8), format: .png, width: 1, height: 1, maximumBytes: 1024)
    return try WardrobePhotoWrite(id: UUID(), thumbnailID: UUID(), normalized: image, thumbnail: image, quality: .catalogReady)
  }

  @Test("真实 v3 衣物与媒体升级不改 UUID、版本或文件内容")
  func v3Upgrade() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = try DatabasePool(path: root.appendingPathComponent("wardrobe.sqlite").path)
    try OOTDSchema.migrator.migrate(pool, upTo: "ootd_v3_unattached_photo_imports")
    let id = UUID(), image = try photo("synthetic v3 storage bytes")
    try await pool.write { db in
      try db.execute(sql: "INSERT INTO wardrobe_items VALUES (?, 'v3 preserved', 'top', 'wearable', 'wardrobe', 1, 1000, 1000)", arguments: [id.uuidString])
    }
    let before = try WardrobePhotoPersistence(pool: pool, directory: root).save(image, itemID: id, expectedRevision: 1)
    try pool.close()
    let store = GRDBWardrobeRepository(directory: root)
    try await store.prepare()
    let garment = try #require(try await store.list(.init()).first)
    #expect(garment.id == id && garment.revision == 2 && garment.input.name == "v3 preserved")
    let after = try #require(try await store.readPhoto(itemID: id, purpose: .normalized, maximumBytes: 1024))
    #expect(after.metadata == before.metadata && after.bytes == image.normalized.bytes)
    let plan = try await save(store, items: [garment])
    #expect(plan.items.first?.content?.photoAssetID == image.id)
    try await store.close()
  }

  @Test("照片替换与移除清空历史引用，不指向新图")
  func photoLifecycle() async throws {
    try await withStore { store, _ in
      let attributes = WardrobeAttributes(formalityBand: .smartCasual, warmthBand: .medium,
        rainUse: .unsuitable, walkingUse: .suitable)
      let original = try await item(store, attributes: attributes)
      let old = try photo("old synthetic"), next = try photo("new synthetic")
      _ = try await store.savePhoto(old, itemID: original.id, expectedRevision: 1)
      let selected = try #require(try await store.list(.init()).first)
      #expect(selected.input.attributes == attributes)
      let first = try await save(store, items: [selected])
      #expect(first.items[0].content?.photoAssetID == old.id)
      _ = try await store.savePhoto(next, itemID: selected.id, expectedRevision: 2)
      #expect(try await store.list(.init()).first?.input.attributes == attributes)
      #expect(try await store.readPlan(id: first.id).items[0].content?.photoAssetID == nil)
      let current = try #require(try await store.list(.init()).first)
      let second = try await save(store, items: [current])
      #expect(second.items[0].content?.photoAssetID == next.id)
      try await store.removePhoto(id: next.id, itemID: current.id, expectedRevision: 3)
      #expect(try await store.list(.init()).first?.input.attributes == attributes)
      #expect(try await store.readPlan(id: second.id).items[0].content?.photoAssetID == nil)
    }
  }

  @Test("历史清除失败回滚衣物、快照和照片删除意图")
  func historyDeletionRollback() async throws {
    try await withStore { store, root in
      let original = try await item(store), image = try photo("rollback synthetic")
      _ = try await store.savePhoto(image, itemID: original.id, expectedRevision: 1)
      let selected = try #require(try await store.list(.init()).first)
      let plan = try await save(store, items: [selected])
      let impact = try await store.deletionImpact(id: selected.id)
      let db = try DatabaseQueue(path: root.appendingPathComponent("wardrobe.sqlite").path)
      try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_history BEFORE UPDATE ON outfit_plan_items BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
      await #expect(throws: WardrobeError.storageUnavailable) {
        try await store.delete(id: selected.id, expectedRevision: 2, impact: impact, policy: .redactSnapshots)
      }
      #expect(try await store.readPlan(id: plan.id) == plan)
      #expect(try await store.photoMetadata(itemID: selected.id)?.id == image.id)
      #expect(try await store.list(.init()).count == 1)
      try await db.write { try $0.execute(sql: "DROP TRIGGER reject_history") }
      try await store.delete(id: selected.id, expectedRevision: 2, impact: impact, policy: .redactSnapshots)
      #expect(try await store.readPlan(id: plan.id).items[0].content == nil)
      #expect(try await store.photoMetadata(itemID: selected.id) == nil)
      try db.close()
    }
  }

}
