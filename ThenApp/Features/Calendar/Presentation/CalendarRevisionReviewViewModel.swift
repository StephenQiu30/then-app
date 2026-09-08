import Foundation
import Observation

@MainActor
@Observable
final class CalendarRevisionReviewViewModel {
  private let occurrence: CalendarOccurrenceSummary
  private let calendarImport: CalendarImportService
  private let tripPlanning: TripPlanningService

  private(set) var revisions: [CalendarOccurrenceRevisionSummary] = []
  private(set) var linkedPlans: [TripPlanSummary] = []
  var editorSeed: TripPlanEditorSeed?
  var isLoading = false
  var isResolving = false
  var errorMessage: LocalizedStringResource?
  var statusMessage: LocalizedStringResource?

  init(
    occurrence: CalendarOccurrenceSummary,
    calendarImport: CalendarImportService,
    tripPlanning: TripPlanningService
  ) {
    self.occurrence = occurrence
    self.calendarImport = calendarImport
    self.tripPlanning = tripPlanning
  }

  var reviewedOccurrence: CalendarOccurrenceSummary {
    guard let revision = reviewedRevisions.last else { return occurrence }
    return CalendarOccurrenceSummary(
      id: occurrence.id,
      sourceID: occurrence.sourceID,
      sourceTitle: occurrence.sourceTitle,
      sourceVersion: revision.toVersion,
      sourceState: occurrence.sourceState,
      isAllDay: occurrence.isAllDay,
      startsAt: revision.newStartsAt,
      endsAt: revision.newEndsAt,
      localStartDate: occurrence.localStartDate,
      localEndDateExclusive: occurrence.localEndDateExclusive,
      timeZoneIdentifier: revision.newTimeZoneIdentifier,
      title: revision.newTitle,
      locationText: revision.newLocationText,
      hasPendingRevision: true,
      linkedPlanCount: occurrence.linkedPlanCount
    )
  }

  var reviewedRevisions: [CalendarOccurrenceRevisionSummary] {
    revisions.filter { $0.toVersion <= occurrence.sourceVersion }
  }

  var reviewedThroughSourceVersion: Int? {
    reviewedRevisions.last?.toVersion
  }

  var canAdopt: Bool {
    guard linkedPlans.count == 1,
      let plan = linkedPlans.first,
      let adoptedVersion = plan.sourceOccurrenceVersion,
      let throughVersion = reviewedThroughSourceVersion
    else {
      return false
    }
    return (plan.status == .draft || plan.status == .planned)
      && adoptedVersion < throughVersion
  }

  var planStateMessage: LocalizedStringResource? {
    if linkedPlans.isEmpty {
      return "这个事件还没有关联出行计划；你可以确认已看到变化，之后再从最新事件创建计划。"
    }
    if linkedPlans.count > 1 {
      return "检测到多个历史关联计划。为避免修改错误计划，采用入口已关闭；保留当前计划仍可安全解决所见变化。"
    }
    guard let plan = linkedPlans.first else { return nil }
    if plan.status == .completed || plan.status == .cancelled {
      return "关联计划已经完成或取消，不能再采用来源变化。"
    }
    return nil
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let loadedRevisions = calendarImport.pendingRevisions(occurrenceID: occurrence.id)
      async let loadedPlans = tripPlanning.linkedPlans(occurrenceID: occurrence.id)
      revisions = try await loadedRevisions
      linkedPlans = try await loadedPlans
      if reviewedRevisions.isEmpty {
        statusMessage = "所见来源变化已经处理；请返回刷新日程。"
      }
    } catch {
      errorMessage = "无法读取来源变化，已有计划保持不变。"
    }
  }

  func keepCurrentPlan() async -> Bool {
    guard !isResolving, let throughVersion = reviewedThroughSourceVersion else {
      errorMessage = "所见来源变化已不再待处理，请重新加载。"
      return false
    }
    isResolving = true
    errorMessage = nil
    defer { isResolving = false }
    do {
      try await calendarImport.ignorePendingRevisions(
        occurrenceID: occurrence.id,
        throughSourceVersion: throughVersion
      )
      revisions.removeAll { $0.toVersion <= throughVersion }
      statusMessage = "已保留当前计划；后续新变化仍会再次提醒。"
      return true
    } catch {
      errorMessage = "来源或计划已再次变化，请关闭后重新加载。"
      return false
    }
  }

  func beginAdoption() {
    guard canAdopt, let plan = linkedPlans.first else {
      errorMessage = "当前没有唯一且可编辑的关联计划。"
      return
    }
    editorSeed = TripPlanEditorSeed(adopting: reviewedOccurrence, into: plan)
  }

  func adoptionCompleted() {
    let throughVersion = reviewedThroughSourceVersion
    if let throughVersion {
      revisions.removeAll { $0.toVersion <= throughVersion }
    }
    statusMessage = "已采用所见来源变化。"
  }
}
