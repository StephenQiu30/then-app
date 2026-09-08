import Foundation

nonisolated struct TripPlanningService: Sendable {
  private let ownerID: UUID
  private let repository: any TripPlanRepository
  private let placeSearch: any PlaceSearchService
  private let routePlanning: any RoutePlanningService
  private let reminders: any ReminderService
  private let navigation: any ExternalNavigationService
  private let now: @Sendable () -> Date

  init(
    ownerID: UUID,
    repository: any TripPlanRepository,
    placeSearch: any PlaceSearchService,
    routePlanning: any RoutePlanningService,
    reminders: any ReminderService,
    navigation: any ExternalNavigationService,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.ownerID = ownerID
    self.repository = repository
    self.placeSearch = placeSearch
    self.routePlanning = routePlanning
    self.reminders = reminders
    self.navigation = navigation
    self.now = now
  }

  func searchPlace(_ query: String) async throws -> [PlaceCandidate] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw TripPlanningError.emptyPlaceQuery }
    let candidates = try await placeSearch.search(query: normalized)
    guard !candidates.isEmpty else { throw TripPlanningError.noPlaceCandidate }
    return candidates
  }

  func calculateRoute(
    origin: ConfirmedLocation,
    destination: ConfirmedLocation,
    transportMode: TripTransportMode,
    targetArrivalAt: Date
  ) async throws -> RouteEstimateDraft {
    guard targetArrivalAt > now() else { throw TripPlanningError.invalidArrivalTime }
    return try await routePlanning.route(
      for: RoutePlanningRequest(
        origin: origin,
        destination: destination,
        transportMode: transportMode,
        targetArrivalAt: targetArrivalAt
      )
    )
  }

  func savePlan(_ request: SaveTripPlanRequest) async throws -> TripPlanSaveResult {
    var plan = try await repository.savePlan(request)
    guard request.reminderEnabled else {
      return TripPlanSaveResult(plan: plan, reminderMessage: nil)
    }

    let fireAt = request.plannedDepartureAt
    guard fireAt > now() else {
      plan = try await repository.updateReminderState(
        ownerID: ownerID,
        planID: request.planID,
        status: .failed,
        fireAt: fireAt,
        safeErrorCode: "fire_time_passed",
        changedAt: now()
      )
      return TripPlanSaveResult(plan: plan, reminderMessage: "计划已保存，但出发时间已过，未安排提醒。")
    }

    do {
      var state = await reminders.authorizationState()
      if state == .notDetermined {
        state = try await reminders.requestAuthorization()
      }
      guard state == .authorized || state == .provisional || state == .ephemeral else {
        plan = try await repository.updateReminderState(
          ownerID: ownerID,
          planID: request.planID,
          status: .authorizationDenied,
          fireAt: fireAt,
          safeErrorCode: "notification_denied",
          changedAt: now()
        )
        return TripPlanSaveResult(plan: plan, reminderMessage: "计划已保存，但通知未获授权。")
      }

      let requestIdentifier = Self.notificationRequestIdentifier(planID: request.planID)
      await reminders.cancel(requestIdentifier: requestIdentifier)
      try await reminders.schedule(
        ReminderScheduleRequest(requestIdentifier: requestIdentifier, fireAt: fireAt)
      )
      plan = try await repository.updateReminderState(
        ownerID: ownerID,
        planID: request.planID,
        status: .scheduled,
        fireAt: fireAt,
        safeErrorCode: nil,
        changedAt: now()
      )
      return TripPlanSaveResult(plan: plan, reminderMessage: "已向系统安排普通本地提醒。")
    } catch {
      plan = try await repository.updateReminderState(
        ownerID: ownerID,
        planID: request.planID,
        status: .failed,
        fireAt: fireAt,
        safeErrorCode: "schedule_failed",
        changedAt: now()
      )
      return TripPlanSaveResult(plan: plan, reminderMessage: "计划已保存，但提醒调度失败。")
    }
  }

  func plans() async throws -> [TripPlanSummary] {
    try await repository.plans(ownerID: ownerID)
  }

  func linkedPlans(occurrenceID: UUID) async throws -> [TripPlanSummary] {
    try await repository.linkedPlans(ownerID: ownerID, occurrenceID: occurrenceID)
  }

  func adoptCalendarRevision(_ request: AdoptCalendarRevisionRequest) async throws
    -> TripPlanSaveResult
  {
    var plan = try await repository.adoptCalendarRevision(request)
    let requestIdentifier = Self.notificationRequestIdentifier(planID: request.planID)
    await reminders.cancel(requestIdentifier: requestIdentifier)
    guard request.reminderEnabled else {
      return TripPlanSaveResult(plan: plan, reminderMessage: "已采用来源变化，出发提醒保持关闭。")
    }

    let fireAt = request.plannedDepartureAt
    guard fireAt > now() else {
      plan = try await repository.updateReminderState(
        ownerID: ownerID,
        planID: request.planID,
        status: .failed,
        fireAt: fireAt,
        safeErrorCode: "fire_time_passed",
        changedAt: now()
      )
      return TripPlanSaveResult(plan: plan, reminderMessage: "已采用来源变化，但出发时间已过，未安排提醒。")
    }

    do {
      var state = await reminders.authorizationState()
      if state == .notDetermined {
        state = try await reminders.requestAuthorization()
      }
      guard state == .authorized || state == .provisional || state == .ephemeral else {
        plan = try await repository.updateReminderState(
          ownerID: ownerID,
          planID: request.planID,
          status: .authorizationDenied,
          fireAt: fireAt,
          safeErrorCode: "notification_denied",
          changedAt: now()
        )
        return TripPlanSaveResult(plan: plan, reminderMessage: "已采用来源变化，但通知未获授权。")
      }
      try await reminders.schedule(
        ReminderScheduleRequest(requestIdentifier: requestIdentifier, fireAt: fireAt)
      )
      plan = try await repository.updateReminderState(
        ownerID: ownerID,
        planID: request.planID,
        status: .scheduled,
        fireAt: fireAt,
        safeErrorCode: nil,
        changedAt: now()
      )
      return TripPlanSaveResult(plan: plan, reminderMessage: "已采用来源变化并重新安排普通本地提醒。")
    } catch {
      plan = try await repository.updateReminderState(
        ownerID: ownerID,
        planID: request.planID,
        status: .failed,
        fireAt: fireAt,
        safeErrorCode: "schedule_failed",
        changedAt: now()
      )
      return TripPlanSaveResult(plan: plan, reminderMessage: "已采用来源变化，但提醒调度失败。")
    }
  }

  @MainActor
  func openAppleMaps(for plan: TripPlanSummary) async throws {
    let handoffID = UUID()
    let requestedAt = now()
    try await repository.beginNavigationHandoff(
      ownerID: ownerID,
      planID: plan.id,
      handoffID: handoffID,
      requestedAt: requestedAt
    )
    let didOpen = await navigation.openAppleMaps(
      destination: plan.destination,
      transportMode: plan.transportMode
    )
    try await repository.completeNavigationHandoff(
      ownerID: ownerID,
      handoffID: handoffID,
      result: didOpen ? .succeeded : .failed,
      safeErrorCode: didOpen ? nil : "open_failed",
      completedAt: now()
    )
    guard didOpen else { throw TripPlanningError.navigationOpenFailed }
  }

  private static func notificationRequestIdentifier(planID: UUID) -> String {
    "trip-plan-\(planID.uuidString.lowercased())-departure-v1"
  }
}
