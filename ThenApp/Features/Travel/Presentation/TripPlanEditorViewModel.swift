import Foundation
import Observation

nonisolated struct TripPlanEditorSeed: Identifiable, Sendable, Equatable {
  let id: UUID
  let planID: UUID
  let occurrenceID: UUID?
  let sourceVersion: Int?
  let expectedPlanVersion: Int?
  let expectedAdoptedSourceVersion: Int?
  let title: String?
  let locationText: String?
  let targetArrivalAt: Date
  let isAllDay: Bool
  let existingPlan: TripPlanSummary?

  var isAdoptingRevision: Bool { existingPlan != nil }

  static func manual(referenceDate: Date = Date()) -> TripPlanEditorSeed {
    TripPlanEditorSeed(
      id: UUID(),
      planID: UUID(),
      occurrenceID: nil,
      sourceVersion: nil,
      expectedPlanVersion: nil,
      expectedAdoptedSourceVersion: nil,
      title: nil,
      locationText: nil,
      targetArrivalAt: referenceDate.addingTimeInterval(60 * 60),
      isAllDay: false,
      existingPlan: nil
    )
  }

  init(occurrence: CalendarOccurrenceSummary) {
    id = occurrence.id
    planID = UUID()
    occurrenceID = occurrence.id
    sourceVersion = occurrence.sourceVersion
    expectedPlanVersion = nil
    expectedAdoptedSourceVersion = nil
    title = occurrence.title
    locationText = occurrence.locationText
    targetArrivalAt = occurrence.startsAt
    isAllDay = occurrence.isAllDay
    existingPlan = nil
  }

  init(adopting occurrence: CalendarOccurrenceSummary, into plan: TripPlanSummary) {
    id = UUID()
    planID = plan.id
    occurrenceID = occurrence.id
    sourceVersion = occurrence.sourceVersion
    expectedPlanVersion = plan.planVersion
    expectedAdoptedSourceVersion = plan.sourceOccurrenceVersion
    title =
      plan.displayNameValueSource == .event
      ? occurrence.title
      : plan.displayName
    locationText = occurrence.locationText ?? plan.destination.name
    targetArrivalAt =
      plan.targetArrivalValueSource == .event
      ? occurrence.startsAt
      : plan.targetArrivalAt
    isAllDay = occurrence.isAllDay && plan.targetArrivalValueSource == .event
    existingPlan = plan
  }

  private init(
    id: UUID,
    planID: UUID,
    occurrenceID: UUID?,
    sourceVersion: Int?,
    expectedPlanVersion: Int?,
    expectedAdoptedSourceVersion: Int?,
    title: String?,
    locationText: String?,
    targetArrivalAt: Date,
    isAllDay: Bool,
    existingPlan: TripPlanSummary?
  ) {
    self.id = id
    self.planID = planID
    self.occurrenceID = occurrenceID
    self.sourceVersion = sourceVersion
    self.expectedPlanVersion = expectedPlanVersion
    self.expectedAdoptedSourceVersion = expectedAdoptedSourceVersion
    self.title = title
    self.locationText = locationText
    self.targetArrivalAt = targetArrivalAt
    self.isAllDay = isAllDay
    self.existingPlan = existingPlan
  }
}

@MainActor
@Observable
final class TripPlanEditorViewModel {
  private let ownerID: UUID
  private let service: TripPlanningService
  private let seed: TripPlanEditorSeed
  private let now: @Sendable () -> Date
  private let planID: UUID

  var displayName: String
  var originQuery = ""
  var destinationQuery: String
  var selectedOrigin: ConfirmedLocation?
  var selectedDestination: ConfirmedLocation?
  var originCandidates: [PlaceCandidate] = []
  var destinationCandidates: [PlaceCandidate] = []
  var transportMode: TripTransportMode = .driving
  var targetArrivalAt: Date
  var plannedDepartureAt: Date
  var preparationBufferMinutes = 15
  var routeEstimate: RouteEstimateDraft?
  var reminderEnabled = false
  private(set) var hasConfirmedAllDayTime: Bool
  var isSearchingOrigin = false
  var isSearchingDestination = false
  var isCalculatingRoute = false
  var isSaving = false
  var errorMessage: LocalizedStringResource?
  var statusMessage: String?
  var savedResult: TripPlanSaveResult?

  private var targetArrivalValueSource: TripPlanValueSource
  private var departureValueSource: TripPlanValueSource = .user
  private var displayNameValueSource: TripPlanValueSource

  init(
    ownerID: UUID,
    service: TripPlanningService,
    seed: TripPlanEditorSeed,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.ownerID = ownerID
    self.service = service
    self.seed = seed
    self.now = now
    planID = seed.planID
    displayName = seed.title ?? ""
    destinationQuery = seed.locationText ?? ""
    selectedOrigin = seed.existingPlan?.origin
    originQuery = seed.existingPlan?.origin?.name ?? ""
    transportMode = seed.existingPlan?.transportMode ?? .driving
    targetArrivalAt = seed.targetArrivalAt
    plannedDepartureAt =
      seed.existingPlan?.plannedDepartureAt
      ?? seed.targetArrivalAt.addingTimeInterval(-30 * 60)
    preparationBufferMinutes = (seed.existingPlan?.preparationBufferSeconds ?? 900) / 60
    reminderEnabled =
      seed.existingPlan.map {
        $0.reminderStatus != .disabled && $0.reminderStatus != .cancelled
      } ?? false
    hasConfirmedAllDayTime = !seed.isAllDay
    targetArrivalValueSource =
      seed.existingPlan?.targetArrivalValueSource
      ?? (seed.occurrenceID == nil ? .user : .event)
    departureValueSource = seed.existingPlan?.departureValueSource ?? .user
    displayNameValueSource =
      seed.existingPlan?.displayNameValueSource
      ?? (seed.occurrenceID == nil ? .user : .event)
  }

  var isAdoptingRevision: Bool { seed.isAdoptingRevision }

  func updateDisplayName(_ value: String) {
    displayName = value
    displayNameValueSource = .user
  }

  var canCalculateRoute: Bool {
    selectedOrigin?.latitude != nil
      && selectedOrigin?.longitude != nil
      && selectedDestination?.latitude != nil
      && selectedDestination?.longitude != nil
      && !isCalculatingRoute
  }

  var canSave: Bool {
    selectedDestination != nil
      && targetArrivalAt > now()
      && plannedDepartureAt < targetArrivalAt
      && hasConfirmedAllDayTime
      && !isSaving
  }

  func updateTargetArrival(_ date: Date) {
    targetArrivalAt = date
    targetArrivalValueSource = .user
    if seed.isAllDay {
      hasConfirmedAllDayTime = true
    }
    routeEstimate = nil
    statusMessage = "到达时间已更改，请重新计算路线或确认手动出发时间。"
  }

  func confirmAllDayArrivalTime() {
    guard seed.isAllDay else { return }
    hasConfirmedAllDayTime = true
    targetArrivalValueSource = .user
    statusMessage = "已将具体到达时间确认为你的计划值。"
  }

  func updateTransportMode(_ mode: TripTransportMode) {
    transportMode = mode
    routeEstimate = nil
    statusMessage = "交通方式已更改，请重新计算路线。"
  }

  func updateBufferMinutes(_ minutes: Int) {
    preparationBufferMinutes = minutes
    if let routeEstimate {
      plannedDepartureAt = routeEstimate.suggestedDeparture(
        targetArrivalAt: targetArrivalAt,
        preparationBufferSeconds: minutes * 60
      )
      departureValueSource = .derived
    }
  }

  func updateDeparture(_ date: Date) {
    plannedDepartureAt = date
    departureValueSource = .user
  }

  func searchOrigin() async {
    guard !isSearchingOrigin else { return }
    isSearchingOrigin = true
    errorMessage = nil
    defer { isSearchingOrigin = false }
    do {
      originCandidates = try await service.searchPlace(originQuery)
    } catch {
      originCandidates = []
      errorMessage = Self.userMessage(for: error)
    }
  }

  func searchDestination() async {
    guard !isSearchingDestination else { return }
    isSearchingDestination = true
    errorMessage = nil
    defer { isSearchingDestination = false }
    do {
      destinationCandidates = try await service.searchPlace(destinationQuery)
    } catch {
      destinationCandidates = []
      errorMessage = Self.userMessage(for: error)
    }
  }

  func selectOrigin(_ candidate: PlaceCandidate) {
    selectedOrigin = candidate.confirmed()
    originQuery = candidate.name
    originCandidates = []
    routeEstimate = nil
  }

  func selectDestination(_ candidate: PlaceCandidate) {
    selectedDestination = candidate.confirmed()
    destinationQuery = candidate.name
    destinationCandidates = []
    routeEstimate = nil
  }

  func useManualDestination() {
    let normalized = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      errorMessage = "请先输入目的地。"
      return
    }
    selectedDestination = ConfirmedLocation(
      id: UUID(),
      name: normalized,
      address: normalized,
      latitude: nil,
      longitude: nil,
      source: .manual,
      horizontalAccuracy: nil
    )
    destinationCandidates = []
    routeEstimate = nil
    statusMessage = "已保存为手动地点；可确认手动出发时间，地图会按地址搜索。"
  }

  func calculateRoute() async {
    guard let origin = selectedOrigin, let destination = selectedDestination else {
      errorMessage = "请先从候选中确认起点和目的地。"
      return
    }
    guard !isCalculatingRoute else { return }
    isCalculatingRoute = true
    errorMessage = nil
    statusMessage = nil
    defer { isCalculatingRoute = false }
    do {
      let route = try await service.calculateRoute(
        origin: origin,
        destination: destination,
        transportMode: transportMode,
        targetArrivalAt: targetArrivalAt
      )
      routeEstimate = route
      plannedDepartureAt = route.suggestedDeparture(
        targetArrivalAt: targetArrivalAt,
        preparationBufferSeconds: preparationBufferMinutes * 60
      )
      departureValueSource = .derived
      statusMessage = "已生成 MapKit 路线快照；出发时间仍可手动调整。"
    } catch {
      routeEstimate = nil
      errorMessage = "暂时没有可用路线，请确认手动出发时间后保存。"
    }
  }

  func save() async {
    guard let destination = selectedDestination else {
      errorMessage = "请确认目的地；无搜索结果时可使用手动地址。"
      return
    }
    guard canSave else {
      errorMessage = "请确认未来的到达时间、较早的出发时间和全天事件的具体时间。"
      return
    }
    isSaving = true
    errorMessage = nil
    statusMessage = nil
    defer { isSaving = false }
    do {
      let submittedAt = now()
      if seed.isAdoptingRevision {
        guard let occurrenceID = seed.occurrenceID,
          let throughSourceVersion = seed.sourceVersion,
          let expectedPlanVersion = seed.expectedPlanVersion,
          let expectedAdoptedSourceVersion = seed.expectedAdoptedSourceVersion
        else {
          throw TripPlanningError.corruptedStoredPlan
        }
        savedResult = try await service.adoptCalendarRevision(
          AdoptCalendarRevisionRequest(
            ownerID: ownerID,
            planID: planID,
            occurrenceID: occurrenceID,
            expectedPlanVersion: expectedPlanVersion,
            expectedAdoptedSourceVersion: expectedAdoptedSourceVersion,
            throughSourceVersion: throughSourceVersion,
            displayName: displayName,
            origin: selectedOrigin,
            destination: destination,
            transportMode: transportMode,
            targetArrivalAt: targetArrivalAt,
            plannedDepartureAt: plannedDepartureAt,
            timezoneIdentifier: seed.existingPlan?.timezoneIdentifier
              ?? TimeZone.current.identifier,
            preparationBufferSeconds: preparationBufferMinutes * 60,
            routeEstimate: routeEstimate,
            displayNameValueSource: displayNameValueSource,
            destinationValueSource: .user,
            targetArrivalValueSource: targetArrivalValueSource,
            departureValueSource: departureValueSource,
            reminderEnabled: reminderEnabled,
            reminderFollowsSource: false,
            submittedAt: submittedAt
          )
        )
        statusMessage = savedResult?.reminderMessage ?? "已采用来源变化。"
        return
      }
      let eventSource = try seed.occurrenceID.map { occurrenceID in
        TripPlanEventSource(
          occurrenceID: occurrenceID,
          sourceVersion: try Self.requiredSourceVersion(seed.sourceVersion)
        )
      }
      savedResult = try await service.savePlan(
        SaveTripPlanRequest(
          planID: planID,
          ownerID: ownerID,
          displayName: displayName,
          origin: selectedOrigin,
          destination: destination,
          transportMode: transportMode,
          targetArrivalAt: targetArrivalAt,
          plannedDepartureAt: plannedDepartureAt,
          timezoneIdentifier: TimeZone.current.identifier,
          preparationBufferSeconds: preparationBufferMinutes * 60,
          routeEstimate: routeEstimate,
          eventSource: eventSource,
          displayNameValueSource: displayNameValueSource,
          destinationValueSource: .user,
          targetArrivalValueSource: targetArrivalValueSource,
          departureValueSource: departureValueSource,
          reminderEnabled: reminderEnabled,
          reminderFollowsSource: false,
          submittedAt: submittedAt
        )
      )
      statusMessage = savedResult?.reminderMessage ?? "出行计划已保存。"
    } catch {
      errorMessage = Self.userMessage(for: error)
    }
  }

  private static func requiredSourceVersion(_ version: Int?) throws -> Int {
    guard let version, version >= 1 else { throw TripPlanningError.corruptedStoredPlan }
    return version
  }

  private static func userMessage(for error: Error) -> LocalizedStringResource {
    switch error {
    case TripPlanningError.emptyPlaceQuery:
      "请输入地点关键词。"
    case TripPlanningError.noPlaceCandidate:
      "没有找到地点，可保留输入并使用手动地址。"
    case TripPlanningError.invalidArrivalTime:
      "目标到达时间必须晚于当前时间。"
    case TripPlanningError.invalidDepartureTime:
      "计划出发时间必须早于目标到达时间。"
    case TripPlanningError.routeUnavailable:
      "暂时没有可用路线，可使用手动出发时间。"
    case TripPlanningError.eventAlreadyLinked:
      "这个日历事件已经有出行计划，请处理已有计划。"
    case TripPlanningError.stalePlanVersion, TripPlanningError.staleEventSource,
      TripPlanningError.revisionNotFound:
      "来源或计划已再次变化，请关闭后重新加载。"
    case TripPlanningError.multipleEventPlans:
      "发现多个历史关联计划，已停止修改以避免覆盖错误计划。"
    case TripPlanningError.planNotEditable:
      "已完成或取消的计划不能采用来源变化。"
    default:
      "无法保存出行计划，请检查输入后重试。"
    }
  }
}
