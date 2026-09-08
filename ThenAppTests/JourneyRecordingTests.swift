import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("实际行程、临时轨迹与恢复")
struct JourneyRecordingTests {
  @Test("同一设备只允许一个未收口行程且重复开始幂等")
  func startIsIdempotentAndUniquePerDevice() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let request = makeJourneyStart(ownerID: identity.profileID)

      let first = try await repository.startJourney(request)
      let repeated = try await repository.startJourney(request)
      #expect(first == repeated)

      do {
        _ = try await repository.startJourney(
          makeJourneyStart(
            journeyID: UUID(),
            ownerID: identity.profileID,
            deviceID: request.recordingDeviceID
          )
        )
        Issue.record("同一设备不能并存第二个未收口行程")
      } catch let error as JourneyRecordingError {
        #expect(error == .activeJourneyExists)
      }

      let counts = try await database.pool.read { database in
        (
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM journeys"),
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_segments")
        )
      }
      #expect(counts == (1, 1))
    }
  }

  @Test("样本先以未复核状态落盘并拒绝错序与异载荷重复")
  func samplesLandBeforeReview() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let request = makeJourneyStart(ownerID: identity.profileID)
      _ = try await repository.startJourney(request)
      let sample = makeJourneySample(byte: 0x11, second: 110, latitude: 31.2)

      let stored = try await repository.appendSample(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        sample: sample,
        storedAt: journeyDate(111)
      )
      #expect(stored.quality == .unreviewed)
      let reviewed = try await repository.reviewPoint(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        pointID: sample.id,
        reviewedAt: journeyDate(112)
      )
      #expect(reviewed.quality == .accepted)
      let repeated = try await repository.appendSample(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        sample: sample,
        storedAt: journeyDate(113)
      )
      #expect(repeated.sequence == 1)

      let mismatched = JourneyLocationSample(
        id: sample.id,
        recordedAt: sample.recordedAt,
        latitude: sample.latitude + 0.01,
        longitude: sample.longitude,
        horizontalAccuracy: sample.horizontalAccuracy,
        verticalAccuracy: nil,
        altitudeMeters: nil,
        speedMetersPerSecond: nil,
        courseDegrees: nil
      )
      await #expect(throws: JourneyRecordingError.duplicateSampleMismatch) {
        try await repository.appendSample(
          ownerID: identity.profileID,
          journeyID: request.journeyID,
          sample: mismatched,
          storedAt: journeyDate(114)
        )
      }
      await #expect(throws: JourneyRecordingError.outOfOrderSample) {
        try await repository.appendSample(
          ownerID: identity.profileID,
          journeyID: request.journeyID,
          sample: makeJourneySample(byte: 0x12, second: 109, latitude: 31.2),
          storedAt: journeyDate(115)
        )
      }
      let pointCount = try await database.pool.read { database in
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_points")
      }
      #expect(pointCount == 1)
    }
  }

  @Test("暂停恢复创建新片段且确认摘要原子删除原始轨迹")
  func pauseResumeFinalizeAndConfirm() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let request = makeJourneyStart(ownerID: identity.profileID)
      _ = try await repository.startJourney(request)
      for sample in [
        makeJourneySample(byte: 0x21, second: 110, latitude: 31.2000),
        makeJourneySample(byte: 0x22, second: 120, latitude: 31.2010),
      ] {
        _ = try await repository.appendSample(
          ownerID: identity.profileID,
          journeyID: request.journeyID,
          sample: sample,
          storedAt: sample.recordedAt
        )
        _ = try await repository.reviewPoint(
          ownerID: identity.profileID,
          journeyID: request.journeyID,
          pointID: sample.id,
          reviewedAt: sample.recordedAt
        )
      }
      _ = try await repository.pauseJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        reason: .userPaused,
        changedAt: journeyDate(125)
      )
      _ = try await repository.resumeJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        newSegmentID: UUID(),
        resumedAt: journeyDate(130)
      )
      let third = makeJourneySample(byte: 0x23, second: 140, latitude: 31.2020)
      _ = try await repository.appendSample(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        sample: third,
        storedAt: third.recordedAt
      )
      _ = try await repository.reviewPoint(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        pointID: third.id,
        reviewedAt: third.recordedAt
      )
      _ = try await repository.beginFinalization(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        reason: .userEnded,
        endedAt: journeyDate(200)
      )
      let reviewing = try await repository.finalizeJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        finalizedAt: journeyDate(201)
      )
      let repeatedFinalization = try await repository.finalizeJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        finalizedAt: journeyDate(202)
      )
      #expect(repeatedFinalization == reviewing)
      #expect(reviewing.status == .reviewing)
      #expect(reviewing.captureCompleteness == .partial)
      #expect(reviewing.pointCount == 3)
      #expect(reviewing.finalSequence == 3)
      #expect((reviewing.distanceMeters ?? 0) > 100)
      #expect((reviewing.distanceMeters ?? 0) < 120)

      let beforeConfirmation = try await database.pool.read { database in
        let segmentCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_segments")
        let pointCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_points")
        let manifestLength = try Int.fetchOne(
          database,
          sql: "SELECT length(manifest_hash) FROM journeys WHERE id = ?",
          arguments: [request.journeyID.uuidString.lowercased()]
        )
        return (segmentCount, pointCount, manifestLength)
      }
      #expect(beforeConfirmation == (2, 3, 32))

      let completed = try await repository.confirmSummary(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        confirmedAt: journeyDate(203)
      )
      #expect(completed.status == .completed)
      #expect(completed.rawTrackState == .purged)
      let afterConfirmation = try await database.pool.read { database in
        (
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_segments"),
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_points")
        )
      }
      #expect(afterConfirmation == (0, 0))
    }
  }

  @Test("丢弃进行中行程会删除所有临时轨迹且不留恢复入口")
  func discardPurgesTemporaryTrack() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let request = makeJourneyStart(ownerID: identity.profileID)
      _ = try await repository.startJourney(request)
      let sample = makeJourneySample(byte: 0x41, second: 110, latitude: 31.2)
      _ = try await repository.appendSample(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        sample: sample,
        storedAt: sample.recordedAt
      )

      let discarded = try await repository.discardJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        discardedAt: journeyDate(120)
      )
      #expect(discarded.status == .discarded)
      #expect(discarded.rawTrackState == .purged)
      #expect(discarded.terminationReason == .discarded)
      #expect(
        try await repository.openJourney(
          ownerID: identity.profileID,
          recordingDeviceID: request.recordingDeviceID
        ) == nil)
      let counts = try await database.pool.read { database in
        (
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_points"),
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_segments")
        )
      }
      #expect(counts == (0, 0))
    }
  }

  @Test("无定位点也能生成完整时间摘要")
  func noPointJourneyCanFinish() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let request = makeJourneyStart(ownerID: identity.profileID)
      _ = try await repository.startJourney(request)
      _ = try await repository.beginFinalization(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        reason: .permissionDenied,
        endedAt: journeyDate(160)
      )
      let summary = try await repository.finalizeJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        finalizedAt: journeyDate(161)
      )
      #expect(summary.status == .reviewing)
      #expect(summary.captureCompleteness == .none)
      #expect(summary.distanceMeters == 0)
      #expect(summary.durationSeconds == 60)
      #expect(summary.finalSequence == 0)
      #expect(summary.pointCount == 0)
    }
  }

  @Test("原始点清理中途失败时摘要状态和全部点回滚")
  func confirmationFailureRollsBackCleanup() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let request = makeJourneyStart(ownerID: identity.profileID)
      _ = try await repository.startJourney(request)
      let sample = makeJourneySample(byte: 0x31, second: 110, latitude: 31.2)
      _ = try await repository.appendSample(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        sample: sample,
        storedAt: sample.recordedAt
      )
      _ = try await repository.beginFinalization(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        reason: .userEnded,
        endedAt: journeyDate(140)
      )
      _ = try await repository.finalizeJourney(
        ownerID: identity.profileID,
        journeyID: request.journeyID,
        finalizedAt: journeyDate(141)
      )

      let failingRepository = GRDBJourneyRepository(
        database: database,
        failurePoint: .afterTrackPointDeletion
      )
      await #expect(throws: JourneyRecordingError.invalidState) {
        try await failingRepository.confirmSummary(
          ownerID: identity.profileID,
          journeyID: request.journeyID,
          confirmedAt: journeyDate(142)
        )
      }
      let snapshot = try await database.pool.read { database in
        (
          try String.fetchOne(database, sql: "SELECT status FROM journeys"),
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_points"),
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM track_segments")
        )
      }
      #expect(snapshot == ("reviewing", 1, 1))
    }
  }

  @Test("定位驱动启动失败时保留可恢复的暂停行程")
  func driverFailurePreservesJourney() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let deviceID = UUID()
      let repository = GRDBJourneyRepository(database: database)
      let service = JourneyRecordingService(
        ownerID: identity.profileID,
        recordingDeviceID: deviceID,
        repository: repository,
        locationDriver: FixedJourneyLocationDriver(shouldFailStart: true),
        now: { journeyDate(100) }
      )
      await #expect(throws: JourneyRecordingError.locationStartFailed) {
        try await service.start(tripPlanID: nil, transportMode: .walking)
      }
      let current = try await service.currentJourney()
      #expect(current?.status == .paused)
      #expect(current?.pauseReason == .systemInterruption)
      #expect(current?.captureCompleteness == .partial)
    }
  }

  @Test("行程列表保留未收口与完成摘要但排除已丢弃记录")
  func journeyListExcludesDiscardedRecords() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeJourneyIdentity(database)
      let repository = GRDBJourneyRepository(database: database)
      let completedRequest = makeJourneyStart(ownerID: identity.profileID)
      _ = try await repository.startJourney(completedRequest)
      _ = try await repository.beginFinalization(
        ownerID: identity.profileID,
        journeyID: completedRequest.journeyID,
        reason: .userEnded,
        endedAt: journeyDate(160)
      )
      _ = try await repository.finalizeJourney(
        ownerID: identity.profileID,
        journeyID: completedRequest.journeyID,
        finalizedAt: journeyDate(161)
      )
      _ = try await repository.confirmSummary(
        ownerID: identity.profileID,
        journeyID: completedRequest.journeyID,
        confirmedAt: journeyDate(162)
      )

      let discardedRequest = makeJourneyStart(
        ownerID: identity.profileID,
        deviceID: completedRequest.recordingDeviceID
      )
      _ = try await repository.startJourney(discardedRequest)
      _ = try await repository.discardJourney(
        ownerID: identity.profileID,
        journeyID: discardedRequest.journeyID,
        discardedAt: journeyDate(170)
      )

      let journeys = try await repository.journeys(ownerID: identity.profileID)
      #expect(journeys.map(\.id) == [completedRequest.journeyID])
      #expect(journeys[0].status == .completed)
    }
  }
}

private nonisolated func makeJourneyIdentity(_ database: AppDatabase) throws
  -> LocalLedgerIdentity
{
  try LocalLedgerBootstrap(database: database).initializeIfNeeded(
    suggestedCurrencyCode: .cny,
    now: journeyDate(10)
  )
}

private nonisolated func makeJourneyStart(
  journeyID: UUID = UUID(),
  ownerID: UUID,
  deviceID: UUID = UUID()
) -> JourneyStartRequest {
  JourneyStartRequest(
    journeyID: journeyID,
    ownerID: ownerID,
    tripPlanID: nil,
    recordingDeviceID: deviceID,
    transportMode: .walking,
    startedAt: journeyDate(100),
    trackingConsentVersion: 1
  )
}

private nonisolated func makeJourneySample(
  byte: UInt8,
  second: TimeInterval,
  latitude: Double
) -> JourneyLocationSample {
  JourneyLocationSample(
    id: UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)),
    recordedAt: journeyDate(second),
    latitude: latitude,
    longitude: 121.4,
    horizontalAccuracy: 8,
    verticalAccuracy: 12,
    altitudeMeters: 5,
    speedMetersPerSecond: 3,
    courseDegrees: 20
  )
}

private nonisolated func journeyDate(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

private actor FixedJourneyLocationDriver: JourneyLocationDriver {
  private let shouldFailStart: Bool
  private var handler: (@Sendable (JourneyLocationEvent) async -> Void)?

  init(shouldFailStart: Bool) {
    self.shouldFailStart = shouldFailStart
  }

  func start(
    transportMode: TripTransportMode,
    handler: @escaping @Sendable (JourneyLocationEvent) async -> Void
  ) async throws {
    if shouldFailStart { throw JourneyRecordingError.locationStartFailed }
    self.handler = handler
  }

  func stop() async {
    handler = nil
  }
}
