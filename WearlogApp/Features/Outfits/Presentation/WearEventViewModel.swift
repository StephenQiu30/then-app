import Foundation
import Observation

@MainActor @Observable
final class WearEventEditorModel: Identifiable {
  enum Action { case save, edit, refresh, previewDuplicate, delete }

  let id: UUID
  private let repository: any WearEventRepository
  private let wardrobe: any WardrobeRepository
  private let photos: any WardrobePhotoRepository
  private let feedbackRepository: (any OutfitFeedbackRepository)?
  private let sourcePlan: OutfitPlan?
  private var action: Action?
  private var mutationID = UUID()
  private var lastInput: WearEventInput?
  private var generation = UUID()
  private var deletionRevision: Int?

  private(set) var event: WearEvent?
  private(set) var choices: [WardrobeItem] = []
  private(set) var isEditing: Bool
  private(set) var isWorking = false
  private(set) var isDeleted = false
  private(set) var finished = false
  private(set) var error: String?
  private(set) var duplicateCandidates: [WearEventCandidate] = []
  var duplicatePreview: WearEvent?
  var showsDuplicateConfirmation = false
  private(set) var request = 0
  private(set) var feedback: OutfitFeedback?
  var feedbackEditor: OutfitFeedbackEditorModel?

  var date: Date
  private(set) var timeZone: String
  var summary: String
  var completeness: WearEventCompleteness
  var selected: [UUID]
  var laundry: Set<UUID> = []
  var confirmsUnavailable = false
  var confirmsDiscard = false
  var confirmsDelete = false
  var choiceCategory: WardrobeCategory?
  let sourceKind: WearEventSourceKind

  init(event: WearEvent? = nil, sourcePlan: OutfitPlan? = nil,
       sourceKind: WearEventSourceKind = .unplanned,
       repository: any WearEventRepository, wardrobe: any WardrobeRepository,
       photos: any WardrobePhotoRepository, feedbackRepository: (any OutfitFeedbackRepository)? = nil) {
    self.event = event
    self.sourcePlan = sourcePlan
    self.sourceKind = event?.sourceKind ?? sourceKind
    id = event?.id ?? UUID()
    self.repository = repository
    self.wardrobe = wardrobe
    self.photos = photos
    self.feedbackRepository = feedbackRepository
    isEditing = event == nil
    let originalTimeZone = event?.timeZone ?? sourcePlan?.timeZone ?? TimeZone.current.identifier
    timeZone = originalTimeZone
    date = Self.instant(event?.localDate ?? sourcePlan?.localDate, zone: originalTimeZone) ?? Date()
    summary = event?.contextSummary ?? sourcePlan?.contextSummary ?? ""
    completeness = event?.completeness ?? .partial
    if let event { selected = event.items.compactMap { $0.content?.itemID } }
    else if sourceKind == .differentOutfit { selected = [] }
    else { selected = sourcePlan?.items.compactMap { $0.content?.itemID } ?? [] }
  }

  var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: timeZone) ?? .gmt
    return value
  }
  var latestDate: Date { calendar.startOfDay(for: Date()) }
  var missingIDs: [UUID] { selected.filter { id in !choices.contains { $0.id == id } } }
  var unavailable: [WardrobeItem] {
    choices.filter { selected.contains($0.id) && $0.input.availability != .wearable }
  }
  var selectedChoices: [WardrobeItem] { selected.compactMap { id in choices.first { $0.id == id } } }
  var visibleChoices: [WardrobeItem] {
    choices.filter { choiceCategory == nil || $0.input.category == choiceCategory }
  }
  var isSourcePlanStale: Bool {
    guard let event, let sourcePlan, event.sourcePlanID == sourcePlan.id else { return false }
    return event.sourcePlanRevision != sourcePlan.revision
  }

  func thumbnail() -> WardrobeThumbnailViewModel { WardrobeThumbnailViewModel(repository: photos) }

  func editFeedback() {
    guard let event, let feedbackRepository else { return }
    feedbackEditor = OutfitFeedbackEditorModel(wearEventID: event.id, feedback: feedback,
      repository: feedbackRepository)
  }

  func toggle(_ item: WardrobeItem) {
    guard !isWorking else { return }
    if selected.contains(item.id) {
      selected.removeAll { $0 == item.id }; laundry.remove(item.id)
    } else if selected.count < 20 { selected.append(item.id) }
    else { error = String(localized: "每次实际记录最多选择 20 件衣物。") }
    duplicateCandidates = []; confirmsUnavailable = false
  }

  func toggleLaundry(_ item: WardrobeItem) {
    setLaundry(item, enabled: !laundry.contains(item.id))
  }

  func setLaundry(_ item: WardrobeItem, enabled: Bool) {
    guard selected.contains(item.id), !isWorking else { return }
    if enabled { laundry.insert(item.id) } else { laundry.remove(item.id) }
  }

  func submit(_ next: Action) {
    guard !isWorking else { return }
    action = next; isWorking = true; request += 1
  }

  func confirmDuplicate() {
    guard !duplicateCandidates.isEmpty else { return }
    showsDuplicateConfirmation = false
    submit(.save)
  }

  func previewDuplicate() {
    guard !duplicateCandidates.isEmpty else { return }
    showsDuplicateConfirmation = false
    submit(.previewDuplicate)
  }

  func cancelDuplicate() { showsDuplicateConfirmation = false; duplicateCandidates = [] }

  func load() async {
    guard !isDeleted else { return }
    let token = UUID(); generation = token; isWorking = true
    defer { if generation == token { isWorking = false } }
    do {
      if let event {
        let latest = try await repository.readWearEvent(id: event.id)
        try Task.checkCancellation()
        guard token == generation else { return }
        apply(latest)
        feedback = try await feedbackRepository?.readFeedback(wearEventID: latest.id)
      }
      let loaded = try await wardrobe.list(.init(availability: nil))
      try Task.checkCancellation()
      guard token == generation else { return }
      choices = loaded; error = nil
    } catch is CancellationError {} catch WearEventError.notFound {
      if token == generation { eraseVisibleContent() }
    } catch {
      if token == generation { self.error = wearEventErrorMessage(error) }
    }
  }

  func perform() async {
    guard let action else { return }
    self.action = nil
    defer { isWorking = false }
    do {
      switch action {
      case .edit:
        isEditing = true; error = nil
      case .refresh:
        if event != nil {
          let latest = try await repository.readWearEvent(id: id)
          try Task.checkCancellation(); apply(latest)
          feedback = try await feedbackRepository?.readFeedback(wearEventID: latest.id)
        }
        choices = try await wardrobe.list(.init(availability: nil))
        error = nil
      case .previewDuplicate:
        guard let candidate = duplicateCandidates.first else { return }
        duplicatePreview = try await repository.readWearEvent(id: candidate.id)
        try Task.checkCancellation(); error = nil
      case .save:
        guard missingIDs.isEmpty else {
          error = String(localized: "请移除已删除的单品，或选择其他真实衣物。")
          return
        }
        guard unavailable.isEmpty || confirmsUnavailable else { throw WearEventError.unavailableItems }
        let selections = try selected.map { id -> OutfitSelection in
          guard let item = choices.first(where: { $0.id == id }) else { throw WearEventError.conflict }
          return OutfitSelection(itemID: item.id, revision: item.revision)
        }
        let originalSourceID = event?.sourcePlanID ?? sourcePlan?.id
        let originalSourceRevision = event?.sourcePlanRevision ?? sourcePlan?.revision
        let input = try WearEventInput(
          localDate: OutfitLocalDate(instant: date, timeZone: timeZone), timeZone: timeZone,
          completeness: completeness, contextSummary: summary, items: selections,
          laundryItemIDs: laundry, confirmedUnavailable: Set(unavailable.map(\.id)),
          sourcePlanID: originalSourceID, sourcePlanRevision: originalSourceRevision,
          sourceKind: event?.sourceKind ?? sourceKind,
          duplicateConfirmation: Set(duplicateCandidates))
        if lastInput != input && duplicateCandidates.isEmpty { mutationID = UUID() }
        lastInput = input
        let saved = try await repository.mutateWearEvent(.init(id: mutationID, eventID: id,
          action: .save(input, expectedRevision: event?.revision)))
        try Task.checkCancellation()
        event = saved; duplicateCandidates = []; finished = true; error = nil
      case .delete:
        guard let revision = deletionRevision ?? event?.revision else { throw WearEventError.notFound }
        deletionRevision = revision
        _ = try await repository.mutateWearEvent(.init(id: mutationID, eventID: id,
          action: .delete(expectedRevision: revision)))
        try Task.checkCancellation(); eraseVisibleContent(); finished = true
      }
    } catch is CancellationError {
    } catch WearEventError.duplicateConfirmationRequired(let candidates) {
      duplicateCandidates = candidates
      showsDuplicateConfirmation = true
      error = nil
    } catch WearEventError.notFound {
      eraseVisibleContent()
    } catch {
      self.error = wearEventErrorMessage(error)
    }
  }

  private func apply(_ value: WearEvent) {
    event = value; date = Self.instant(value.localDate, zone: value.timeZone) ?? date
    timeZone = value.timeZone; summary = value.contextSummary ?? ""; completeness = value.completeness
    selected = value.items.compactMap { $0.content?.itemID }; laundry = []; duplicateCandidates = []
  }

  private func eraseVisibleContent() {
    generation = UUID(); event = nil; choices = []; selected = []; laundry = []; summary = ""
    feedback = nil; feedbackEditor = nil
    duplicateCandidates = []; duplicatePreview = nil; showsDuplicateConfirmation = false
    error = nil; isDeleted = true; isEditing = false
  }

  private static func instant(_ date: OutfitLocalDate?, zone: String) -> Date? {
    guard let date else { return nil }
    let parts = date.value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let timeZone = TimeZone(identifier: zone) else { return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }
}

@MainActor @Observable
final class OutfitFeedbackEditorModel: Identifiable {
  enum Action { case save, delete }

  let id: UUID
  let wearEventID: UUID
  private let repository: any OutfitFeedbackRepository
  private var feedback: OutfitFeedback?
  private var action: Action?
  private var mutationID = UUID()
  private var previousInput: OutfitFeedbackInput?

  var thermalComfort: ThermalComfort?
  var activityComfort: ActivityComfort?
  var occasionFit: OccasionFit?
  var repeatIntent: RepeatIntent?
  var issueTags: Set<OutfitFeedbackIssueTag>
  var note: String
  private(set) var isWorking = false
  private(set) var finished = false
  private(set) var error: String?
  private(set) var request = 0
  var confirmsDelete = false

  init(wearEventID: UUID, feedback: OutfitFeedback?, repository: any OutfitFeedbackRepository) {
    self.wearEventID = wearEventID
    self.feedback = feedback
    self.repository = repository
    id = feedback?.id ?? UUID()
    thermalComfort = feedback?.input.thermalComfort
    activityComfort = feedback?.input.activityComfort
    occasionFit = feedback?.input.occasionFit
    repeatIntent = feedback?.input.repeatIntent
    issueTags = feedback?.input.issueTags ?? []
    note = feedback?.input.note ?? ""
  }

  var canSave: Bool {
    thermalComfort != nil || activityComfort != nil || occasionFit != nil || repeatIntent != nil
      || !issueTags.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var hasExistingFeedback: Bool { feedback != nil }

  func toggle(_ tag: OutfitFeedbackIssueTag) {
    if issueTags.contains(tag) { issueTags.remove(tag) } else { issueTags.insert(tag) }
  }

  func submit(_ next: Action) {
    guard !isWorking else { return }
    action = next; isWorking = true; request += 1
  }

  func perform() async {
    guard let action else { return }
    self.action = nil
    defer { isWorking = false }
    do {
      switch action {
      case .save:
        let input = try OutfitFeedbackInput(thermalComfort: thermalComfort,
          activityComfort: activityComfort, occasionFit: occasionFit, repeatIntent: repeatIntent,
          issueTags: issueTags, note: note)
        if input != previousInput { mutationID = UUID(); previousInput = input }
        feedback = try await repository.mutateFeedback(.init(id: mutationID, feedbackID: id,
          wearEventID: wearEventID, action: .save(input, expectedRevision: feedback?.revision)))
        try Task.checkCancellation(); finished = true; error = nil
      case .delete:
        guard let feedback else { throw OutfitFeedbackError.notFound }
        _ = try await repository.mutateFeedback(.init(id: mutationID, feedbackID: id,
          wearEventID: wearEventID, action: .delete(expectedRevision: feedback.revision)))
        try Task.checkCancellation(); finished = true; error = nil
      }
    } catch is CancellationError {
    } catch {
      switch error as? OutfitFeedbackError {
      case .invalidInput: self.error = String(localized: "至少选择一项反馈，备注最多 240 字。")
      case .conflict: self.error = String(localized: "反馈已变化，请关闭后重新打开并复核。")
      case .notFound: self.error = String(localized: "实际穿着或反馈已被删除。")
      default: self.error = String(localized: "暂时无法保存反馈，请重试。")
      }
    }
  }
}

@MainActor
func wearEventErrorMessage(_ error: any Error) -> String {
  if let error = error as? WardrobeError { return error.title }
  switch error as? WearEventError {
  case .invalidInput: return String(localized: "请选择 1～20 件衣物，场景不超过 120 字。")
  case .invalidDate: return String(localized: "实际穿着只能记录今天或过去的日期。")
  case .conflict: return String(localized: "衣物、原计划或记录已变化，请刷新并重新复核。")
  case .notFound: return String(localized: "这条实际穿着已被删除。")
  case .unavailableItems: return String(localized: "所选衣物当前不可穿，请先确认这次历史事实。")
  default: return String(localized: "暂时无法保存或读取实际穿着，请重试。")
  }
}
