import Foundation
import Observation

@MainActor @Observable
final class OutfitPlanViewModel {
  private let repository: any OutfitPlanRepository
  private let wardrobe: any WardrobeRepository
  private let photos: any WardrobePhotoRepository
  private let wearEvents: (any WearEventRepository)?
  private var generation = UUID()
  private(set) var plans: [OutfitPlan] = []
  private(set) var cursor: OutfitPlanCursor?
  private(set) var timelineEntries: [OutfitTimelineEntry] = []
  private(set) var timelineCursor: OutfitTimelineCursor?
  private(set) var error: String?
  private(set) var isLoading = false
  var editor: OutfitPlanEditorModel?
  var wearEditor: WearEventEditorModel?
  var request = 0
  var nextPage = false

  init(repository: any OutfitPlanRepository, wardrobe: any WardrobeRepository, photos: any WardrobePhotoRepository,
       wearEvents: (any WearEventRepository)? = nil) {
    self.repository = repository; self.wardrobe = wardrobe; self.photos = photos; self.wearEvents = wearEvents
  }

  var hasMore: Bool { wearEvents == nil ? cursor != nil : timelineCursor != nil }

  func reload() {
    generation = UUID(); plans = []; cursor = nil; timelineEntries = []; timelineCursor = nil
    error = nil; nextPage = false; request += 1
  }
  func loadMore() { guard !isLoading, hasMore else { return }; nextPage = true; request += 1 }

  func load() async {
    let token = UUID(); generation = token
    let append = nextPage
    nextPage = false
    isLoading = true
    if !append { plans = []; cursor = nil; timelineEntries = []; timelineCursor = nil }
    defer { if generation == token { isLoading = false } }
    do {
      if let wearEvents {
        let page = try await wearEvents.listTimeline(after: append ? timelineCursor : nil)
        try Task.checkCancellation(); guard generation == token else { return }
        if append { timelineEntries += page.entries.filter { row in !timelineEntries.contains { $0.id == row.id } } }
        else { timelineEntries = page.entries }
        plans = timelineEntries.compactMap { if case .plan(let plan) = $0 { plan } else { nil } }
        timelineCursor = page.nextCursor; error = nil
      } else {
        let page = try await repository.listPlans(on: nil, after: append ? cursor : nil)
        try Task.checkCancellation(); guard generation == token else { return }
        if append { plans += page.plans.filter { row in !plans.contains { $0.id == row.id } } }
        else { plans = page.plans }
        timelineEntries = plans.map(OutfitTimelineEntry.plan)
        cursor = page.nextCursor; error = nil
      }
    } catch is CancellationError {} catch {
      if generation == token { self.error = outfitErrorMessage(error) }
    }
  }

  func open(_ plan: OutfitPlan? = nil) {
    editor = OutfitPlanEditorModel(plan: plan, repository: repository, wardrobe: wardrobe, photos: photos,
      wearEvents: wearEvents)
  }

  func recordActual() {
    guard let wearEvents else { return }
    wearEditor = WearEventEditorModel(repository: wearEvents, wardrobe: wardrobe, photos: photos)
  }

  func open(_ event: WearEvent) {
    guard let wearEvents else { return }
    wearEditor = WearEventEditorModel(event: event, repository: wearEvents, wardrobe: wardrobe, photos: photos)
  }
}

@MainActor @Observable
final class OutfitPlanEditorModel: Identifiable {
  enum Action { case save, edit, refresh, cancel, markNotWorn, restoreActive, delete }
  let id: UUID
  private let repository: any OutfitPlanRepository
  private let wardrobe: any WardrobeRepository
  private let photos: any WardrobePhotoRepository
  private let wearEvents: (any WearEventRepository)?
  private var generation = UUID()
  private var previousInput: OutfitPlanInput?
  private var mutationID = UUID()
  private var mutationKind = ""
  private var deletionRevision: Int?
  private var action: Action?
  private(set) var plan: OutfitPlan?
  private(set) var choices: [WardrobeItem] = []
  private(set) var changedIDs: Set<UUID> = []
  private(set) var isEditing: Bool
  private(set) var isWorking = false
  private(set) var isDeleted = false
  private(set) var finished = false
  private(set) var needsRefresh = false
  private(set) var error: String?
  private(set) var request = 0
  var date: Date
  private(set) var timeZone: String
  var summary: String
  var selected: [UUID]
  var removedPlaceholders: Int
  var confirmsChanges = false
  var confirmsUnavailable = false
  var confirmsDiscard = false
  var confirmsCancel = false
  var confirmsNotWorn = false
  var confirmsDelete = false
  var choiceCategory: WardrobeCategory?
  var wearEditor: WearEventEditorModel?

  init(plan: OutfitPlan?, repository: any OutfitPlanRepository, wardrobe: any WardrobeRepository,
       photos: any WardrobePhotoRepository, wearEvents: (any WearEventRepository)? = nil) {
    self.plan = plan; id = plan?.id ?? UUID()
    self.repository = repository; self.wardrobe = wardrobe; self.photos = photos
    self.wearEvents = wearEvents
    isEditing = plan == nil
    timeZone = plan?.timeZone ?? TimeZone.current.identifier
    date = plan.flatMap { Self.instant($0.localDate, zone: $0.timeZone) } ?? Date()
    summary = plan?.contextSummary ?? ""
    selected = plan?.items.compactMap { $0.content?.itemID } ?? []
    removedPlaceholders = plan?.items.filter { $0.content == nil }.count ?? 0
  }

  var missingIDs: [UUID] { selected.filter { id in !choices.contains { $0.id == id } } }
  var unavailable: [WardrobeItem] { choices.filter { selected.contains($0.id) && $0.input.availability != .wearable } }
  var hasChanges: Bool { !changedIDs.isDisjoint(with: selected) }
  var visibleChoices: [WardrobeItem] {
    choices.filter { choiceCategory == nil || $0.input.category == choiceCategory }
  }
  var selectedChoices: [WardrobeItem] {
    selected.compactMap { id in choices.first { $0.id == id } }
  }
  var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: timeZone) ?? .gmt
    return value
  }
  var earliestDate: Date { calendar.startOfDay(for: Date()) }
  var isPast: Bool { plan.map { (Self.instant($0.localDate, zone: timeZone) ?? Date()) < earliestDate } ?? false }
  var canRecordActual: Bool {
    guard let plan, let today = try? OutfitLocalDate(instant: Date(), timeZone: plan.timeZone) else { return false }
    return plan.localDate <= today
  }

  func thumbnail() -> WardrobeThumbnailViewModel { WardrobeThumbnailViewModel(repository: photos) }

  func recordActual(_ kind: WearEventSourceKind) {
    guard let wearEvents, let plan else { return }
    wearEditor = WearEventEditorModel(sourcePlan: plan, sourceKind: kind,
      repository: wearEvents, wardrobe: wardrobe, photos: photos)
  }

  func toggle(_ item: WardrobeItem) {
    guard !isWorking else { return }
    if selected.contains(item.id) { selected.removeAll { $0 == item.id } }
    else if selected.count < 20 { selected.append(item.id) }
    else { error = String(localized: "每个计划最多选择 20 件衣物。") }
    confirmsChanges = false; confirmsUnavailable = false
  }

  func submit(_ next: Action) {
    guard !isWorking else { return }
    if isDeleted {
      guard case .delete = next, deletionRevision != nil else { return }
    }
    action = next; isWorking = true; request += 1
  }

  func load() async {
    guard !isDeleted else { return }
    let token = UUID(); generation = token
    isWorking = true
    defer { if token == generation { isWorking = false } }
    do {
      if let plan {
        let latest = try await repository.readPlan(id: plan.id)
        try Task.checkCancellation()
        guard token == generation else { return }
        guard acceptLatest(latest) else { return }
      }
      let loaded = try await wardrobe.list(.init(availability: nil))
      try Task.checkCancellation()
      guard token == generation else { return }
      applyChoices(loaded); error = nil
    } catch is CancellationError {} catch OutfitPlanError.notFound {
      if token == generation { eraseVisibleContent() }
    } catch {
      if token == generation { self.error = outfitErrorMessage(error) }
    }
  }

  private func applyChoices(_ loaded: [WardrobeItem]) {
    let old = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
    for item in loaded {
      if let earlier = old[item.id], earlier != item { changedIDs.insert(item.id) }
      if let snapshot = plan?.items.compactMap(\.content).first(where: { $0.itemID == item.id }),
         snapshot.revision != item.revision || snapshot.input != item.input { changedIDs.insert(item.id) }
    }
    choices = loaded; confirmsChanges = false; confirmsUnavailable = false; needsRefresh = false
  }

  private func acceptLatest(_ latest: OutfitPlan) -> Bool {
    if isEditing, let plan, latest != plan {
      requirePlanReview()
      return false
    }
    plan = latest
    if !isEditing {
      selected = latest.items.compactMap { $0.content?.itemID }
      removedPlaceholders = latest.items.filter { $0.content == nil }.count
      summary = latest.contextSummary ?? ""
      date = Self.instant(latest.localDate, zone: timeZone) ?? date
    }
    return true
  }

  private func requirePlanReview() {
    needsRefresh = true
    error = String(localized: "计划已在其他操作中修改。草稿仍保留，请取消编辑后重新打开计划，核对最新内容。")
  }

  func perform() async {
    guard let action else { return }
    self.action = nil
    defer { isWorking = false }
    do {
      switch action {
      case .edit, .refresh:
        if let plan {
          let latest = try await repository.readPlan(id: plan.id)
          try Task.checkCancellation()
          guard acceptLatest(latest) else { return }
        } else if case .refresh = action, mutationKind == "save" {
          let latest: OutfitPlan?
          do { latest = try await repository.readPlan(id: id) }
          catch OutfitPlanError.notFound { latest = nil }
          try Task.checkCancellation()
          if let latest {
            // A lost create response can leave this session without a plan.
            // Adopt only its initial revision; later changes require explicit review.
            guard latest.revision == 1 else { requirePlanReview(); return }
            plan = latest
            mutationKind = ""; previousInput = nil
          }
        }
        let loaded = try await wardrobe.list(.init(availability: nil))
        try Task.checkCancellation()
        applyChoices(loaded)
        if case .edit = action { isEditing = true }
        error = nil
      case .save:
        guard !needsRefresh else { throw OutfitPlanError.conflict }
        guard removedPlaceholders == 0, missingIDs.isEmpty else {
          error = String(localized: "请先移除已删除的单品，再保存计划。")
          return
        }
        guard !hasChanges || confirmsChanges else {
          error = String(localized: "请先确认已复核衣物变化。")
          return
        }
        guard unavailable.isEmpty || confirmsUnavailable else { throw OutfitPlanError.unavailableItems }
        let items = try selected.map { id -> OutfitSelection in
          guard let item = choices.first(where: { $0.id == id }) else { throw OutfitPlanError.conflict }
          return OutfitSelection(itemID: id, revision: item.revision)
        }
        let input = try OutfitPlanInput(localDate: OutfitLocalDate(instant: date, timeZone: timeZone), timeZone: timeZone,
          contextSummary: summary, items: items, confirmedUnavailable: Set(unavailable.map(\.id)))
        if mutationKind != "save" || input != previousInput { mutationID = UUID(); previousInput = input; mutationKind = "save" }
        let result = try await repository.mutatePlan(.init(id: mutationID, planID: id, action: .save(input, expectedRevision: plan?.revision)))
        try Task.checkCancellation()
        plan = result; finished = true; error = nil
      case .cancel:
        guard let plan else { throw OutfitPlanError.notFound }
        if mutationKind != "cancel" { mutationID = UUID(); mutationKind = "cancel" }
        let result = try await repository.mutatePlan(.init(id: mutationID, planID: id, action: .cancel(expectedRevision: plan.revision)))
        try Task.checkCancellation()
        self.plan = result; mutationID = UUID(); error = nil
      case .markNotWorn:
        guard let plan else { throw OutfitPlanError.notFound }
        if mutationKind != "markNotWorn" { mutationID = UUID(); mutationKind = "markNotWorn" }
        self.plan = try await repository.mutatePlan(.init(id: mutationID, planID: id,
          action: .markNotWorn(expectedRevision: plan.revision)))
        try Task.checkCancellation(); error = nil
      case .restoreActive:
        guard let plan else { throw OutfitPlanError.notFound }
        if mutationKind != "restoreActive" { mutationID = UUID(); mutationKind = "restoreActive" }
        self.plan = try await repository.mutatePlan(.init(id: mutationID, planID: id,
          action: .restoreActive(expectedRevision: plan.revision)))
        try Task.checkCancellation(); error = nil
      case .delete:
        guard let revision = deletionRevision ?? plan?.revision else { throw OutfitPlanError.notFound }
        deletionRevision = revision
        if mutationKind != "delete" { mutationID = UUID(); mutationKind = "delete" }
        _ = try await repository.mutatePlan(.init(id: mutationID, planID: id, action: .delete(expectedRevision: revision)))
        eraseVisibleContent(); finished = true
      }
    } catch is CancellationError {
      // Reopening reads the committed result; cancellation does not undo a database transaction.
    } catch OutfitPlanError.notFound {
      eraseVisibleContent()
    } catch WardrobeError.deletionCleanupPending {
      eraseVisibleContent(); error = WardrobeError.deletionCleanupPending.title
    } catch {
      self.error = outfitErrorMessage(error)
      if let failure = error as? OutfitPlanError, failure == .conflict {
        needsRefresh = true
        if case .delete = action {
          // A rejected deletion must be confirmed again against the refreshed revision.
          // Keep the original intent for ambiguous failures and committed cleanup retries.
          deletionRevision = nil; mutationKind = ""
        }
      }
    }
  }

  private func eraseVisibleContent() {
    generation = UUID(); error = nil
    isWorking = false; action = nil; needsRefresh = false
    confirmsDiscard = false; confirmsCancel = false; confirmsNotWorn = false; confirmsDelete = false
    isDeleted = true; isEditing = false; selected = []; choices = []; summary = ""; changedIDs = []
    removedPlaceholders = 0; confirmsChanges = false; confirmsUnavailable = false
    choiceCategory = nil
    // Only the opaque ID and deletion revision survive while cleanup is retried.
    plan = nil; previousInput = nil; date = Date(); timeZone = TimeZone.current.identifier
  }

  private static func instant(_ date: OutfitLocalDate, zone: String) -> Date? {
    let parts = date.value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let timeZone = TimeZone(identifier: zone) else { return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }
}

@MainActor
func outfitErrorMessage(_ error: any Error) -> String {
  if let error = error as? WardrobeError { return error.title }
  switch error as? OutfitPlanError {
  case .invalidInput: return String(localized: "请选择 1～20 件衣物，场景不超过 120 字。")
  case .invalidDate: return String(localized: "新日期须为今天或未来；过去的计划可保留原日期。")
  case .invalidTimeZone: return String(localized: "当前时区不可用，请检查系统日期设置。")
  case .conflict: return String(localized: "衣物或计划已变化，请刷新并复核后保存。")
  case .notFound: return String(localized: "这个计划已被删除，请关闭后刷新。")
  case .unavailableItems: return String(localized: "所选衣物当前不可穿，请先确认安排。")
  default: return String(localized: "暂时无法保存或读取计划，请重试。")
  }
}
