import Foundation

nonisolated enum JourneyStatus: String, Codable, Sendable {
  case recording
  case paused
  case finalizing
  case reviewing
  case completed
  case discarded
}

nonisolated enum JourneyCaptureCompleteness: String, Codable, Sendable {
  case none
  case partial
  case complete
}

nonisolated enum JourneyRawTrackState: String, Codable, Sendable {
  case collecting
  case awaitingSummaryConfirmation = "awaiting_summary_confirmation"
  case purged
}

nonisolated enum JourneyTerminationReason: String, Codable, Sendable {
  case userEnded = "user_ended"
  case permissionDenied = "permission_denied"
  case locationUnavailable = "location_unavailable"
  case storageFailure = "storage_failure"
  case systemInterruption = "system_interruption"
  case discarded
}

nonisolated enum TrackPointQuality: String, Codable, Sendable {
  case unreviewed
  case accepted
  case lowAccuracy = "low_accuracy"
  case implausibleJump = "implausible_jump"
}

nonisolated enum JourneyInterruptionReason: String, Codable, Sendable {
  case permissionDenied = "permission_denied"
  case authorizationRestricted = "authorization_restricted"
  case locationServicesDisabled = "location_services_disabled"
  case locationUnavailable = "location_unavailable"
  case insufficientlyInUse = "insufficiently_in_use"
  case accuracyLimited = "accuracy_limited"
  case storageFailure = "storage_failure"
  case systemInterruption = "system_interruption"
  case userPaused = "user_paused"
}

nonisolated struct JourneyStartRequest: Sendable, Equatable {
  let journeyID: UUID
  let ownerID: UUID
  let tripPlanID: UUID?
  let recordingDeviceID: UUID
  let transportMode: TripTransportMode
  let startedAt: Date
  let trackingConsentVersion: Int
}

nonisolated struct JourneySnapshot: Identifiable, Sendable, Equatable {
  let id: UUID
  let tripPlanID: UUID?
  let recordingDeviceID: UUID
  let status: JourneyStatus
  let transportMode: TripTransportMode
  let startedAt: Date
  let endedAt: Date?
  let distanceMeters: Double?
  let durationSeconds: TimeInterval?
  let captureCompleteness: JourneyCaptureCompleteness
  let rawTrackState: JourneyRawTrackState
  let finalSequence: Int?
  let pointCount: Int?
  let terminationReason: JourneyTerminationReason?
  let pauseReason: JourneyInterruptionReason?
}

nonisolated struct JourneyLocationSample: Identifiable, Sendable, Equatable {
  let id: UUID
  let recordedAt: Date
  let latitude: Double
  let longitude: Double
  let horizontalAccuracy: Double
  let verticalAccuracy: Double?
  let altitudeMeters: Double?
  let speedMetersPerSecond: Double?
  let courseDegrees: Double?
}

nonisolated struct StoredTrackPoint: Identifiable, Sendable, Equatable {
  let id: UUID
  let journeyID: UUID
  let segmentID: UUID
  let sequence: Int
  let sample: JourneyLocationSample
  let quality: TrackPointQuality
}

nonisolated enum JourneyLocationEvent: Sendable, Equatable {
  case sample(JourneyLocationSample)
  case interrupted(JourneyInterruptionReason)
}

nonisolated enum JourneyRecordingError: Error, Sendable, Equatable {
  case activeJourneyExists
  case journeyNotFound
  case invalidState
  case invalidSample
  case outOfOrderSample
  case duplicateSampleMismatch
  case locationStartFailed
  case corruptedStoredJourney
}

nonisolated protocol JourneyRepository: Sendable {
  func startJourney(_ request: JourneyStartRequest) async throws -> JourneySnapshot
  func openJourney(ownerID: UUID, recordingDeviceID: UUID) async throws -> JourneySnapshot?
  func journey(ownerID: UUID, journeyID: UUID) async throws -> JourneySnapshot
  func journeys(ownerID: UUID) async throws -> [JourneySnapshot]
  func appendSample(
    ownerID: UUID,
    journeyID: UUID,
    sample: JourneyLocationSample,
    storedAt: Date
  ) async throws -> StoredTrackPoint
  func reviewPoint(
    ownerID: UUID,
    journeyID: UUID,
    pointID: UUID,
    reviewedAt: Date
  ) async throws -> StoredTrackPoint
  func pauseJourney(
    ownerID: UUID,
    journeyID: UUID,
    reason: JourneyInterruptionReason,
    changedAt: Date
  ) async throws -> JourneySnapshot
  func resumeJourney(
    ownerID: UUID,
    journeyID: UUID,
    newSegmentID: UUID,
    resumedAt: Date
  ) async throws -> JourneySnapshot
  func beginFinalization(
    ownerID: UUID,
    journeyID: UUID,
    reason: JourneyTerminationReason,
    endedAt: Date
  ) async throws -> JourneySnapshot
  func finalizeJourney(
    ownerID: UUID,
    journeyID: UUID,
    finalizedAt: Date
  ) async throws -> JourneySnapshot
  func confirmSummary(
    ownerID: UUID,
    journeyID: UUID,
    confirmedAt: Date
  ) async throws -> JourneySnapshot
  func discardJourney(
    ownerID: UUID,
    journeyID: UUID,
    discardedAt: Date
  ) async throws -> JourneySnapshot
  func deleteJourney(ownerID: UUID, journeyID: UUID) async throws
}

nonisolated protocol JourneyLocationDriver: Sendable {
  func start(
    transportMode: TripTransportMode,
    handler: @escaping @Sendable (JourneyLocationEvent) async -> Void
  ) async throws
  func stop() async
}
