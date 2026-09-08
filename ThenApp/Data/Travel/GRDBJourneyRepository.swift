import CryptoKit
import Foundation
import GRDB

nonisolated enum JourneyRepositoryFailurePoint: Sendable {
  case afterTrackPointDeletion
}

nonisolated struct GRDBJourneyRepository: JourneyRepository {
  private let database: AppDatabase
  private let failurePoint: JourneyRepositoryFailurePoint?

  init(database: AppDatabase, failurePoint: JourneyRepositoryFailurePoint? = nil) {
    self.database = database
    self.failurePoint = failurePoint
  }

  func startJourney(_ request: JourneyStartRequest) async throws -> JourneySnapshot {
    guard request.trackingConsentVersion >= 1, request.startedAt.timeIntervalSince1970 >= 0 else {
      throw JourneyRecordingError.invalidState
    }
    return try await database.pool.write { database in
      if let existing = try Self.fetchOpenJourney(
        database: database,
        ownerID: request.ownerID,
        recordingDeviceID: request.recordingDeviceID
      ) {
        if existing.id == request.journeyID { return existing }
        throw JourneyRecordingError.activeJourneyExists
      }

      let timestamp = request.startedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          INSERT INTO journeys (
            id, owner_id, trip_plan_id, recording_device_id, status, transport_mode,
            started_at, capture_completeness, raw_track_state,
            tracking_consent_version, created_at, updated_at
          ) VALUES (?, ?, ?, ?, 'recording', ?, ?, 'none', 'collecting', ?, ?, ?)
          """,
        arguments: [
          request.journeyID.lowercasedString,
          request.ownerID.lowercasedString,
          request.tripPlanID?.lowercasedString,
          request.recordingDeviceID.lowercasedString,
          request.transportMode.rawValue,
          timestamp,
          request.trackingConsentVersion,
          timestamp,
          timestamp,
        ]
      )
      try Self.insertSegment(
        database: database,
        ownerID: request.ownerID,
        journeyID: request.journeyID,
        segmentID: UUID(),
        sequence: 1,
        startedAt: request.startedAt
      )
      return try Self.fetchJourney(
        database: database, ownerID: request.ownerID, journeyID: request.journeyID)
    }
  }

  func openJourney(ownerID: UUID, recordingDeviceID: UUID) async throws -> JourneySnapshot? {
    try await database.pool.read { database in
      try Self.fetchOpenJourney(
        database: database,
        ownerID: ownerID,
        recordingDeviceID: recordingDeviceID
      )
    }
  }

  func journey(ownerID: UUID, journeyID: UUID) async throws -> JourneySnapshot {
    try await database.pool.read { database in
      try Self.fetchJourney(database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func journeys(ownerID: UUID) async throws -> [JourneySnapshot] {
    try await database.pool.read { database in
      let identifiers = try String.fetchAll(
        database,
        sql: """
          SELECT id
          FROM journeys
          WHERE owner_id = ? AND status <> 'discarded'
          ORDER BY started_at DESC, id
          """,
        arguments: [ownerID.lowercasedString]
      )
      return try identifiers.map { rawIdentifier in
        guard let identifier = UUID(uuidString: rawIdentifier) else {
          throw JourneyRecordingError.corruptedStoredJourney
        }
        return try Self.fetchJourney(
          database: database,
          ownerID: ownerID,
          journeyID: identifier
        )
      }
    }
  }

  func appendSample(
    ownerID: UUID,
    journeyID: UUID,
    sample: JourneyLocationSample,
    storedAt: Date
  ) async throws -> StoredTrackPoint {
    try Self.validate(sample)
    return try await database.pool.write { database in
      if let existing = try Self.fetchPoint(
        database: database, ownerID: ownerID, pointID: sample.id)
      {
        guard existing.journeyID == journeyID, existing.sample == sample else {
          throw JourneyRecordingError.duplicateSampleMismatch
        }
        return existing
      }

      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      guard journey.status == .recording else { throw JourneyRecordingError.invalidState }
      guard
        let segmentRow = try Row.fetchOne(
          database,
          sql: """
            SELECT id, started_at
            FROM track_segments
            WHERE owner_id = ? AND journey_id = ? AND ended_at IS NULL
            """,
          arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
        ),
        let segmentID = UUID(uuidString: segmentRow["id"])
      else {
        throw JourneyRecordingError.corruptedStoredJourney
      }
      let segmentStartedTimestamp: Double = segmentRow["started_at"]
      let segmentStartedAt = Date(timeIntervalSince1970: segmentStartedTimestamp)
      guard sample.recordedAt >= segmentStartedAt else {
        throw JourneyRecordingError.outOfOrderSample
      }

      let lastRecordedAt = try Double.fetchOne(
        database,
        sql: """
          SELECT recorded_at
          FROM track_points
          WHERE owner_id = ? AND journey_id = ?
          ORDER BY sequence DESC
          LIMIT 1
          """,
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
      if let lastRecordedAt,
        sample.recordedAt.timeIntervalSince1970 < lastRecordedAt
      {
        throw JourneyRecordingError.outOfOrderSample
      }

      let sequence =
        (try Int.fetchOne(
          database,
          sql: "SELECT MAX(sequence) FROM track_points WHERE owner_id = ? AND journey_id = ?",
          arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
        ) ?? 0) + 1
      let timestamp = storedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          INSERT INTO track_points (
            id, owner_id, journey_id, segment_id, sequence, recorded_at,
            latitude, longitude, coordinate_system, horizontal_accuracy,
            vertical_accuracy, altitude_meters, speed_meters_per_second,
            course_degrees, quality_flag, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'wgs84', ?, ?, ?, ?, ?, 'unreviewed', ?, ?)
          """,
        arguments: [
          sample.id.lowercasedString,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
          segmentID.lowercasedString,
          sequence,
          sample.recordedAt.timeIntervalSince1970,
          sample.latitude,
          sample.longitude,
          sample.horizontalAccuracy,
          sample.verticalAccuracy,
          sample.altitudeMeters,
          sample.speedMetersPerSecond,
          sample.courseDegrees,
          timestamp,
          timestamp,
        ]
      )
      guard
        let storedPoint = try Self.fetchPoint(
          database: database, ownerID: ownerID, pointID: sample.id)
      else {
        throw JourneyRecordingError.corruptedStoredJourney
      }
      return storedPoint
    }
  }

  func reviewPoint(
    ownerID: UUID,
    journeyID: UUID,
    pointID: UUID,
    reviewedAt: Date
  ) async throws -> StoredTrackPoint {
    try await database.pool.write { database in
      guard
        let point = try Self.fetchPoint(database: database, ownerID: ownerID, pointID: pointID),
        point.journeyID == journeyID
      else {
        throw JourneyRecordingError.journeyNotFound
      }
      if point.quality != .unreviewed { return point }
      let quality = try Self.quality(for: point, database: database, ownerID: ownerID)
      try database.execute(
        sql: """
          UPDATE track_points
          SET quality_flag = ?, updated_at = ?
          WHERE owner_id = ? AND journey_id = ? AND id = ? AND quality_flag = 'unreviewed'
          """,
        arguments: [
          quality.rawValue,
          reviewedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
          pointID.lowercasedString,
        ]
      )
      guard
        let reviewedPoint = try Self.fetchPoint(
          database: database, ownerID: ownerID, pointID: pointID)
      else {
        throw JourneyRecordingError.corruptedStoredJourney
      }
      return reviewedPoint
    }
  }

  func pauseJourney(
    ownerID: UUID,
    journeyID: UUID,
    reason: JourneyInterruptionReason,
    changedAt: Date
  ) async throws -> JourneySnapshot {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      if journey.status == .paused { return journey }
      guard journey.status == .recording else { throw JourneyRecordingError.invalidState }
      try Self.closeOpenSegment(
        database: database,
        ownerID: ownerID,
        journeyID: journeyID,
        endedAt: changedAt,
        reason: reason == .userPaused ? "paused" : "interrupted"
      )
      try database.execute(
        sql: """
          UPDATE journeys
          SET status = 'paused', capture_completeness = 'partial',
              pause_reason = ?, updated_at = ?
          WHERE owner_id = ? AND id = ? AND status = 'recording'
          """,
        arguments: [
          reason.rawValue,
          changedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
        ]
      )
      return try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func resumeJourney(
    ownerID: UUID,
    journeyID: UUID,
    newSegmentID: UUID,
    resumedAt: Date
  ) async throws -> JourneySnapshot {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      guard [.paused, .finalizing, .reviewing].contains(journey.status) else {
        throw JourneyRecordingError.invalidState
      }
      let nextSequence =
        (try Int.fetchOne(
          database,
          sql: "SELECT MAX(sequence) FROM track_segments WHERE owner_id = ? AND journey_id = ?",
          arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
        ) ?? 0) + 1
      try database.execute(
        sql: """
          UPDATE journeys
          SET status = 'recording', ended_at = NULL, distance_meters = NULL,
              duration_seconds = NULL, capture_completeness = 'partial',
              raw_track_state = 'collecting', final_sequence = NULL,
              point_count = NULL, manifest_hash = NULL, termination_reason = NULL,
              pause_reason = NULL, updated_at = ?
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [
          resumedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
        ]
      )
      try Self.insertSegment(
        database: database,
        ownerID: ownerID,
        journeyID: journeyID,
        segmentID: newSegmentID,
        sequence: nextSequence,
        startedAt: resumedAt
      )
      return try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func beginFinalization(
    ownerID: UUID,
    journeyID: UUID,
    reason: JourneyTerminationReason,
    endedAt: Date
  ) async throws -> JourneySnapshot {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      if [.finalizing, .reviewing].contains(journey.status) { return journey }
      guard [.recording, .paused].contains(journey.status), endedAt >= journey.startedAt else {
        throw JourneyRecordingError.invalidState
      }
      if journey.status == .recording {
        try Self.closeOpenSegment(
          database: database,
          ownerID: ownerID,
          journeyID: journeyID,
          endedAt: endedAt,
          reason: "finalizing"
        )
      }
      try database.execute(
        sql: """
          UPDATE journeys
          SET status = 'finalizing', ended_at = ?, termination_reason = ?,
              pause_reason = NULL, updated_at = ?
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [
          endedAt.timeIntervalSince1970,
          reason.rawValue,
          endedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
        ]
      )
      return try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func finalizeJourney(
    ownerID: UUID,
    journeyID: UUID,
    finalizedAt: Date
  ) async throws -> JourneySnapshot {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      if journey.status == .reviewing { return journey }
      guard journey.status == .finalizing, let endedAt = journey.endedAt else {
        throw JourneyRecordingError.invalidState
      }

      let pendingIDs = try String.fetchAll(
        database,
        sql: """
          SELECT id FROM track_points
          WHERE owner_id = ? AND journey_id = ? AND quality_flag = 'unreviewed'
          ORDER BY sequence
          """,
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
      for rawID in pendingIDs {
        guard let pointID = UUID(uuidString: rawID),
          let point = try Self.fetchPoint(database: database, ownerID: ownerID, pointID: pointID)
        else {
          throw JourneyRecordingError.corruptedStoredJourney
        }
        let quality = try Self.quality(for: point, database: database, ownerID: ownerID)
        try database.execute(
          sql:
            "UPDATE track_points SET quality_flag = ?, updated_at = ? WHERE owner_id = ? AND id = ?",
          arguments: [
            quality.rawValue,
            finalizedAt.timeIntervalSince1970,
            ownerID.lowercasedString,
            pointID.lowercasedString,
          ]
        )
      }

      let points = try Self.fetchPoints(
        database: database, ownerID: ownerID, journeyID: journeyID)
      let segmentCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM track_segments WHERE owner_id = ? AND journey_id = ?",
          arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
        ) ?? 0
      let distance = Self.projectedDistance(points)
      let hasRejectedPoint = points.contains { $0.quality != .accepted }
      let completeness: JourneyCaptureCompleteness
      if points.isEmpty {
        completeness = .none
      } else if journey.captureCompleteness == .partial || segmentCount > 1 || hasRejectedPoint {
        completeness = .partial
      } else {
        completeness = .complete
      }
      let finalSequence = points.last?.sequence ?? 0
      let manifest = Self.manifestHash(points)
      try database.execute(
        sql: """
          UPDATE journeys
          SET status = 'reviewing', distance_meters = ?, duration_seconds = ?,
              capture_completeness = ?, raw_track_state = 'awaiting_summary_confirmation',
              final_sequence = ?, point_count = ?, manifest_hash = ?, updated_at = ?
          WHERE owner_id = ? AND id = ? AND status = 'finalizing'
          """,
        arguments: [
          distance,
          endedAt.timeIntervalSince(journey.startedAt),
          completeness.rawValue,
          finalSequence,
          points.count,
          manifest,
          finalizedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
        ]
      )
      return try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func confirmSummary(
    ownerID: UUID,
    journeyID: UUID,
    confirmedAt: Date
  ) async throws -> JourneySnapshot {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      if journey.status == .completed { return journey }
      guard journey.status == .reviewing else { throw JourneyRecordingError.invalidState }
      try database.execute(
        sql: "DELETE FROM track_points WHERE owner_id = ? AND journey_id = ?",
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
      if failurePoint == .afterTrackPointDeletion {
        throw JourneyRecordingError.invalidState
      }
      try database.execute(
        sql: "DELETE FROM track_segments WHERE owner_id = ? AND journey_id = ?",
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
      try database.execute(
        sql: """
          UPDATE journeys
          SET status = 'completed', raw_track_state = 'purged', updated_at = ?
          WHERE owner_id = ? AND id = ? AND status = 'reviewing'
          """,
        arguments: [
          confirmedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
        ]
      )
      return try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func discardJourney(
    ownerID: UUID,
    journeyID: UUID,
    discardedAt: Date
  ) async throws -> JourneySnapshot {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
      if journey.status == .discarded { return journey }
      guard journey.status != .completed else { throw JourneyRecordingError.invalidState }
      try database.execute(
        sql: "DELETE FROM track_points WHERE owner_id = ? AND journey_id = ?",
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
      try database.execute(
        sql: "DELETE FROM track_segments WHERE owner_id = ? AND journey_id = ?",
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
      try database.execute(
        sql: """
          UPDATE journeys
          SET status = 'discarded', ended_at = COALESCE(ended_at, ?),
              raw_track_state = 'purged', termination_reason = 'discarded',
              pause_reason = NULL, updated_at = ?
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [
          discardedAt.timeIntervalSince1970,
          discardedAt.timeIntervalSince1970,
          ownerID.lowercasedString,
          journeyID.lowercasedString,
        ]
      )
      return try Self.fetchJourney(
        database: database, ownerID: ownerID, journeyID: journeyID)
    }
  }

  func deleteJourney(ownerID: UUID, journeyID: UUID) async throws {
    try await database.pool.write { database in
      let journey = try Self.fetchJourney(
        database: database,
        ownerID: ownerID,
        journeyID: journeyID
      )
      guard journey.status == .completed || journey.status == .discarded else {
        throw JourneyRecordingError.invalidState
      }
      try database.execute(
        sql: "DELETE FROM journeys WHERE owner_id = ? AND id = ?",
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      )
    }
  }

  private static func validate(_ sample: JourneyLocationSample) throws {
    guard sample.recordedAt.timeIntervalSince1970 >= 0,
      sample.latitude.isFinite,
      sample.longitude.isFinite,
      (-90...90).contains(sample.latitude),
      (-180...180).contains(sample.longitude),
      sample.horizontalAccuracy.isFinite,
      sample.horizontalAccuracy >= 0,
      sample.verticalAccuracy.map({ $0.isFinite && $0 >= 0 }) ?? true,
      sample.altitudeMeters.map(\.isFinite) ?? true,
      sample.speedMetersPerSecond.map({ $0.isFinite && $0 >= 0 }) ?? true,
      sample.courseDegrees.map({ $0.isFinite && (0...360).contains($0) }) ?? true
    else {
      throw JourneyRecordingError.invalidSample
    }
  }

  private static func insertSegment(
    database: Database,
    ownerID: UUID,
    journeyID: UUID,
    segmentID: UUID,
    sequence: Int,
    startedAt: Date
  ) throws {
    let timestamp = startedAt.timeIntervalSince1970
    try database.execute(
      sql: """
        INSERT INTO track_segments (
          id, owner_id, journey_id, sequence, started_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        segmentID.lowercasedString,
        ownerID.lowercasedString,
        journeyID.lowercasedString,
        sequence,
        timestamp,
        timestamp,
        timestamp,
      ]
    )
  }

  private static func closeOpenSegment(
    database: Database,
    ownerID: UUID,
    journeyID: UUID,
    endedAt: Date,
    reason: String
  ) throws {
    try database.execute(
      sql: """
        UPDATE track_segments
        SET ended_at = MAX(started_at, ?), end_reason = ?, updated_at = ?
        WHERE owner_id = ? AND journey_id = ? AND ended_at IS NULL
        """,
      arguments: [
        endedAt.timeIntervalSince1970,
        reason,
        endedAt.timeIntervalSince1970,
        ownerID.lowercasedString,
        journeyID.lowercasedString,
      ]
    )
    guard database.changesCount == 1 else {
      throw JourneyRecordingError.corruptedStoredJourney
    }
  }

  private static func fetchOpenJourney(
    database: Database,
    ownerID: UUID,
    recordingDeviceID: UUID
  ) throws -> JourneySnapshot? {
    let rawID = try String.fetchOne(
      database,
      sql: """
        SELECT id FROM journeys
        WHERE owner_id = ? AND recording_device_id = ?
          AND status IN ('recording', 'paused', 'finalizing', 'reviewing')
        LIMIT 1
        """,
      arguments: [ownerID.lowercasedString, recordingDeviceID.lowercasedString]
    )
    guard let rawID, let journeyID = UUID(uuidString: rawID) else {
      if rawID != nil { throw JourneyRecordingError.corruptedStoredJourney }
      return nil
    }
    return try fetchJourney(database: database, ownerID: ownerID, journeyID: journeyID)
  }

  private static func fetchJourney(
    database: Database,
    ownerID: UUID,
    journeyID: UUID
  ) throws -> JourneySnapshot {
    guard
      let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM journeys WHERE owner_id = ? AND id = ?",
        arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
      ),
      let id = UUID(uuidString: row["id"]),
      let deviceID = UUID(uuidString: row["recording_device_id"]),
      let status = JourneyStatus(rawValue: row["status"]),
      let transportMode = TripTransportMode(rawValue: row["transport_mode"]),
      let completeness = JourneyCaptureCompleteness(rawValue: row["capture_completeness"]),
      let rawTrackState = JourneyRawTrackState(rawValue: row["raw_track_state"])
    else {
      throw JourneyRecordingError.journeyNotFound
    }
    let rawPlanID: String? = row["trip_plan_id"]
    let rawTermination: String? = row["termination_reason"]
    let rawPause: String? = row["pause_reason"]
    return JourneySnapshot(
      id: id,
      tripPlanID: rawPlanID.flatMap(UUID.init(uuidString:)),
      recordingDeviceID: deviceID,
      status: status,
      transportMode: transportMode,
      startedAt: Date(timeIntervalSince1970: row["started_at"]),
      endedAt: (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
      distanceMeters: row["distance_meters"],
      durationSeconds: row["duration_seconds"],
      captureCompleteness: completeness,
      rawTrackState: rawTrackState,
      finalSequence: row["final_sequence"],
      pointCount: row["point_count"],
      terminationReason: rawTermination.flatMap(JourneyTerminationReason.init(rawValue:)),
      pauseReason: rawPause.flatMap(JourneyInterruptionReason.init(rawValue:))
    )
  }

  private static func fetchPoint(
    database: Database,
    ownerID: UUID,
    pointID: UUID
  ) throws -> StoredTrackPoint? {
    guard
      let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM track_points WHERE owner_id = ? AND id = ?",
        arguments: [ownerID.lowercasedString, pointID.lowercasedString]
      )
    else { return nil }
    return try point(from: row)
  }

  private static func fetchPoints(
    database: Database,
    ownerID: UUID,
    journeyID: UUID
  ) throws -> [StoredTrackPoint] {
    try Row.fetchAll(
      database,
      sql: """
        SELECT * FROM track_points
        WHERE owner_id = ? AND journey_id = ?
        ORDER BY sequence
        """,
      arguments: [ownerID.lowercasedString, journeyID.lowercasedString]
    ).map(point(from:))
  }

  private static func point(from row: Row) throws -> StoredTrackPoint {
    guard let id = UUID(uuidString: row["id"]),
      let journeyID = UUID(uuidString: row["journey_id"]),
      let segmentID = UUID(uuidString: row["segment_id"]),
      let quality = TrackPointQuality(rawValue: row["quality_flag"])
    else {
      throw JourneyRecordingError.corruptedStoredJourney
    }
    let verticalAccuracy: Double? = row["vertical_accuracy"]
    let altitude: Double? = row["altitude_meters"]
    let speed: Double? = row["speed_meters_per_second"]
    let course: Double? = row["course_degrees"]
    let sample = JourneyLocationSample(
      id: id,
      recordedAt: Date(timeIntervalSince1970: row["recorded_at"]),
      latitude: row["latitude"],
      longitude: row["longitude"],
      horizontalAccuracy: row["horizontal_accuracy"],
      verticalAccuracy: verticalAccuracy,
      altitudeMeters: altitude,
      speedMetersPerSecond: speed,
      courseDegrees: course
    )
    return StoredTrackPoint(
      id: id,
      journeyID: journeyID,
      segmentID: segmentID,
      sequence: row["sequence"],
      sample: sample,
      quality: quality
    )
  }

  private static func quality(
    for point: StoredTrackPoint,
    database: Database,
    ownerID: UUID
  ) throws -> TrackPointQuality {
    if point.sample.horizontalAccuracy > 100 { return .lowAccuracy }
    let previousRows = try Row.fetchAll(
      database,
      sql: """
        SELECT * FROM track_points
        WHERE owner_id = ? AND journey_id = ? AND segment_id = ?
          AND sequence < ? AND quality_flag = 'accepted'
        ORDER BY sequence DESC
        LIMIT 1
        """,
      arguments: [
        ownerID.lowercasedString,
        point.journeyID.lowercasedString,
        point.segmentID.lowercasedString,
        point.sequence,
      ]
    )
    guard let previousRow = previousRows.first else { return .accepted }
    let previous = try self.point(from: previousRow)
    let elapsed = point.sample.recordedAt.timeIntervalSince(previous.sample.recordedAt)
    let distance = haversineDistance(previous.sample, point.sample)
    if distance > max(200, max(elapsed, 1) * 80) { return .implausibleJump }
    return .accepted
  }

  private static func projectedDistance(_ points: [StoredTrackPoint]) -> Double {
    var total = 0.0
    var previous: StoredTrackPoint?
    for point in points {
      guard point.quality == .accepted else {
        previous = nil
        continue
      }
      if let previous, previous.segmentID == point.segmentID {
        total += haversineDistance(previous.sample, point.sample)
      }
      previous = point
    }
    return total
  }

  private static func haversineDistance(
    _ first: JourneyLocationSample,
    _ second: JourneyLocationSample
  ) -> Double {
    let radius = 6_371_000.0
    let firstLatitude = first.latitude * .pi / 180
    let secondLatitude = second.latitude * .pi / 180
    let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
    let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
    let value =
      sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
      + cos(firstLatitude) * cos(secondLatitude)
      * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
    return radius * 2 * atan2(sqrt(value), sqrt(1 - value))
  }

  private static func manifestHash(_ points: [StoredTrackPoint]) -> Data {
    var payload = Data()
    for point in points {
      append(point.id.uuidString.lowercased(), to: &payload)
      append(point.segmentID.uuidString.lowercased(), to: &payload)
      append(UInt64(point.sequence), to: &payload)
      append(point.sample.recordedAt.timeIntervalSince1970.bitPattern, to: &payload)
      append(point.sample.latitude.bitPattern, to: &payload)
      append(point.sample.longitude.bitPattern, to: &payload)
      append(point.sample.horizontalAccuracy.bitPattern, to: &payload)
      append(point.quality.rawValue, to: &payload)
    }
    return Data(SHA256.hash(data: payload))
  }

  private static func append(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    append(UInt64(bytes.count), to: &data)
    data.append(bytes)
  }

  private static func append(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
}

extension UUID {
  nonisolated fileprivate var lowercasedString: String { uuidString.lowercased() }
}
