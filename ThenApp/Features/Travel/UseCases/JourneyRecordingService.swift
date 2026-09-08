import Foundation

actor JourneyRecordingService {
  private let ownerID: UUID
  private let recordingDeviceID: UUID
  private let repository: any JourneyRepository
  private let locationDriver: any JourneyLocationDriver
  private let now: @Sendable () -> Date
  private var activeDriverJourneyID: UUID?

  init(
    ownerID: UUID,
    recordingDeviceID: UUID,
    repository: any JourneyRepository,
    locationDriver: any JourneyLocationDriver,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.ownerID = ownerID
    self.recordingDeviceID = recordingDeviceID
    self.repository = repository
    self.locationDriver = locationDriver
    self.now = now
  }

  func currentJourney() async throws -> JourneySnapshot? {
    try await repository.openJourney(ownerID: ownerID, recordingDeviceID: recordingDeviceID)
  }

  func journeys() async throws -> [JourneySnapshot] {
    try await repository.journeys(ownerID: ownerID)
  }

  func start(
    tripPlanID: UUID?,
    transportMode: TripTransportMode
  ) async throws -> JourneySnapshot {
    let startedAt = now()
    let journey = try await repository.startJourney(
      JourneyStartRequest(
        journeyID: UUID(),
        ownerID: ownerID,
        tripPlanID: tripPlanID,
        recordingDeviceID: recordingDeviceID,
        transportMode: transportMode,
        startedAt: startedAt,
        trackingConsentVersion: 1
      )
    )
    do {
      try await startDriver(for: journey)
      return journey
    } catch {
      _ = try? await repository.pauseJourney(
        ownerID: ownerID,
        journeyID: journey.id,
        reason: .systemInterruption,
        changedAt: now()
      )
      throw JourneyRecordingError.locationStartFailed
    }
  }

  func pause(journeyID: UUID) async throws -> JourneySnapshot {
    await locationDriver.stop()
    activeDriverJourneyID = nil
    return try await repository.pauseJourney(
      ownerID: ownerID,
      journeyID: journeyID,
      reason: .userPaused,
      changedAt: now()
    )
  }

  func resume(journeyID: UUID) async throws -> JourneySnapshot {
    var current = try await repository.journey(ownerID: ownerID, journeyID: journeyID)
    if current.status == .recording {
      current = try await repository.pauseJourney(
        ownerID: ownerID,
        journeyID: journeyID,
        reason: .systemInterruption,
        changedAt: now()
      )
    }
    guard [.paused, .finalizing, .reviewing].contains(current.status) else {
      throw JourneyRecordingError.invalidState
    }
    let resumed = try await repository.resumeJourney(
      ownerID: ownerID,
      journeyID: journeyID,
      newSegmentID: UUID(),
      resumedAt: now()
    )
    do {
      try await startDriver(for: resumed)
      return resumed
    } catch {
      _ = try? await repository.pauseJourney(
        ownerID: ownerID,
        journeyID: journeyID,
        reason: .systemInterruption,
        changedAt: now()
      )
      throw JourneyRecordingError.locationStartFailed
    }
  }

  func end(journeyID: UUID) async throws -> JourneySnapshot {
    await locationDriver.stop()
    activeDriverJourneyID = nil
    _ = try await repository.beginFinalization(
      ownerID: ownerID,
      journeyID: journeyID,
      reason: .userEnded,
      endedAt: now()
    )
    return try await repository.finalizeJourney(
      ownerID: ownerID,
      journeyID: journeyID,
      finalizedAt: now()
    )
  }

  func retryFinalization(journeyID: UUID) async throws -> JourneySnapshot {
    try await repository.finalizeJourney(
      ownerID: ownerID,
      journeyID: journeyID,
      finalizedAt: now()
    )
  }

  func confirm(journeyID: UUID) async throws -> JourneySnapshot {
    try await repository.confirmSummary(
      ownerID: ownerID,
      journeyID: journeyID,
      confirmedAt: now()
    )
  }

  func discard(journeyID: UUID) async throws -> JourneySnapshot {
    await locationDriver.stop()
    activeDriverJourneyID = nil
    return try await repository.discardJourney(
      ownerID: ownerID,
      journeyID: journeyID,
      discardedAt: now()
    )
  }

  func delete(journeyID: UUID) async throws {
    try await repository.deleteJourney(ownerID: ownerID, journeyID: journeyID)
  }

  func suspendForLocalDataReset() async -> JourneySnapshot? {
    guard let activeDriverJourneyID,
      let journey = try? await repository.journey(
        ownerID: ownerID,
        journeyID: activeDriverJourneyID
      )
    else {
      return nil
    }
    await locationDriver.stop()
    self.activeDriverJourneyID = nil
    return journey
  }

  func restoreAfterFailedLocalDataReset(_ journey: JourneySnapshot) async throws {
    guard journey.status == .recording else { return }
    let current = try await repository.journey(ownerID: ownerID, journeyID: journey.id)
    guard current.status == .recording else { return }
    try await startDriver(for: current)
  }

  private func startDriver(for journey: JourneySnapshot) async throws {
    activeDriverJourneyID = journey.id
    do {
      try await locationDriver.start(transportMode: journey.transportMode) { [weak self] event in
        await self?.handle(event, journeyID: journey.id)
      }
    } catch {
      activeDriverJourneyID = nil
      throw error
    }
  }

  private func handle(_ event: JourneyLocationEvent, journeyID: UUID) async {
    guard activeDriverJourneyID == journeyID else { return }
    switch event {
    case .sample(let sample):
      do {
        let point = try await repository.appendSample(
          ownerID: ownerID,
          journeyID: journeyID,
          sample: sample,
          storedAt: now()
        )
        _ = try await repository.reviewPoint(
          ownerID: ownerID,
          journeyID: journeyID,
          pointID: point.id,
          reviewedAt: now()
        )
      } catch JourneyRecordingError.outOfOrderSample {
        return
      } catch JourneyRecordingError.invalidSample {
        return
      } catch {
        await locationDriver.stop()
        activeDriverJourneyID = nil
        _ = try? await repository.pauseJourney(
          ownerID: ownerID,
          journeyID: journeyID,
          reason: .storageFailure,
          changedAt: now()
        )
      }
    case .interrupted(let reason):
      await locationDriver.stop()
      activeDriverJourneyID = nil
      _ = try? await repository.pauseJourney(
        ownerID: ownerID,
        journeyID: journeyID,
        reason: reason,
        changedAt: now()
      )
    }
  }
}

nonisolated struct JourneyNavigationStartResult: Sendable, Equatable {
  let journey: JourneySnapshot
  let didOpenAppleMaps: Bool
}

nonisolated struct JourneyNavigationCoordinator: Sendable {
  private let recording: JourneyRecordingService
  private let tripPlanning: TripPlanningService

  init(
    recording: JourneyRecordingService,
    tripPlanning: TripPlanningService
  ) {
    self.recording = recording
    self.tripPlanning = tripPlanning
  }

  @MainActor
  func startRecordingAndOpenMaps(
    for plan: TripPlanSummary
  ) async throws -> JourneyNavigationStartResult {
    let journey: JourneySnapshot
    do {
      journey = try await recording.start(
        tripPlanID: plan.id,
        transportMode: plan.transportMode
      )
    } catch JourneyRecordingError.locationStartFailed {
      guard let recoverable = try await recording.currentJourney(),
        recoverable.tripPlanID == plan.id
      else {
        throw JourneyRecordingError.locationStartFailed
      }
      journey = recoverable
    }

    do {
      try await tripPlanning.openAppleMaps(for: plan)
      return JourneyNavigationStartResult(journey: journey, didOpenAppleMaps: true)
    } catch TripPlanningError.navigationOpenFailed {
      return JourneyNavigationStartResult(journey: journey, didOpenAppleMaps: false)
    }
  }
}
