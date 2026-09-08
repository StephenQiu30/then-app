import Foundation

nonisolated enum TripTransportMode: String, CaseIterable, Codable, Sendable, Identifiable {
  case walking
  case driving
  case transit

  var id: String { rawValue }
}

nonisolated enum LocationSnapshotSource: String, Codable, Sendable {
  case manual
  case mapkit
}

nonisolated struct ConfirmedLocation: Identifiable, Sendable, Equatable {
  let id: UUID
  let name: String
  let address: String?
  let latitude: Double?
  let longitude: Double?
  let source: LocationSnapshotSource
  let horizontalAccuracy: Double?
}

nonisolated struct PlaceCandidate: Identifiable, Sendable, Equatable {
  let id: UUID
  let name: String
  let address: String?
  let latitude: Double
  let longitude: Double

  func confirmed() -> ConfirmedLocation {
    ConfirmedLocation(
      id: id,
      name: name,
      address: address,
      latitude: latitude,
      longitude: longitude,
      source: .mapkit,
      horizontalAccuracy: nil
    )
  }
}

nonisolated struct RoutePlanningRequest: Sendable, Equatable {
  let origin: ConfirmedLocation
  let destination: ConfirmedLocation
  let transportMode: TripTransportMode
  let targetArrivalAt: Date
}

nonisolated struct RouteEstimateDraft: Identifiable, Sendable, Equatable {
  let id: UUID
  let origin: ConfirmedLocation
  let destination: ConfirmedLocation
  let transportMode: TripTransportMode
  let distanceMeters: Double
  let expectedTravelSeconds: TimeInterval
  let calculatedAt: Date
  let expiresAt: Date

  func suggestedDeparture(
    targetArrivalAt: Date,
    preparationBufferSeconds: Int
  ) -> Date {
    targetArrivalAt.addingTimeInterval(
      -(expectedTravelSeconds + TimeInterval(preparationBufferSeconds))
    )
  }
}

nonisolated enum TripPlanStatus: String, Codable, Sendable {
  case draft
  case planned
  case completed
  case cancelled
}

nonisolated enum TripPlanValueSource: String, Codable, Sendable {
  case event
  case user
  case derived
}

nonisolated enum DepartureReminderStatus: String, Codable, Sendable {
  case disabled
  case notRequested = "not_requested"
  case authorizationDenied = "authorization_denied"
  case scheduled
  case failed
  case cancelled
}

nonisolated struct TripPlanEventSource: Sendable, Equatable {
  let occurrenceID: UUID
  let sourceVersion: Int
}

nonisolated struct SaveTripPlanRequest: Sendable, Equatable {
  let planID: UUID
  let ownerID: UUID
  let displayName: String?
  let origin: ConfirmedLocation?
  let destination: ConfirmedLocation
  let transportMode: TripTransportMode
  let targetArrivalAt: Date
  let plannedDepartureAt: Date
  let timezoneIdentifier: String
  let preparationBufferSeconds: Int
  let routeEstimate: RouteEstimateDraft?
  let eventSource: TripPlanEventSource?
  let displayNameValueSource: TripPlanValueSource
  let destinationValueSource: TripPlanValueSource
  let targetArrivalValueSource: TripPlanValueSource
  let departureValueSource: TripPlanValueSource
  let reminderEnabled: Bool
  let reminderFollowsSource: Bool
  let submittedAt: Date
}

nonisolated struct AdoptCalendarRevisionRequest: Sendable, Equatable {
  let ownerID: UUID
  let planID: UUID
  let occurrenceID: UUID
  let expectedPlanVersion: Int
  let expectedAdoptedSourceVersion: Int
  let throughSourceVersion: Int
  let displayName: String?
  let origin: ConfirmedLocation?
  let destination: ConfirmedLocation
  let transportMode: TripTransportMode
  let targetArrivalAt: Date
  let plannedDepartureAt: Date
  let timezoneIdentifier: String
  let preparationBufferSeconds: Int
  let routeEstimate: RouteEstimateDraft?
  let displayNameValueSource: TripPlanValueSource
  let destinationValueSource: TripPlanValueSource
  let targetArrivalValueSource: TripPlanValueSource
  let departureValueSource: TripPlanValueSource
  let reminderEnabled: Bool
  let reminderFollowsSource: Bool
  let submittedAt: Date
}

nonisolated struct TripPlanSummary: Identifiable, Sendable, Equatable {
  let id: UUID
  let planVersion: Int
  let displayName: String?
  let destination: ConfirmedLocation
  let origin: ConfirmedLocation?
  let transportMode: TripTransportMode
  let targetArrivalAt: Date
  let plannedDepartureAt: Date?
  let timezoneIdentifier: String
  let preparationBufferSeconds: Int
  let status: TripPlanStatus
  let routeEstimate: RouteEstimateDraft?
  let reminderStatus: DepartureReminderStatus
  let reminderFireAt: Date?
  let linkedOccurrenceID: UUID?
  let sourceOccurrenceVersion: Int?
  let displayNameValueSource: TripPlanValueSource
  let destinationValueSource: TripPlanValueSource
  let targetArrivalValueSource: TripPlanValueSource
  let departureValueSource: TripPlanValueSource
}

nonisolated struct TripPlanSaveResult: Sendable, Equatable {
  let plan: TripPlanSummary
  let reminderMessage: String?
}

nonisolated enum ReminderAuthorizationState: Sendable, Equatable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral
}

nonisolated struct ReminderScheduleRequest: Sendable, Equatable {
  let requestIdentifier: String
  let fireAt: Date
}

nonisolated enum NavigationHandoffResult: String, Sendable, Codable {
  case requested
  case succeeded
  case failed
}

nonisolated enum TripPlanningError: Error, Sendable, Equatable {
  case emptyPlaceQuery
  case noPlaceCandidate
  case invalidCoordinate
  case invalidArrivalTime
  case invalidDepartureTime
  case invalidBuffer
  case routeRequiresOrigin
  case routeUnavailable
  case reminderNotAuthorized
  case reminderFireTimePassed
  case planNotFound
  case eventAlreadyLinked
  case multipleEventPlans
  case stalePlanVersion
  case staleEventSource
  case revisionNotFound
  case invalidResolutionTime
  case planNotEditable
  case corruptedStoredPlan
  case navigationOpenFailed
}

nonisolated protocol PlaceSearchService: Sendable {
  func search(query: String) async throws -> [PlaceCandidate]
}

nonisolated protocol RoutePlanningService: Sendable {
  func route(for request: RoutePlanningRequest) async throws -> RouteEstimateDraft
}

nonisolated protocol ReminderService: Sendable {
  func authorizationState() async -> ReminderAuthorizationState
  func requestAuthorization() async throws -> ReminderAuthorizationState
  func schedule(_ request: ReminderScheduleRequest) async throws
  func cancel(requestIdentifier: String) async
}

nonisolated protocol ExternalNavigationService: Sendable {
  @MainActor
  func openAppleMaps(
    destination: ConfirmedLocation,
    transportMode: TripTransportMode
  ) async -> Bool
}

nonisolated protocol TripPlanRepository: Sendable {
  func savePlan(_ request: SaveTripPlanRequest) async throws -> TripPlanSummary
  func plans(ownerID: UUID) async throws -> [TripPlanSummary]
  func linkedPlans(ownerID: UUID, occurrenceID: UUID) async throws -> [TripPlanSummary]
  func adoptCalendarRevision(_ request: AdoptCalendarRevisionRequest) async throws
    -> TripPlanSummary
  func updateReminderState(
    ownerID: UUID,
    planID: UUID,
    status: DepartureReminderStatus,
    fireAt: Date?,
    safeErrorCode: String?,
    changedAt: Date
  ) async throws -> TripPlanSummary
  func beginNavigationHandoff(
    ownerID: UUID,
    planID: UUID,
    handoffID: UUID,
    requestedAt: Date
  ) async throws
  func completeNavigationHandoff(
    ownerID: UUID,
    handoffID: UUID,
    result: NavigationHandoffResult,
    safeErrorCode: String?,
    completedAt: Date
  ) async throws
}
