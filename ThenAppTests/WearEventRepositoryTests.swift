import Foundation
import GRDB
import Testing
@testable import ThenApp

struct WearEventRepositoryTests {
  private struct Fixture {
    let root: URL
    let store: GRDBWardrobeRepository

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      store = GRDBWardrobeRepository(directory: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private func item(_ store: GRDBWardrobeRepository, name: String = "合成测试上衣") async throws -> WardrobeItem {
    try await store.create(id: UUID(), input: WardrobeInput(name: name, category: .top,
      availability: .wearable, attributes: .init()), source: .wardrobe)
  }

  private func date() throws -> OutfitLocalDate {
    try OutfitLocalDate(instant: Date(), timeZone: "Asia/Shanghai")
  }

  private func plan(_ store: GRDBWardrobeRepository, item: WardrobeItem) async throws -> OutfitPlan {
    let input = try OutfitPlanInput(localDate: date(), timeZone: "Asia/Shanghai", contextSummary: "合成计划",
      items: [.init(itemID: item.id, revision: item.revision)])
    return try #require(try await store.mutatePlan(.init(id: UUID(), planID: UUID(), action: .save(input,
      expectedRevision: nil))))
  }

  private func input(_ item: WardrobeItem, plan: OutfitPlan? = nil,
                     laundry: Bool = false, confirmation: Set<WearEventCandidate> = []) throws -> WearEventInput {
    try WearEventInput(localDate: date(), timeZone: "Asia/Shanghai", completeness: .partial,
      contextSummary: "合成实际记录", items: [.init(itemID: item.id, revision: item.revision)],
      laundryItemIDs: laundry ? [item.id] : [], sourcePlanID: plan?.id,
      sourcePlanRevision: plan?.revision, sourceKind: plan == nil ? .unplanned : .followedPlan,
      duplicateConfirmation: confirmation)
  }

  @Test func actualWearCompletesPlanAndDeletionRestoresActiveWithoutRevertingLaundry() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let originalPlan = try await plan(fixture.store, item: garment)
    let eventID = UUID()
    let event = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: eventID,
      action: .save(input(garment, plan: originalPlan, laundry: true), expectedRevision: nil))))
    #expect(event.sourcePlanID == originalPlan.id)
    #expect(event.completeness == .partial)
    #expect(try await fixture.store.readPlan(id: originalPlan.id).status == .completed)
    #expect(try await fixture.store.wearCount(itemID: garment.id) == 1)
    #expect(try await fixture.store.list(.init(availability: .laundry)).first?.id == garment.id)

    _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: event.id,
      action: .delete(expectedRevision: event.revision)))
    #expect(try await fixture.store.readPlan(id: originalPlan.id).status == .active)
    #expect(try await fixture.store.wearCount(itemID: garment.id) == 0)
    #expect(try await fixture.store.list(.init(availability: .laundry)).first?.id == garment.id)
    try await fixture.store.close()
  }

  @Test func duplicateRequiresExactCandidateRevisionAndExplicitSecondSave() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let first = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(input(garment), expectedRevision: nil))))
    let secondID = UUID()
    do {
      _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: secondID,
        action: .save(input(garment), expectedRevision: nil)))
      Issue.record("Expected duplicate confirmation")
    } catch WearEventError.duplicateConfirmationRequired(let candidates) {
      #expect(candidates == [.init(id: first.id, revision: first.revision)])
      let saved = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: secondID,
        action: .save(input(garment, confirmation: Set(candidates)), expectedRevision: nil))))
      #expect(saved.id == secondID)
    }
    #expect(try await fixture.store.wearCount(itemID: garment.id) == 2)
    try await fixture.store.close()
  }

  @Test func mutationRetryIsIdempotentAndChangedPayloadConflicts() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let mutationID = UUID(), eventID = UUID()
    let command = WearEventMutation(id: mutationID, eventID: eventID,
      action: .save(try input(garment), expectedRevision: nil))
    let first = try #require(try await fixture.store.mutateWearEvent(command))
    #expect(try await fixture.store.mutateWearEvent(command) == first)
    try await withThrowingTaskGroup(of: WearEvent?.self) { group in
      for _ in 0..<8 { group.addTask { try await fixture.store.mutateWearEvent(command) } }
      for try await result in group { #expect(result == first) }
    }
    let changed = try WearEventInput(localDate: date(), timeZone: "Asia/Shanghai", completeness: .complete,
      contextSummary: "不同正文", items: [.init(itemID: garment.id, revision: garment.revision)])
    await #expect(throws: WearEventError.conflict) {
      try await fixture.store.mutateWearEvent(.init(id: mutationID, eventID: eventID,
        action: .save(changed, expectedRevision: nil)))
    }
    #expect(try await fixture.store.wearCount(itemID: garment.id) == 1)
    try await fixture.store.close()
  }

  @Test func duplicateSimilarityUsesInclusivePointEightBoundary() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    var garments: [WardrobeItem] = []
    for index in 0..<5 { garments.append(try await item(fixture.store, name: "相似度单品 \(index)")) }
    func eventInput(_ items: ArraySlice<WardrobeItem>) throws -> WearEventInput {
      try WearEventInput(localDate: date(), timeZone: "Asia/Shanghai",
        items: items.map { .init(itemID: $0.id, revision: $0.revision) })
    }
    let first = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(eventInput(garments[0..<5]), expectedRevision: nil))))
    await #expect(throws: WearEventError.duplicateConfirmationRequired([.init(id: first.id, revision: 1)])) {
      try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
        action: .save(eventInput(garments[0..<4]), expectedRevision: nil)))
    }
    let distinct = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(eventInput(garments[0..<3]), expectedRevision: nil)))
    #expect(distinct != nil)
    try await fixture.store.close()
  }

  @Test func outcomeFailureRollsBackEventLaundryAndPlanTogether() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let original = try await plan(fixture.store, item: garment)
    let database = try DatabaseQueue(path: fixture.root.appendingPathComponent("wardrobe.sqlite").path)
    try await database.write { db in
      try db.execute(sql: """
        CREATE TRIGGER reject_outcome BEFORE UPDATE ON outfit_plans
        BEGIN SELECT RAISE(ABORT, 'synthetic outcome failure'); END
        """)
    }
    await #expect(throws: WardrobeError.storageUnavailable) {
      try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
        action: .save(input(garment, plan: original, laundry: true), expectedRevision: nil)))
    }
    #expect(try await fixture.store.listWearEvents(on: nil).isEmpty)
    #expect(try await fixture.store.list(.init(availability: .wearable)).map(\.id) == [garment.id])
    #expect(try await fixture.store.readPlan(id: original.id).status == .active)
    try database.close(); try await fixture.store.close()
  }

  @Test func futureActualDateIsRejectedWithoutWrites() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Date()))
    let future = try WearEventInput(localDate: OutfitLocalDate(instant: tomorrow, timeZone: "Asia/Shanghai"),
      timeZone: "Asia/Shanghai", items: [.init(itemID: garment.id, revision: garment.revision)])
    await #expect(throws: WearEventError.invalidDate) {
      try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
        action: .save(future, expectedRevision: nil)))
    }
    #expect(try await fixture.store.listWearEvents(on: nil).isEmpty)
    try await fixture.store.close()
  }

  @Test func notWornNeedsNoActualEventAndCanBeRestored() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let original = try await plan(fixture.store, item: garment)
    let notWorn = try #require(try await fixture.store.mutatePlan(.init(id: UUID(), planID: original.id,
      action: .markNotWorn(expectedRevision: original.revision))))
    #expect(notWorn.status == .notWorn)
    let restored = try #require(try await fixture.store.mutatePlan(.init(id: UUID(), planID: original.id,
      action: .restoreActive(expectedRevision: notWorn.revision))))
    #expect(restored.status == .active)
    let event = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(input(garment, plan: restored), expectedRevision: nil))))
    let completed = try await fixture.store.readPlan(id: original.id)
    await #expect(throws: OutfitPlanError.conflict) {
      try await fixture.store.mutatePlan(.init(id: UUID(), planID: original.id,
        action: .markNotWorn(expectedRevision: completed.revision)))
    }
    #expect(event.sourcePlanID == original.id)
    try await fixture.store.close()
  }

  @Test func deletingPlanUnlinksButPreservesActualEvent() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let original = try await plan(fixture.store, item: garment)
    let event = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(input(garment, plan: original), expectedRevision: nil))))
    let completed = try await fixture.store.readPlan(id: original.id)
    _ = try await fixture.store.mutatePlan(.init(id: UUID(), planID: original.id,
      action: .delete(expectedRevision: completed.revision)))
    let retained = try await fixture.store.readWearEvent(id: event.id)
    #expect(retained.sourcePlanID == nil)
    #expect(retained.sourceKind == .unplanned)
    #expect(retained.revision == event.revision + 1)
    #expect(try await fixture.store.wearCount(itemID: garment.id) == 1)
    try await fixture.store.close()
  }

  @Test func wardrobeDeletionImpactCoversPlansAndActualHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let originalPlan = try await plan(fixture.store, item: garment)
    let event = try #require(try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(input(garment, plan: originalPlan), expectedRevision: nil))))
    let impact = try await fixture.store.deletionImpact(id: garment.id)
    #expect(impact.plans.map(\.id) == [originalPlan.id])
    #expect(impact.wearEvents == [.init(id: event.id, revision: event.revision)])
    try await fixture.store.delete(id: garment.id, expectedRevision: garment.revision,
      impact: impact, policy: .redactSnapshots)
    #expect(try await fixture.store.readWearEvent(id: event.id).items.first?.content == nil)
    #expect(try await fixture.store.readPlan(id: originalPlan.id).items.first?.content == nil)
    #expect(try await fixture.store.wearCount(itemID: garment.id) == 0)
    try await fixture.store.close()
  }

  @Test func currentSchemaHasNoForeignKeyViolationsAndTimelinePagesWithoutDuplicates() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let garment = try await item(fixture.store)
    for index in 0..<31 {
      let input = try WearEventInput(localDate: date(), timeZone: "Asia/Shanghai",
        contextSummary: "合成记录 \(index)", items: [.init(itemID: garment.id, revision: garment.revision)],
        duplicateConfirmation: Set(try await fixture.store.listWearEvents(on: date()).map {
          WearEventCandidate(id: $0.id, revision: $0.revision)
        }))
      _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
        action: .save(input, expectedRevision: nil)))
    }
    let first = try await fixture.store.listTimeline(after: nil)
    guard let cursor = first.nextCursor else { Issue.record("Expected a second timeline page"); return }
    let second = try await fixture.store.listTimeline(after: cursor)
    #expect(first.entries.count == 30)
    #expect(second.entries.count == 1)
    #expect(Set((first.entries + second.entries).map(\.id)).count == 31)
    let database = try DatabaseQueue(path: fixture.root.appendingPathComponent("wardrobe.sqlite").path)
    let violationCount = try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1
    }
    #expect(violationCount == 0)
    try database.close()
    try await fixture.store.close()
  }

  @Test func migrationPreservesAttributedPlanAndMutationWithFinalForeignKeys() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = try DatabasePool(path: root.appendingPathComponent("wardrobe.sqlite").path)
    try OOTDSchema.migrator.migrate(pool, upTo: "ootd_wardrobe_attributes_v1")
    let itemID = UUID(), planID = UUID(), mutationID = UUID()
    try await pool.write { db in
      try db.execute(sql: """
        INSERT INTO wardrobe_items(id, name, category, availability, source, revision, createdAt, updatedAt,
          formalityBand, warmthBand, rainUse, walkingUse)
        VALUES (?, '迁移保留上衣', 'top', 'wearable', 'wardrobe', 3, 1000, 1001,
          'smartCasual', 'medium', 'suitable', 'unsuitable')
        """, arguments: [itemID.uuidString])
      try db.execute(sql: """
        INSERT INTO outfit_plans(id, localDate, timeZone, contextSummary, sourceKind, status, revision, createdAt, updatedAt)
        VALUES (?, '2080-09-16', 'Asia/Shanghai', '迁移保留计划', 'manual', 'active', 2, 1000, 1001)
        """, arguments: [planID.uuidString])
      try db.execute(sql: """
        INSERT INTO outfit_plan_items(planID, ordinal, wardrobeItemID, itemRevision, name, category, availability,
          photoAssetID, redacted, formalityBand, warmthBand, rainUse, walkingUse)
        VALUES (?, 0, ?, 3, '迁移保留上衣', 'top', 'wearable', NULL, 0,
          'smartCasual', 'medium', 'suitable', 'unsuitable')
        """, arguments: [planID.uuidString, itemID.uuidString])
      try db.execute(sql: """
        INSERT INTO outfit_plan_mutations(id, planID, operation, fingerprint)
        VALUES (?, ?, 'save', ?)
        """, arguments: [mutationID.uuidString, planID.uuidString, String(repeating: "a", count: 64)])
    }
    try OOTDSchema.migrator.migrate(pool)
    let preserved = try await pool.read { db -> (String?, String?, Int, [String]) in
      let name = try String.fetchOne(db, sql: "SELECT name FROM outfit_plan_items WHERE planID = ?", arguments: [planID.uuidString])
      let warmth = try String.fetchOne(db, sql: "SELECT warmthBand FROM outfit_plan_items WHERE planID = ?", arguments: [planID.uuidString])
      let violations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1
      let parents = try String.fetchAll(db, sql: "SELECT DISTINCT \"table\" FROM pragma_foreign_key_list('outfit_plan_items')")
      return (name, warmth, violations, parents)
    }
    #expect(preserved.0 == "迁移保留上衣" && preserved.1 == "medium")
    #expect(preserved.2 == 0 && preserved.3.contains("outfit_plans") && !preserved.3.contains("outfit_plans_new"))
    let plan = try OutfitPlanPersistence(pool: pool).read(id: planID)
    #expect(plan.id == planID && plan.revision == 2 && plan.items.first?.content?.revision == 3)
    let receiptOwner = try await pool.read { db in
      try String.fetchOne(db, sql: "SELECT planID FROM outfit_plan_mutations WHERE id = ?", arguments: [mutationID.uuidString])
    }
    #expect(receiptOwner == planID.uuidString)
    try pool.close()
  }

  @Test func timelineKeepsPlanAndActualWhenEntityUUIDsMatch() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let garment = try await item(fixture.store)
    let sharedID = UUID()
    let planInput = try OutfitPlanInput(localDate: date(), timeZone: "Asia/Shanghai",
      contextSummary: "同标识计划", items: [.init(itemID: garment.id, revision: garment.revision)])
    _ = try await fixture.store.mutatePlan(.init(id: UUID(), planID: sharedID,
      action: .save(planInput, expectedRevision: nil)))
    _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: sharedID,
      action: .save(input(garment), expectedRevision: nil)))
    let page = try await fixture.store.listTimeline(after: nil)
    #expect(page.entries.count == 2)
    #expect(Set(page.entries.map(\.id)) == ["plan:\(sharedID.uuidString)", "wear:\(sharedID.uuidString)"])
    try await fixture.store.close()
  }
}
