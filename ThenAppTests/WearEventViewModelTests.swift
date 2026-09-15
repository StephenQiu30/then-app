import Foundation
import Testing
@testable import ThenApp

@MainActor @Suite("实际穿着编辑状态")
struct WearEventViewModelTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: GRDBWardrobeRepository
    init() {
      store = GRDBWardrobeRepository(directory: root)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private func garment(_ store: GRDBWardrobeRepository, name: String = "合成上衣") async throws -> WardrobeItem {
    try await store.create(id: UUID(), input: WardrobeInput(name: name, category: .top,
      availability: .wearable, attributes: .init()), source: .wardrobe)
  }

  @Test("无计划默认部分记录，重复必须明确确认后才计为第二次")
  func unplannedDuplicateConfirmation() async throws {
    let fixture = Fixture(); defer { fixture.remove() }
    let item = try await garment(fixture.store)
    let first = WearEventEditorModel(repository: fixture.store, wardrobe: fixture.store, photos: fixture.store)
    await first.load(); first.toggle(item); first.submit(.save); await first.perform()
    #expect(first.finished && first.event?.completeness == .partial)
    #expect(try await fixture.store.wearCount(itemID: item.id) == 1)

    let second = WearEventEditorModel(repository: fixture.store, wardrobe: fixture.store, photos: fixture.store)
    await second.load(); second.toggle(item); second.submit(.save); await second.perform()
    let firstEvent = try #require(first.event)
    #expect(!second.finished && second.duplicateCandidates == [.init(id: firstEvent.id, revision: 1)])
    second.previewDuplicate(); await second.perform()
    #expect(second.duplicatePreview == firstEvent && !second.showsDuplicateConfirmation)
    second.confirmDuplicate(); await second.perform()
    let count = try await fixture.store.wearCount(itemID: item.id)
    #expect(second.finished && count == 2)
    try await fixture.store.close()
  }

  @Test("从计划复核实际单品和待洗意图，删除事实恢复计划但不恢复衣物状态")
  func planLaundryAndDeletion() async throws {
    let fixture = Fixture(); defer { fixture.remove() }
    let item = try await garment(fixture.store)
    let day = try OutfitLocalDate(instant: Date(), timeZone: "Asia/Shanghai")
    let input = try OutfitPlanInput(localDate: day, timeZone: "Asia/Shanghai", contextSummary: "合成计划",
      items: [.init(itemID: item.id, revision: item.revision)])
    let plan = try #require(try await fixture.store.mutatePlan(.init(id: UUID(), planID: UUID(),
      action: .save(input, expectedRevision: nil))))
    let editor = WearEventEditorModel(sourcePlan: plan, sourceKind: .changedPlan,
      repository: fixture.store, wardrobe: fixture.store, photos: fixture.store)
    await editor.load()
    #expect(editor.selected == [item.id] && editor.completeness == .partial)
    editor.toggleLaundry(item); editor.submit(.save); await editor.perform()
    let event = try #require(editor.event)
    #expect(event.sourceKind == .changedPlan)
    #expect(try await fixture.store.readPlan(id: plan.id).status == .completed)
    #expect(try await fixture.store.list(.init(availability: .laundry)).map(\.id) == [item.id])
    _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: event.id,
      action: .delete(expectedRevision: event.revision)))
    #expect(try await fixture.store.readPlan(id: plan.id).status == .active)
    #expect(try await fixture.store.list(.init(availability: .laundry)).map(\.id) == [item.id])
    try await fixture.store.close()
  }

  @Test("混合时间线展示计划与事实，详情获知外部删除后清空旧内容")
  func timelineAndExternalDeletion() async throws {
    let fixture = Fixture(); defer { fixture.remove() }
    let item = try await garment(fixture.store)
    let writer = WearEventEditorModel(repository: fixture.store, wardrobe: fixture.store, photos: fixture.store)
    await writer.load(); writer.toggle(item); writer.submit(.save); await writer.perform()
    let event = try #require(writer.event)
    let timeline = OutfitPlanViewModel(repository: fixture.store, wardrobe: fixture.store,
      photos: fixture.store, wearEvents: fixture.store)
    await timeline.load()
    #expect(timeline.timelineEntries == [.wear(event)])
    let stale = WearEventEditorModel(event: event, repository: fixture.store,
      wardrobe: fixture.store, photos: fixture.store)
    _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: event.id,
      action: .delete(expectedRevision: event.revision)))
    await stale.load()
    #expect(stale.isDeleted && stale.event == nil && stale.selected.isEmpty && stale.summary.isEmpty)
    try await fixture.store.close()
  }
}
