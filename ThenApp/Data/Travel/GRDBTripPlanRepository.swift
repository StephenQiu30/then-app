import Foundation
import GRDB

nonisolated struct GRDBTripPlanRepository: TripPlanRepository {
  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  func savePlan(_ request: SaveTripPlanRequest) async throws -> TripPlanSummary {
    try Self.validate(request)
    return try await database.pool.write { database in
      let owner = request.ownerID.uuidString.lowercased()
      let plan = request.planID.uuidString.lowercased()
      if try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM trip_plans WHERE owner_id = ? AND id = ?",
        arguments: [owner, plan]
      ) == 1 {
        return try Self.fetchPlan(
          database: database, ownerID: request.ownerID, planID: request.planID)
      }

      if let eventSource = request.eventSource {
        guard
          let storedSourceVersion = try Int.fetchOne(
            database,
            sql: """
              SELECT source_version
              FROM calendar_occurrences
              WHERE owner_id = ? AND id = ? AND source_state IN ('active', 'missing')
              """,
            arguments: [owner, eventSource.occurrenceID.uuidString.lowercased()]
          )
        else {
          throw TripPlanningError.staleEventSource
        }
        guard storedSourceVersion == eventSource.sourceVersion else {
          throw TripPlanningError.staleEventSource
        }
        guard
          try Int.fetchOne(
            database,
            sql: """
              SELECT COUNT(*)
              FROM event_trip_links
              WHERE owner_id = ? AND calendar_occurrence_id = ?
              """,
            arguments: [owner, eventSource.occurrenceID.uuidString.lowercased()]
          ) == 0
        else {
          throw TripPlanningError.eventAlreadyLinked
        }
      }

      try Self.insertLocation(
        database: database, ownerID: request.ownerID, location: request.destination,
        createdAt: request.submittedAt)
      if let origin = request.origin {
        try Self.insertLocation(
          database: database, ownerID: request.ownerID, location: origin,
          createdAt: request.submittedAt)
      }

      let timestamp = request.submittedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          INSERT INTO trip_plans (
            id, owner_id, display_name, origin_snapshot_id, destination_snapshot_id,
            transport_mode, target_arrival_at, planned_departure_at, timezone_id,
            preparation_buffer_seconds, source_occurrence_version,
            display_name_value_source, display_name_user_overridden_at,
            destination_value_source, target_arrival_value_source,
            transport_value_source, departure_value_source,
            destination_user_overridden_at, target_arrival_user_overridden_at,
            transport_user_overridden_at, departure_user_overridden_at,
            status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'user', ?, ?, ?, ?, ?, 'planned', ?, ?)
          """,
        arguments: [
          plan,
          owner,
          Self.normalizedOptional(request.displayName, limit: 200),
          request.origin?.id.uuidString.lowercased(),
          request.destination.id.uuidString.lowercased(),
          request.transportMode.rawValue,
          request.targetArrivalAt.timeIntervalSince1970,
          request.plannedDepartureAt.timeIntervalSince1970,
          request.timezoneIdentifier,
          request.preparationBufferSeconds,
          request.eventSource?.sourceVersion,
          request.displayNameValueSource.rawValue,
          request.displayNameValueSource == .user ? timestamp : nil,
          request.destinationValueSource.rawValue,
          request.targetArrivalValueSource.rawValue,
          request.departureValueSource.rawValue,
          request.destinationValueSource == .user ? timestamp : nil,
          request.targetArrivalValueSource == .user ? timestamp : nil,
          timestamp,
          request.departureValueSource == .user ? timestamp : nil,
          timestamp,
          timestamp,
        ]
      )

      if let route = request.routeEstimate {
        guard let origin = request.origin,
          origin.id == route.origin.id,
          request.destination.id == route.destination.id,
          request.transportMode == route.transportMode
        else {
          throw TripPlanningError.routeRequiresOrigin
        }
        try database.execute(
          sql: """
            INSERT INTO route_estimates (
              id, owner_id, trip_plan_id, origin_snapshot_id, destination_snapshot_id,
              transport_mode, provider, coordinate_system, distance_meters,
              expected_travel_seconds, calculated_at, expires_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'mapkit', 'wgs84', ?, ?, ?, ?, ?)
            """,
          arguments: [
            route.id.uuidString.lowercased(),
            owner,
            plan,
            origin.id.uuidString.lowercased(),
            request.destination.id.uuidString.lowercased(),
            route.transportMode.rawValue,
            route.distanceMeters,
            route.expectedTravelSeconds,
            route.calculatedAt.timeIntervalSince1970,
            route.expiresAt.timeIntervalSince1970,
            timestamp,
          ]
        )
        try database.execute(
          sql: "UPDATE trip_plans SET selected_route_estimate_id = ? WHERE owner_id = ? AND id = ?",
          arguments: [route.id.uuidString.lowercased(), owner, plan]
        )
      }

      try database.execute(
        sql: """
          INSERT INTO departure_reminders (
            id, owner_id, trip_plan_id, notification_request_id, is_enabled,
            fire_at, follows_source, schedule_version, status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
          """,
        arguments: [
          UUID().uuidString.lowercased(),
          owner,
          plan,
          "trip-plan-\(plan)-departure-v1",
          request.reminderEnabled,
          request.reminderEnabled ? request.plannedDepartureAt.timeIntervalSince1970 : nil,
          request.reminderFollowsSource,
          request.reminderEnabled
            ? DepartureReminderStatus.notRequested.rawValue
            : DepartureReminderStatus.disabled.rawValue,
          timestamp,
          timestamp,
        ]
      )

      if let eventSource = request.eventSource {
        try database.execute(
          sql: """
            INSERT INTO event_trip_links (
              id, owner_id, calendar_occurrence_id, trip_plan_id,
              source_occurrence_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            UUID().uuidString.lowercased(),
            owner,
            eventSource.occurrenceID.uuidString.lowercased(),
            plan,
            eventSource.sourceVersion,
            timestamp,
          ]
        )
      }
      return try Self.fetchPlan(
        database: database, ownerID: request.ownerID, planID: request.planID)
    }
  }

  func plans(ownerID: UUID) async throws -> [TripPlanSummary] {
    try await database.pool.read { database in
      let planIDs = try String.fetchAll(
        database,
        sql: """
          SELECT id
          FROM trip_plans
          WHERE owner_id = ?
          ORDER BY
            status IN ('cancelled', 'completed'),
            planned_departure_at IS NULL,
            planned_departure_at,
            id
          """,
        arguments: [ownerID.uuidString.lowercased()]
      )
      return try planIDs.map { rawID in
        guard let planID = UUID(uuidString: rawID) else {
          throw TripPlanningError.corruptedStoredPlan
        }
        return try Self.fetchPlan(database: database, ownerID: ownerID, planID: planID)
      }
    }
  }

  func linkedPlans(ownerID: UUID, occurrenceID: UUID) async throws -> [TripPlanSummary] {
    try await database.pool.read { database in
      let planIDs = try String.fetchAll(
        database,
        sql: """
          SELECT trip_plan_id
          FROM event_trip_links
          WHERE owner_id = ? AND calendar_occurrence_id = ?
          ORDER BY created_at, id
          """,
        arguments: [
          ownerID.uuidString.lowercased(),
          occurrenceID.uuidString.lowercased(),
        ]
      )
      return try planIDs.map { rawID in
        guard let planID = UUID(uuidString: rawID) else {
          throw TripPlanningError.corruptedStoredPlan
        }
        return try Self.fetchPlan(database: database, ownerID: ownerID, planID: planID)
      }
    }
  }

  func adoptCalendarRevision(_ request: AdoptCalendarRevisionRequest) async throws
    -> TripPlanSummary
  {
    try Self.validate(request)
    return try await database.pool.write { database in
      let owner = request.ownerID.uuidString.lowercased()
      let plan = request.planID.uuidString.lowercased()
      let occurrence = request.occurrenceID.uuidString.lowercased()
      let linkedPlanCount =
        try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM event_trip_links
            WHERE owner_id = ? AND calendar_occurrence_id = ?
            """,
          arguments: [owner, occurrence]
        ) ?? 0
      guard linkedPlanCount > 0 else { throw TripPlanningError.planNotFound }
      guard linkedPlanCount == 1 else { throw TripPlanningError.multipleEventPlans }

      guard
        let state = try Row.fetchOne(
          database,
          sql: """
            SELECT
              plan.plan_version,
              plan.status,
              plan.source_occurrence_version,
              link.source_occurrence_version AS link_source_occurrence_version
            FROM trip_plans AS plan
            JOIN event_trip_links AS link
              ON link.owner_id = plan.owner_id
             AND link.trip_plan_id = plan.id
            WHERE plan.owner_id = ?
              AND plan.id = ?
              AND link.calendar_occurrence_id = ?
            """,
          arguments: [owner, plan, occurrence]
        )
      else {
        throw TripPlanningError.planNotFound
      }
      let planVersion: Int = state["plan_version"]
      let statusRaw: String = state["status"]
      let planSourceVersion: Int? = state["source_occurrence_version"]
      let linkSourceVersion: Int = state["link_source_occurrence_version"]
      guard planVersion == request.expectedPlanVersion else {
        throw TripPlanningError.stalePlanVersion
      }
      guard
        statusRaw == TripPlanStatus.draft.rawValue
          || statusRaw == TripPlanStatus.planned.rawValue
      else {
        throw TripPlanningError.planNotEditable
      }
      guard planSourceVersion == request.expectedAdoptedSourceVersion,
        linkSourceVersion == request.expectedAdoptedSourceVersion
      else {
        throw TripPlanningError.staleEventSource
      }
      guard
        let currentSourceVersion = try Int.fetchOne(
          database,
          sql: "SELECT source_version FROM calendar_occurrences WHERE owner_id = ? AND id = ?",
          arguments: [owner, occurrence]
        ), currentSourceVersion >= request.throughSourceVersion
      else {
        throw TripPlanningError.staleEventSource
      }

      let expectedRevisionCount =
        request.throughSourceVersion - request.expectedAdoptedSourceVersion
      let storedRevisionCount =
        try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM calendar_occurrence_revisions
            WHERE owner_id = ?
              AND calendar_occurrence_id = ?
              AND from_version >= ?
              AND to_version <= ?
            """,
          arguments: [
            owner,
            occurrence,
            request.expectedAdoptedSourceVersion,
            request.throughSourceVersion,
          ]
        ) ?? 0
      guard storedRevisionCount == expectedRevisionCount else {
        throw TripPlanningError.revisionNotFound
      }
      guard
        try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM calendar_occurrence_revisions
            WHERE owner_id = ?
              AND calendar_occurrence_id = ?
              AND to_version = ?
              AND resolution_state = 'pending'
            """,
          arguments: [owner, occurrence, request.throughSourceVersion]
        ) == 1
      else {
        throw TripPlanningError.revisionNotFound
      }
      guard
        let latestPendingDetection = try Double.fetchOne(
          database,
          sql: """
            SELECT MAX(detected_at)
            FROM calendar_occurrence_revisions
            WHERE owner_id = ?
              AND calendar_occurrence_id = ?
              AND to_version <= ?
              AND resolution_state = 'pending'
            """,
          arguments: [owner, occurrence, request.throughSourceVersion]
        ), request.submittedAt.timeIntervalSince1970 >= latestPendingDetection
      else {
        throw TripPlanningError.invalidResolutionTime
      }

      try Self.insertLocationIfNeeded(
        database: database,
        ownerID: request.ownerID,
        location: request.destination,
        createdAt: request.submittedAt
      )
      if let origin = request.origin {
        try Self.insertLocationIfNeeded(
          database: database,
          ownerID: request.ownerID,
          location: origin,
          createdAt: request.submittedAt
        )
      }

      let timestamp = request.submittedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          UPDATE trip_plans
          SET display_name = ?,
              origin_snapshot_id = ?,
              destination_snapshot_id = ?,
              transport_mode = ?,
              target_arrival_at = ?,
              planned_departure_at = ?,
              timezone_id = ?,
              preparation_buffer_seconds = ?,
              selected_route_estimate_id = NULL,
              source_occurrence_version = ?,
              display_name_value_source = ?,
              display_name_user_overridden_at = ?,
              destination_value_source = ?,
              target_arrival_value_source = ?,
              transport_value_source = 'user',
              departure_value_source = ?,
              destination_user_overridden_at = ?,
              target_arrival_user_overridden_at = ?,
              transport_user_overridden_at = ?,
              departure_user_overridden_at = ?,
              plan_version = plan_version + 1,
              updated_at = ?
          WHERE owner_id = ? AND id = ? AND plan_version = ?
          """,
        arguments: [
          Self.normalizedOptional(request.displayName, limit: 200),
          request.origin?.id.uuidString.lowercased(),
          request.destination.id.uuidString.lowercased(),
          request.transportMode.rawValue,
          request.targetArrivalAt.timeIntervalSince1970,
          request.plannedDepartureAt.timeIntervalSince1970,
          request.timezoneIdentifier,
          request.preparationBufferSeconds,
          request.throughSourceVersion,
          request.displayNameValueSource.rawValue,
          request.displayNameValueSource == .user ? timestamp : nil,
          request.destinationValueSource.rawValue,
          request.targetArrivalValueSource.rawValue,
          request.departureValueSource.rawValue,
          request.destinationValueSource == .user ? timestamp : nil,
          request.targetArrivalValueSource == .user ? timestamp : nil,
          timestamp,
          request.departureValueSource == .user ? timestamp : nil,
          timestamp,
          owner,
          plan,
          request.expectedPlanVersion,
        ]
      )
      guard database.changesCount == 1 else {
        throw TripPlanningError.stalePlanVersion
      }
      try database.execute(
        sql: "DELETE FROM route_estimates WHERE owner_id = ? AND trip_plan_id = ?",
        arguments: [owner, plan]
      )
      if let route = request.routeEstimate {
        try Self.insertRouteEstimate(
          database: database,
          ownerID: request.ownerID,
          planID: request.planID,
          origin: request.origin,
          destination: request.destination,
          transportMode: request.transportMode,
          route: route,
          createdAt: request.submittedAt
        )
      }

      try database.execute(
        sql: """
          UPDATE departure_reminders
          SET is_enabled = ?,
              fire_at = ?,
              follows_source = ?,
              schedule_version = schedule_version + 1,
              status = ?,
              last_error_code = NULL,
              updated_at = ?
          WHERE owner_id = ? AND trip_plan_id = ?
          """,
        arguments: [
          request.reminderEnabled,
          request.reminderEnabled ? request.plannedDepartureAt.timeIntervalSince1970 : nil,
          request.reminderFollowsSource,
          request.reminderEnabled
            ? DepartureReminderStatus.notRequested.rawValue
            : DepartureReminderStatus.disabled.rawValue,
          timestamp,
          owner,
          plan,
        ]
      )
      guard database.changesCount == 1 else { throw TripPlanningError.planNotFound }

      try database.execute(
        sql: """
          UPDATE event_trip_links
          SET source_occurrence_version = ?
          WHERE owner_id = ?
            AND calendar_occurrence_id = ?
            AND trip_plan_id = ?
            AND source_occurrence_version = ?
          """,
        arguments: [
          request.throughSourceVersion,
          owner,
          occurrence,
          plan,
          request.expectedAdoptedSourceVersion,
        ]
      )
      guard database.changesCount == 1 else {
        throw TripPlanningError.staleEventSource
      }
      try database.execute(
        sql: """
          UPDATE calendar_occurrence_revisions
          SET resolution_state = 'accepted', resolved_at = ?
          WHERE owner_id = ?
            AND calendar_occurrence_id = ?
            AND resolution_state = 'pending'
            AND to_version <= ?
          """,
        arguments: [timestamp, owner, occurrence, request.throughSourceVersion]
      )
      guard database.changesCount > 0 else { throw TripPlanningError.revisionNotFound }

      return try Self.fetchPlan(
        database: database,
        ownerID: request.ownerID,
        planID: request.planID
      )
    }
  }

  func updateReminderState(
    ownerID: UUID,
    planID: UUID,
    status: DepartureReminderStatus,
    fireAt: Date?,
    safeErrorCode: String?,
    changedAt: Date
  ) async throws -> TripPlanSummary {
    try await database.pool.write { database in
      try database.execute(
        sql: """
          UPDATE departure_reminders
          SET status = ?, fire_at = ?, last_error_code = ?, updated_at = ?
          WHERE owner_id = ? AND trip_plan_id = ? AND is_enabled = 1
          """,
        arguments: [
          status.rawValue,
          fireAt?.timeIntervalSince1970,
          safeErrorCode.map { String($0.prefix(80)) },
          changedAt.timeIntervalSince1970,
          ownerID.uuidString.lowercased(),
          planID.uuidString.lowercased(),
        ]
      )
      guard database.changesCount == 1 else {
        throw TripPlanningError.planNotFound
      }
      return try Self.fetchPlan(database: database, ownerID: ownerID, planID: planID)
    }
  }

  func beginNavigationHandoff(
    ownerID: UUID,
    planID: UUID,
    handoffID: UUID,
    requestedAt: Date
  ) async throws {
    try await database.pool.write { database in
      try database.execute(
        sql: """
          INSERT INTO navigation_handoffs (
            id, owner_id, trip_plan_id, target_app, result, requested_at
          ) VALUES (?, ?, ?, 'apple_maps', 'requested', ?)
          """,
        arguments: [
          handoffID.uuidString.lowercased(),
          ownerID.uuidString.lowercased(),
          planID.uuidString.lowercased(),
          requestedAt.timeIntervalSince1970,
        ]
      )
    }
  }

  func completeNavigationHandoff(
    ownerID: UUID,
    handoffID: UUID,
    result: NavigationHandoffResult,
    safeErrorCode: String?,
    completedAt: Date
  ) async throws {
    guard result != .requested else {
      throw TripPlanningError.navigationOpenFailed
    }
    try await database.pool.write { database in
      try database.execute(
        sql: """
          UPDATE navigation_handoffs
          SET result = ?, completed_at = ?, safe_error_code = ?
          WHERE owner_id = ? AND id = ? AND result = 'requested'
          """,
        arguments: [
          result.rawValue,
          completedAt.timeIntervalSince1970,
          safeErrorCode.map { String($0.prefix(80)) },
          ownerID.uuidString.lowercased(),
          handoffID.uuidString.lowercased(),
        ]
      )
      guard database.changesCount == 1 else {
        throw TripPlanningError.navigationOpenFailed
      }
    }
  }

  private static func validate(_ request: SaveTripPlanRequest) throws {
    guard request.preparationBufferSeconds >= 0,
      request.preparationBufferSeconds <= 86_400
    else {
      throw TripPlanningError.invalidBuffer
    }
    guard request.targetArrivalAt > request.submittedAt else {
      throw TripPlanningError.invalidArrivalTime
    }
    guard request.plannedDepartureAt < request.targetArrivalAt else {
      throw TripPlanningError.invalidDepartureTime
    }
    guard !request.timezoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TripPlanningError.invalidArrivalTime
    }
    try validateCoordinate(request.destination)
    if let origin = request.origin { try validateCoordinate(origin) }
  }

  private static func validate(_ request: AdoptCalendarRevisionRequest) throws {
    guard request.expectedPlanVersion >= 1,
      request.expectedAdoptedSourceVersion >= 1,
      request.throughSourceVersion > request.expectedAdoptedSourceVersion
    else {
      throw TripPlanningError.staleEventSource
    }
    guard request.preparationBufferSeconds >= 0,
      request.preparationBufferSeconds <= 86_400
    else {
      throw TripPlanningError.invalidBuffer
    }
    guard request.targetArrivalAt > request.submittedAt else {
      throw TripPlanningError.invalidArrivalTime
    }
    guard request.plannedDepartureAt < request.targetArrivalAt else {
      throw TripPlanningError.invalidDepartureTime
    }
    guard !request.timezoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TripPlanningError.invalidArrivalTime
    }
    try validateCoordinate(request.destination)
    if let origin = request.origin { try validateCoordinate(origin) }
    if let route = request.routeEstimate {
      guard let origin = request.origin,
        origin.id == route.origin.id,
        request.destination.id == route.destination.id,
        request.transportMode == route.transportMode
      else {
        throw TripPlanningError.routeRequiresOrigin
      }
    }
  }

  private static func validateCoordinate(_ location: ConfirmedLocation) throws {
    if location.latitude == nil, location.longitude == nil { return }
    guard let latitude = location.latitude,
      let longitude = location.longitude,
      latitude.isFinite,
      longitude.isFinite,
      (-90...90).contains(latitude),
      (-180...180).contains(longitude)
    else {
      throw TripPlanningError.invalidCoordinate
    }
  }

  private static func insertLocation(
    database: Database,
    ownerID: UUID,
    location: ConfirmedLocation,
    createdAt: Date
  ) throws {
    try validateCoordinate(location)
    try database.execute(
      sql: """
        INSERT INTO location_snapshots (
          id, owner_id, name, address, latitude, longitude,
          coordinate_system, source, horizontal_accuracy, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        location.id.uuidString.lowercased(),
        ownerID.uuidString.lowercased(),
        normalizedRequired(location.name, limit: 200),
        normalizedOptional(location.address, limit: 500),
        location.latitude,
        location.longitude,
        location.latitude == nil ? nil : "wgs84",
        location.source.rawValue,
        location.horizontalAccuracy,
        createdAt.timeIntervalSince1970,
      ]
    )
  }

  private static func insertLocationIfNeeded(
    database: Database,
    ownerID: UUID,
    location: ConfirmedLocation,
    createdAt: Date
  ) throws {
    if try Int.fetchOne(
      database,
      sql: "SELECT COUNT(*) FROM location_snapshots WHERE owner_id = ? AND id = ?",
      arguments: [
        ownerID.uuidString.lowercased(),
        location.id.uuidString.lowercased(),
      ]
    ) == 1 {
      return
    }
    try insertLocation(
      database: database,
      ownerID: ownerID,
      location: location,
      createdAt: createdAt
    )
  }

  private static func insertRouteEstimate(
    database: Database,
    ownerID: UUID,
    planID: UUID,
    origin: ConfirmedLocation?,
    destination: ConfirmedLocation,
    transportMode: TripTransportMode,
    route: RouteEstimateDraft,
    createdAt: Date
  ) throws {
    guard let origin,
      origin.id == route.origin.id,
      destination.id == route.destination.id,
      transportMode == route.transportMode
    else {
      throw TripPlanningError.routeRequiresOrigin
    }
    let owner = ownerID.uuidString.lowercased()
    let plan = planID.uuidString.lowercased()
    try database.execute(
      sql: """
        INSERT INTO route_estimates (
          id, owner_id, trip_plan_id, origin_snapshot_id, destination_snapshot_id,
          transport_mode, provider, coordinate_system, distance_meters,
          expected_travel_seconds, calculated_at, expires_at, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'mapkit', 'wgs84', ?, ?, ?, ?, ?)
        """,
      arguments: [
        route.id.uuidString.lowercased(),
        owner,
        plan,
        origin.id.uuidString.lowercased(),
        destination.id.uuidString.lowercased(),
        route.transportMode.rawValue,
        route.distanceMeters,
        route.expectedTravelSeconds,
        route.calculatedAt.timeIntervalSince1970,
        route.expiresAt.timeIntervalSince1970,
        createdAt.timeIntervalSince1970,
      ]
    )
    try database.execute(
      sql: "UPDATE trip_plans SET selected_route_estimate_id = ? WHERE owner_id = ? AND id = ?",
      arguments: [route.id.uuidString.lowercased(), owner, plan]
    )
  }

  private static func fetchPlan(
    database: Database,
    ownerID: UUID,
    planID: UUID
  ) throws -> TripPlanSummary {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT
            plan.*,
            destination.name AS destination_name,
            destination.address AS destination_address,
            destination.latitude AS destination_latitude,
            destination.longitude AS destination_longitude,
            destination.source AS destination_source,
            destination.horizontal_accuracy AS destination_accuracy,
            origin.name AS origin_name,
            origin.address AS origin_address,
            origin.latitude AS origin_latitude,
            origin.longitude AS origin_longitude,
            origin.source AS origin_source,
            origin.horizontal_accuracy AS origin_accuracy,
            route.id AS route_id,
            route.distance_meters,
            route.expected_travel_seconds,
            route.calculated_at,
            route.expires_at,
            reminder.status AS reminder_status,
            reminder.fire_at AS reminder_fire_at,
            event_link.calendar_occurrence_id,
            event_link.source_occurrence_version AS linked_source_occurrence_version
          FROM trip_plans plan
          JOIN location_snapshots destination
            ON destination.owner_id = plan.owner_id
           AND destination.id = plan.destination_snapshot_id
          LEFT JOIN location_snapshots origin
            ON origin.owner_id = plan.owner_id
           AND origin.id = plan.origin_snapshot_id
          LEFT JOIN route_estimates route
            ON route.owner_id = plan.owner_id
           AND route.id = plan.selected_route_estimate_id
          JOIN departure_reminders reminder
            ON reminder.owner_id = plan.owner_id
           AND reminder.trip_plan_id = plan.id
          LEFT JOIN event_trip_links event_link
            ON event_link.owner_id = plan.owner_id
           AND event_link.trip_plan_id = plan.id
          WHERE plan.owner_id = ? AND plan.id = ?
          """,
        arguments: [ownerID.uuidString.lowercased(), planID.uuidString.lowercased()]
      )
    else {
      throw TripPlanningError.planNotFound
    }
    return try decodePlan(row)
  }

  private static func decodePlan(_ row: Row) throws -> TripPlanSummary {
    let planIDRaw: String = row["id"]
    let destinationIDRaw: String = row["destination_snapshot_id"]
    let modeRaw: String = row["transport_mode"]
    let statusRaw: String = row["status"]
    let reminderRaw: String = row["reminder_status"]
    let destinationSourceRaw: String = row["destination_source"]
    let displayNameValueSourceRaw: String = row["display_name_value_source"]
    let destinationValueSourceRaw: String = row["destination_value_source"]
    let targetArrivalValueSourceRaw: String = row["target_arrival_value_source"]
    let departureValueSourceRaw: String = row["departure_value_source"]
    guard let planID = UUID(uuidString: planIDRaw),
      let destinationID = UUID(uuidString: destinationIDRaw),
      let mode = TripTransportMode(rawValue: modeRaw),
      let status = TripPlanStatus(rawValue: statusRaw),
      let reminderStatus = DepartureReminderStatus(rawValue: reminderRaw),
      let destinationSource = LocationSnapshotSource(rawValue: destinationSourceRaw),
      let displayNameValueSource = TripPlanValueSource(rawValue: displayNameValueSourceRaw),
      let destinationValueSource = TripPlanValueSource(rawValue: destinationValueSourceRaw),
      let targetArrivalValueSource = TripPlanValueSource(rawValue: targetArrivalValueSourceRaw),
      let departureValueSource = TripPlanValueSource(rawValue: departureValueSourceRaw)
    else {
      throw TripPlanningError.corruptedStoredPlan
    }
    let destination = ConfirmedLocation(
      id: destinationID,
      name: row["destination_name"],
      address: row["destination_address"],
      latitude: row["destination_latitude"] as Double?,
      longitude: row["destination_longitude"] as Double?,
      source: destinationSource,
      horizontalAccuracy: row["destination_accuracy"]
    )

    var origin: ConfirmedLocation?
    let originIDRaw: String? = row["origin_snapshot_id"]
    if let originIDRaw,
      let originID = UUID(uuidString: originIDRaw),
      let originSourceRaw: String = row["origin_source"],
      let originSource = LocationSnapshotSource(rawValue: originSourceRaw)
    {
      origin = ConfirmedLocation(
        id: originID,
        name: row["origin_name"],
        address: row["origin_address"],
        latitude: row["origin_latitude"] as Double?,
        longitude: row["origin_longitude"] as Double?,
        source: originSource,
        horizontalAccuracy: row["origin_accuracy"]
      )
    }

    var route: RouteEstimateDraft?
    let routeIDRaw: String? = row["route_id"]
    if let routeIDRaw,
      let routeID = UUID(uuidString: routeIDRaw),
      let routeOrigin = origin
    {
      route = RouteEstimateDraft(
        id: routeID,
        origin: routeOrigin,
        destination: destination,
        transportMode: mode,
        distanceMeters: row["distance_meters"],
        expectedTravelSeconds: row["expected_travel_seconds"],
        calculatedAt: Date(timeIntervalSince1970: row["calculated_at"]),
        expiresAt: Date(timeIntervalSince1970: row["expires_at"])
      )
    }
    let departureTimestamp: Double? = row["planned_departure_at"]
    let reminderTimestamp: Double? = row["reminder_fire_at"]
    let linkedOccurrenceRaw: String? = row["calendar_occurrence_id"]
    let linkedOccurrenceID = try linkedOccurrenceRaw.map { rawID in
      guard let id = UUID(uuidString: rawID) else {
        throw TripPlanningError.corruptedStoredPlan
      }
      return id
    }
    return TripPlanSummary(
      id: planID,
      planVersion: row["plan_version"],
      displayName: row["display_name"],
      destination: destination,
      origin: origin,
      transportMode: mode,
      targetArrivalAt: Date(timeIntervalSince1970: row["target_arrival_at"]),
      plannedDepartureAt: departureTimestamp.map(Date.init(timeIntervalSince1970:)),
      timezoneIdentifier: row["timezone_id"],
      preparationBufferSeconds: row["preparation_buffer_seconds"],
      status: status,
      routeEstimate: route,
      reminderStatus: reminderStatus,
      reminderFireAt: reminderTimestamp.map(Date.init(timeIntervalSince1970:)),
      linkedOccurrenceID: linkedOccurrenceID,
      sourceOccurrenceVersion: row["source_occurrence_version"],
      displayNameValueSource: displayNameValueSource,
      destinationValueSource: destinationValueSource,
      targetArrivalValueSource: targetArrivalValueSource,
      departureValueSource: departureValueSource
    )
  }

  private static func normalizedRequired(_ value: String, limit: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return String((trimmed.isEmpty ? "未命名地点" : trimmed).prefix(limit))
  }

  private static func normalizedOptional(_ value: String?, limit: Int) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
  }
}
