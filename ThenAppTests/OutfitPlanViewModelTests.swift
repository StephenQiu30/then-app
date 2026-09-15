import Foundation
import Testing
@testable import ThenApp

@MainActor @Suite("计划编辑状态")
struct OutfitPlanViewModelTests {
  private func fixture(_ body: (GRDBWardrobeRepository, WardrobeItem) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = GRDBWardrobeRepository(directory: root)
    do {
      let item = try await store.create(id: UUID(), input: WardrobeInput(name: "synthetic choice",
        category: .top, availability: .wearable, attributes: .init()), source: .wardrobe)
      try await body(store, item)
      try await store.close()
    } catch { try await store.close(); throw error }
    try FileManager.default.removeItem(at: root)
  }

  @Test("加载更多只影响一次请求，重新进入时间线读取删除和取消后的事实", arguments: [false, true])
  func timelineReentryAfterPagination(deletes: Bool) async throws {
    try await fixture { store, item in
      let input = try OutfitPlanInput(localDate: OutfitLocalDate("2080-09-14"), timeZone: "Asia/Shanghai",
        contextSummary: "synthetic paginated plan", items: [.init(itemID: item.id, revision: item.revision)])
      for _ in 0..<51 {
        _ = try await store.mutatePlan(.init(id: UUID(), planID: UUID(), action: .save(input, expectedRevision: nil)))
      }
      let timeline = OutfitPlanViewModel(repository: store, wardrobe: store, photos: store)
      await timeline.load()
      #expect(timeline.plans.count == 50 && timeline.cursor != nil)
      let changed = try #require(timeline.plans.first)
      timeline.loadMore(); await timeline.load()
      #expect(timeline.plans.count == 51 && timeline.cursor == nil)
      let action: OutfitPlanMutation.Action = deletes
        ? .delete(expectedRevision: changed.revision) : .cancel(expectedRevision: changed.revision)
      _ = try await store.mutatePlan(.init(id: UUID(), planID: changed.id, action: action))
      // A recreated SwiftUI list runs its task without a load-more button event.
      await timeline.load()
      let current = try await store.listPlans(on: nil, after: nil)
      #expect(timeline.plans == current.plans && timeline.cursor == current.nextCursor)
      #expect(timeline.error == nil && !timeline.isLoading)
      if deletes { #expect(!timeline.plans.contains { $0.id == changed.id }) }
      else { #expect(timeline.plans.first { $0.id == changed.id }?.status == .cancelled) }
      if timeline.cursor != nil {
        timeline.loadMore(); await timeline.load()
        #expect(timeline.plans.count == 51 && timeline.cursor == nil)
      }
      #expect(try await store.list(.init()).map(\.id) == [item.id])
    }
  }

  @Test("输入错误保留草稿，选择真实单品后保存一次")
  func validationAndSave() async throws {
    try await fixture { store, item in
      let draft = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await draft.load()
      draft.summary = "synthetic plan"
      draft.submit(.save); await draft.perform()
      #expect(draft.error != nil && !draft.finished && draft.summary == "synthetic plan")
      draft.toggle(item)
      draft.submit(.save); draft.submit(.save)
      #expect(draft.request == 2)
      await draft.perform()
      #expect(draft.finished && draft.error == nil)
      let page = try await store.listPlans(on: nil, after: nil)
      #expect(page.plans.count == 1)
    }
  }

  @Test("冲突保留选择，刷新后必须重新确认当前差异和不可穿状态")
  func conflictReview() async throws {
    try await fixture { store, item in
      let draft = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await draft.load(); draft.toggle(item)
      _ = try await store.update(id: item.id, expectedRevision: 1,
        input: WardrobeInput(name: "updated synthetic", category: .top, availability: .laundry,
          attributes: .init()))
      draft.submit(.save); await draft.perform()
      #expect(draft.needsRefresh && draft.selected == [item.id] && !draft.finished)
      draft.submit(.refresh); await draft.perform()
      #expect(draft.hasChanges && !draft.confirmsChanges && draft.unavailable.count == 1)
      draft.confirmsChanges = true; draft.confirmsUnavailable = true
      draft.submit(.save); await draft.perform()
      #expect(draft.finished)
      let plan = try #require(try await store.listPlans(on: nil, after: nil).plans.first)
      #expect(plan.items[0].content?.revision == 2)
      #expect(plan.items[0].content?.input.name == "updated synthetic")
    }
  }

  @Test("跨类别筛选不清空有序选择，已选区移除后保存真实剩余单品")
  func filteredSelectionPreservesOrder() async throws {
    try await fixture { store, top in
      let bottom = try await store.create(id: UUID(), input: WardrobeInput(name: "synthetic trousers",
        category: .bottom, availability: .wearable, attributes: .init()), source: .wardrobe)
      let draft = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await draft.load()
      draft.choiceCategory = .bottom
      #expect(draft.visibleChoices.map(\.id) == [bottom.id])
      draft.toggle(bottom)
      draft.choiceCategory = .top
      draft.toggle(top)
      #expect(draft.visibleChoices.map(\.id) == [top.id])
      #expect(draft.selectedChoices.map(\.id) == [bottom.id, top.id])
      draft.choiceCategory = .shoes
      #expect(draft.visibleChoices.isEmpty && draft.selected.count == 2)
      draft.toggle(bottom)
      #expect(draft.selectedChoices.map(\.id) == [top.id])
      draft.choiceCategory = nil
      #expect(draft.visibleChoices.count == 2)
      draft.submit(.save); await draft.perform()
      let saved = try #require(draft.plan)
      #expect(draft.finished && saved.items.compactMap { $0.content?.itemID } == [top.id])
    }
  }

  @Test("筛选和已选区共用二十件上限，移除后允许新项并保持顺序")
  func selectionLimitAcrossCategories() async throws {
    try await fixture { store, first in
      var items = [first]
      for number in 1...20 {
        let item = try await store.create(id: UUID(), input: WardrobeInput(name: "synthetic choice \(number)",
          category: number.isMultiple(of: 2) ? .bottom : .top, availability: .wearable,
          attributes: .init()), source: .wardrobe)
        items.append(item)
      }
      let draft = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await draft.load()
      for item in items.prefix(20) { draft.choiceCategory = item.input.category; draft.toggle(item) }
      draft.toggle(items[20])
      #expect(draft.selected == Array(items.prefix(20)).map(\.id) && draft.error != nil)
      draft.toggle(first); draft.toggle(items[20])
      #expect(draft.selectedChoices.map(\.id) == Array(items.dropFirst()).map(\.id))
      draft.submit(.save); await draft.perform()
      #expect(draft.finished && draft.plan?.items.count == 20)
    }
  }

  @Test("删除占位无法直接重存，主动移除后可保存剩余真实衣物")
  func redactedEdit() async throws {
    try await fixture { store, item in
      let second = try await store.create(id: UUID(), input: WardrobeInput(name: "second synthetic",
        category: .bottom, availability: .wearable, attributes: .init()), source: .wardrobe)
      let initial = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await initial.load(); initial.toggle(item); initial.toggle(second)
      initial.submit(.save); await initial.perform()
      let saved = try #require(initial.plan)
      let impact = try await store.deletionImpact(id: item.id)
      try await store.delete(id: item.id, expectedRevision: 1, impact: impact, policy: .redactSnapshots)
      let current = try await store.readPlan(id: saved.id)
      let edit = OutfitPlanEditorModel(plan: current, repository: store, wardrobe: store, photos: store)
      await edit.load(); edit.submit(.edit); await edit.perform()
      #expect(edit.removedPlaceholders == 1 && edit.selected == [second.id])
      edit.submit(.save); await edit.perform()
      #expect(!edit.finished)
      edit.submit(.refresh); await edit.perform(); edit.removedPlaceholders = 0
      edit.submit(.save); await edit.perform()
      #expect(edit.finished && edit.plan?.items.count == 1)
    }
  }

  @Test("提交后响应丢失重试不重复，取消和永久删除互不混用 mutation")
  func lostReplyAndDeletion() async throws {
    try await fixture { store, item in
      let provider = LostReply(store: store)
      let draft = OutfitPlanEditorModel(plan: nil, repository: provider, wardrobe: store, photos: store)
      await draft.load(); draft.toggle(item)
      draft.submit(.save); await draft.perform()
      #expect(!draft.finished && draft.selected == [item.id])
      draft.submit(.save); await draft.perform()
      #expect(draft.finished && draft.plan?.revision == 1)
      let saved = try #require(draft.plan)
      let detail = OutfitPlanEditorModel(plan: saved, repository: store, wardrobe: store, photos: store)
      await detail.load(); detail.submit(.cancel); await detail.perform()
      #expect(detail.plan?.status == .cancelled)
      detail.submit(.delete); await detail.perform()
      #expect(detail.finished && detail.isDeleted && detail.plan == nil && detail.selected.isEmpty && detail.summary.isEmpty)
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      #expect(try await store.list(.init()).count == 1)
    }
  }


  @Test("其他操作修改计划时刷新不提升草稿版本，防止无提示覆盖")
  func planEditConflict() async throws {
    try await fixture { store, item in
      let initial = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await initial.load(); initial.toggle(item); initial.submit(.save); await initial.perform()
      let plan = try #require(initial.plan)
      let edit = OutfitPlanEditorModel(plan: plan, repository: store, wardrobe: store, photos: store)
      await edit.load(); edit.submit(.edit); await edit.perform(); edit.summary = "unsaved draft"
      let other = try OutfitPlanInput(localDate: plan.localDate, timeZone: plan.timeZone, contextSummary: "another edit",
        items: [.init(itemID: item.id, revision: item.revision)])
      _ = try await store.mutatePlan(.init(id: UUID(), planID: plan.id, action: .save(other, expectedRevision: 1)))
      edit.submit(.refresh); await edit.perform()
      #expect(edit.needsRefresh && edit.summary == "unsaved draft" && edit.plan?.revision == 1)
      edit.submit(.save); await edit.perform()
      #expect(!edit.finished)
      #expect(try await store.readPlan(id: plan.id).contextSummary == "another edit")
      await edit.load()
      #expect(edit.needsRefresh && edit.plan?.revision == 1 && edit.summary == "unsaved draft")
    }
  }

  @Test("旧详情和编辑草稿获知永久删除后清除内容，不能再次提交", arguments: ["load", "refresh", "save", "cancel"])
  func externallyDeletedPlanClearsContent(operation: String) async throws {
    try await fixture { store, item in
      let initial = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await initial.load(); initial.toggle(item); initial.summary = "synthetic deleted context"
      initial.submit(.save); await initial.perform()
      let plan = try #require(initial.plan)
      let stale = OutfitPlanEditorModel(plan: plan, repository: store, wardrobe: store, photos: store)
      if operation != "load" {
        await stale.load(); stale.submit(.edit); await stale.perform()
        stale.summary = "synthetic unsaved context"
      }
      _ = try await store.mutatePlan(.init(id: UUID(), planID: plan.id, action: .delete(expectedRevision: plan.revision)))
      switch operation {
      case "load": await stale.load()
      case "refresh": stale.submit(.refresh); await stale.perform()
      case "save": stale.submit(.save); await stale.perform()
      default: stale.submit(.cancel); await stale.perform()
      }
      #expect(stale.isDeleted && !stale.isEditing && !stale.isWorking)
      #expect(stale.plan == nil && stale.summary.isEmpty && stale.selected.isEmpty && stale.choices.isEmpty)
      #expect(stale.changedIDs.isEmpty && stale.removedPlaceholders == 0 && !stale.needsRefresh)
      let request = stale.request
      stale.submit(.save)
      #expect(stale.request == request)
      await stale.load()
      #expect(stale.plan == nil && stale.choices.isEmpty && !stale.isWorking)
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      #expect(try await store.list(.init()).count == 1)
    }
  }

  @Test("删除已提交但清理待重试时只保留清理标识，再加载不恢复内容")
  func deletionCleanupRetry() async throws {
    try await fixture { store, item in
      let initial = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await initial.load(); initial.toggle(item); initial.summary = "synthetic cleanup context"
      initial.submit(.save); await initial.perform()
      let plan = try #require(initial.plan)
      let provider = CleanupReply(store: store)
      let detail = OutfitPlanEditorModel(plan: plan, repository: provider, wardrobe: store, photos: store)
      await detail.load(); detail.submit(.delete); await detail.perform()
      #expect(detail.isDeleted && !detail.finished && !detail.isWorking)
      #expect(detail.error == WardrobeError.deletionCleanupPending.title)
      #expect(detail.plan == nil && detail.summary.isEmpty && detail.choices.isEmpty && detail.selected.isEmpty)
      await detail.load()
      #expect(detail.plan == nil && detail.choices.isEmpty)
      detail.submit(.delete); await detail.perform()
      #expect(detail.finished && detail.error == nil)
      let commands = await provider.deletions
      #expect(commands.count == 2 && commands[0] == commands[1])
      #expect(try await store.list(.init()).count == 1)
    }
  }

  @Test("删除冲突后刷新并重新确认可删除最新版本，不能一直复用旧删除版本", arguments: [false, true])
  func deletionConflictCanBeReviewed(otherCancels: Bool) async throws {
    try await fixture { store, item in
      let initial = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await initial.load(); initial.toggle(item); initial.submit(.save); await initial.perform()
      let plan = try #require(initial.plan)
      let provider = LostReply(store: store, loseReply: false)
      let detail = OutfitPlanEditorModel(plan: plan, repository: provider, wardrobe: store, photos: store)
      await detail.load()
      if otherCancels {
        _ = try await store.mutatePlan(.init(id: UUID(), planID: plan.id, action: .cancel(expectedRevision: plan.revision)))
      } else {
        let input = try OutfitPlanInput(localDate: plan.localDate, timeZone: plan.timeZone,
          contextSummary: "synthetic concurrent edit", items: [.init(itemID: item.id, revision: item.revision)])
        _ = try await store.mutatePlan(.init(id: UUID(), planID: plan.id, action: .save(input, expectedRevision: plan.revision)))
      }
      detail.submit(.delete); await detail.perform()
      #expect(detail.needsRefresh && !detail.isDeleted && !detail.finished)
      #expect(try await store.readPlan(id: plan.id).revision == 2)
      detail.submit(.delete); await detail.perform()
      #expect(detail.needsRefresh && !detail.finished)
      #expect(try await store.readPlan(id: plan.id).revision == 2)
      detail.submit(.refresh); await detail.perform()
      #expect(detail.plan?.revision == 2 && detail.error == nil && !detail.needsRefresh)
      #expect(detail.plan?.status == (otherCancels ? .cancelled : .active))
      // The real UI asks for a new deletion confirmation after showing the refreshed plan.
      detail.submit(.delete); await detail.perform()
      #expect(detail.finished && detail.isDeleted && detail.error == nil)
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      #expect(try await store.list(.init()).map(\.id) == [item.id])
      let commands = await provider.mutations
      #expect(commands.count == 3 && Set(commands).count == 3)
    }
  }

  @Test("删除提交后响应丢失仍使用原幂等键重试，不按明确冲突处理")
  func deletionLostReplyPreservesIntent() async throws {
    try await fixture { store, item in
      let initial = OutfitPlanEditorModel(plan: nil, repository: store, wardrobe: store, photos: store)
      await initial.load(); initial.toggle(item); initial.submit(.save); await initial.perform()
      let plan = try #require(initial.plan)
      let provider = LostReply(store: store)
      let detail = OutfitPlanEditorModel(plan: plan, repository: provider, wardrobe: store, photos: store)
      await detail.load(); detail.submit(.delete); await detail.perform()
      #expect(detail.error != nil && !detail.finished && !detail.needsRefresh)
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      detail.submit(.delete); await detail.perform()
      #expect(detail.finished && detail.isDeleted && detail.plan == nil && detail.error == nil)
      let commands = await provider.mutations
      #expect(commands.count == 2 && commands[0] == commands[1])
      #expect(try await store.list(.init()).map(\.id) == [item.id])
    }
  }

  @Test("首次保存结果不明后刷新保留草稿，已提交和未提交都能恢复", arguments: [false, true], [false, true])
  func uncertainCreateCanBeReviewed(committed: Bool, editsDraft: Bool) async throws {
    try await fixture { store, item in
      let provider = LostReply(store: store, commitBeforeFailure: committed)
      let draft = OutfitPlanEditorModel(plan: nil, repository: provider, wardrobe: store, photos: store)
      await draft.load(); draft.toggle(item); draft.summary = "synthetic initial intent"
      draft.submit(.save); await draft.perform()
      #expect(draft.error != nil && !draft.finished && draft.plan == nil)
      if editsDraft {
        draft.summary = "synthetic revised intent"
        if committed {
          draft.submit(.save); await draft.perform()
          #expect(draft.needsRefresh && !draft.finished)
        }
      }
      let summary = draft.summary
      draft.submit(.refresh); await draft.perform()
      #expect(draft.isEditing && !draft.finished && !draft.isDeleted && !draft.needsRefresh)
      #expect(draft.summary == summary && draft.selected == [item.id])
      #expect(draft.plan?.revision == (committed ? 1 : nil))
      draft.submit(.save); await draft.perform()
      #expect(draft.finished && draft.error == nil)
      let plans = try await store.listPlans(on: nil, after: nil).plans
      #expect(plans.count == 1 && plans.first?.id == draft.id)
      #expect(plans.first?.revision == (committed ? 2 : 1))
      #expect(plans.first?.contextSummary == summary)
      #expect(try await store.list(.init()).map(\.id) == [item.id])
    }
  }

  @Test("首次保存响应丢失后若已有后续修改，刷新不能静默采用新版本覆盖", arguments: [false, true])
  func uncertainCreatePreservesConcurrentChange(otherCancels: Bool) async throws {
    try await fixture { store, item in
      let provider = LostReply(store: store)
      let draft = OutfitPlanEditorModel(plan: nil, repository: provider, wardrobe: store, photos: store)
      await draft.load(); draft.toggle(item); draft.summary = "synthetic original"
      draft.submit(.save); await draft.perform()
      let initial = try await store.readPlan(id: draft.id)
      if otherCancels {
        _ = try await store.mutatePlan(.init(id: UUID(), planID: draft.id, action: .cancel(expectedRevision: 1)))
      } else {
        let input = try OutfitPlanInput(localDate: initial.localDate, timeZone: initial.timeZone,
          contextSummary: "synthetic concurrent", items: [.init(itemID: item.id, revision: item.revision)])
        _ = try await store.mutatePlan(.init(id: UUID(), planID: draft.id, action: .save(input, expectedRevision: 1)))
      }
      let concurrent = try await store.readPlan(id: draft.id)
      draft.summary = "synthetic unsaved change"
      draft.submit(.refresh); await draft.perform()
      #expect(draft.needsRefresh && draft.error != nil && !draft.finished)
      #expect(draft.plan == nil && draft.summary == "synthetic unsaved change" && draft.selected == [item.id])
      draft.submit(.save); await draft.perform()
      #expect(!draft.finished && draft.needsRefresh)
      #expect(try await store.readPlan(id: draft.id) == concurrent)
    }
  }

  @Test("首次保存响应丢失后计划已删除，刷新和重试不能复活计划")
  func uncertainCreateCannotRestoreDeletedPlan() async throws {
    try await fixture { store, item in
      let provider = LostReply(store: store)
      let draft = OutfitPlanEditorModel(plan: nil, repository: provider, wardrobe: store, photos: store)
      await draft.load(); draft.toggle(item); draft.summary = "synthetic deleted creation"
      draft.submit(.save); await draft.perform()
      _ = try await store.mutatePlan(.init(id: UUID(), planID: draft.id, action: .delete(expectedRevision: 1)))
      draft.submit(.refresh); await draft.perform()
      draft.submit(.save); await draft.perform()
      #expect(draft.isDeleted && !draft.finished && draft.summary.isEmpty && draft.selected.isEmpty && draft.plan == nil)
      #expect(try await store.listPlans(on: nil, after: nil).plans.isEmpty)
      #expect(try await store.list(.init()).map(\.id) == [item.id])
    }
  }

  private actor CleanupReply: OutfitPlanRepository {
    let store: GRDBWardrobeRepository
    var deletions: [UUID] = []
    init(store: GRDBWardrobeRepository) { self.store = store }
    func listPlans(on: OutfitLocalDate?, after: OutfitPlanCursor?) async throws -> OutfitPlanPage { try await store.listPlans(on: on, after: after) }
    func readPlan(id: UUID) async throws -> OutfitPlan { try await store.readPlan(id: id) }
    func mutatePlan(_ command: OutfitPlanMutation) async throws -> OutfitPlan? {
      let result = try await store.mutatePlan(command)
      if case .delete = command.action {
        deletions.append(command.id)
        if deletions.count == 1 { throw WardrobeError.deletionCleanupPending }
      }
      return result
    }
  }

  private actor LostReply: OutfitPlanRepository {
    let store: GRDBWardrobeRepository
    var loseReply: Bool
    let commitBeforeFailure: Bool
    var mutations: [UUID] = []
    init(store: GRDBWardrobeRepository, loseReply: Bool = true, commitBeforeFailure: Bool = true) {
      self.store = store; self.loseReply = loseReply; self.commitBeforeFailure = commitBeforeFailure
    }
    func listPlans(on: OutfitLocalDate?, after: OutfitPlanCursor?) async throws -> OutfitPlanPage { try await store.listPlans(on: on, after: after) }
    func readPlan(id: UUID) async throws -> OutfitPlan { try await store.readPlan(id: id) }
    func mutatePlan(_ command: OutfitPlanMutation) async throws -> OutfitPlan? {
      mutations.append(command.id)
      if loseReply && !commitBeforeFailure { loseReply = false; throw OutfitPlanError.storageUnavailable }
      let result = try await store.mutatePlan(command)
      if loseReply { loseReply = false; throw OutfitPlanError.storageUnavailable }
      return result
    }
  }
}
