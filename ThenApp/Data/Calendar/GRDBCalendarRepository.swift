import Foundation
import GRDB

nonisolated struct GRDBCalendarRepository: CalendarRepository {
  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  func reconcileSources(
    ownerID: UUID,
    snapshots: [SystemCalendarSourceSnapshot],
    observedAt: Date
  ) async throws -> [CalendarSourceSummary] {
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      let timestamp = observedAt.timeIntervalSince1970
      let existingRows = try Row.fetchAll(
        database,
        sql:
          "SELECT id, external_id_hmac, desired_selected FROM calendar_sources WHERE owner_id = ?",
        arguments: [owner]
      )
      var existingByHMAC: [Data: Row] = [:]
      for row in existingRows {
        existingByHMAC[row["external_id_hmac"] as Data] = row
      }
      let observedHMACs = Set(snapshots.map(\.externalIdentityHMAC))

      for snapshot in snapshots {
        guard !snapshot.externalIdentityHMAC.isEmpty else {
          throw CalendarDomainError.corruptedStoredCalendar
        }
        if let existing = existingByHMAC[snapshot.externalIdentityHMAC] {
          let desiredSelected = existing["desired_selected"] as Bool
          try database.execute(
            sql: """
              UPDATE calendar_sources
              SET title = ?,
                  source_kind = ?,
                  access_state = ?,
                  is_subscribed = ?,
                  allows_modifications = ?,
                  updated_at = ?
              WHERE owner_id = ? AND external_id_hmac = ?
              """,
            arguments: [
              Self.normalizedTitle(snapshot.title),
              snapshot.kind.rawValue,
              desiredSelected
                ? CalendarSourceAccessState.selected.rawValue
                : CalendarSourceAccessState.unselected.rawValue,
              snapshot.isSubscribed,
              snapshot.allowsContentModifications,
              timestamp,
              owner,
              snapshot.externalIdentityHMAC,
            ]
          )
        } else {
          try database.execute(
            sql: """
              INSERT INTO calendar_sources (
                id, owner_id, external_id_hmac, title, source_kind, access_state,
                desired_selected, is_subscribed, allows_modifications, created_at, updated_at
              ) VALUES (?, ?, ?, ?, ?, 'unselected', 0, ?, ?, ?, ?)
              """,
            arguments: [
              UUID().uuidString.lowercased(),
              owner,
              snapshot.externalIdentityHMAC,
              Self.normalizedTitle(snapshot.title),
              snapshot.kind.rawValue,
              snapshot.isSubscribed,
              snapshot.allowsContentModifications,
              timestamp,
              timestamp,
            ]
          )
        }
      }

      for row in existingRows {
        let hmac = row["external_id_hmac"] as Data
        guard !observedHMACs.contains(hmac) else { continue }
        try database.execute(
          sql: """
            UPDATE calendar_sources
            SET access_state = 'unavailable', updated_at = ?
            WHERE owner_id = ? AND external_id_hmac = ?
            """,
          arguments: [timestamp, owner, hmac]
        )
      }
      return try Self.fetchSources(database: database, ownerID: ownerID)
    }
  }

  func markSourcesUnavailable(ownerID: UUID, changedAt: Date) async throws {
    try await database.pool.write { database in
      try database.execute(
        sql: """
          UPDATE calendar_sources
          SET access_state = 'unavailable', updated_at = ?
          WHERE owner_id = ? AND access_state <> 'unavailable'
          """,
        arguments: [
          changedAt.timeIntervalSince1970,
          ownerID.uuidString.lowercased(),
        ]
      )
    }
  }

  func setSourceSelection(
    ownerID: UUID,
    sourceID: UUID,
    isSelected: Bool,
    changedAt: Date
  ) async throws -> CalendarSourceSummary {
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      let source = sourceID.uuidString.lowercased()
      guard
        let accessState: String = try String.fetchOne(
          database,
          sql: "SELECT access_state FROM calendar_sources WHERE owner_id = ? AND id = ?",
          arguments: [owner, source]
        )
      else {
        throw CalendarDomainError.selectedSourceUnavailable
      }
      guard accessState != CalendarSourceAccessState.unavailable.rawValue else {
        throw CalendarDomainError.selectedSourceUnavailable
      }
      try database.execute(
        sql: """
          UPDATE calendar_sources
          SET desired_selected = ?, access_state = ?, updated_at = ?
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [
          isSelected,
          isSelected
            ? CalendarSourceAccessState.selected.rawValue
            : CalendarSourceAccessState.unselected.rawValue,
          changedAt.timeIntervalSince1970,
          owner,
          source,
        ]
      )
      return try Self.fetchSource(database: database, ownerID: ownerID, sourceID: sourceID)
    }
  }

  func sources(ownerID: UUID) async throws -> [CalendarSourceSummary] {
    try await database.pool.read { database in
      try Self.fetchSources(database: database, ownerID: ownerID)
    }
  }

  func selectedSources(ownerID: UUID) async throws -> [SelectedCalendarSource] {
    try await database.pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT id, external_id_hmac
          FROM calendar_sources
          WHERE owner_id = ? AND desired_selected = 1 AND access_state = 'selected'
          ORDER BY id
          """,
        arguments: [ownerID.uuidString.lowercased()]
      )
      return try rows.map { row in
        guard let id = UUID(uuidString: row["id"] as String) else {
          throw CalendarDomainError.corruptedStoredCalendar
        }
        return SelectedCalendarSource(id: id, externalIdentityHMAC: row["external_id_hmac"])
      }
    }
  }

  func beginScan(
    ownerID: UUID,
    scanID: UUID,
    window: CalendarScanWindow,
    startedAt: Date
  ) async throws {
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      let timestamp = startedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          UPDATE calendar_scans
          SET status = 'failed', finished_at = ?, safe_error_code = 'interrupted'
          WHERE owner_id = ? AND status = 'running'
          """,
        arguments: [timestamp, owner]
      )
      try database.execute(
        sql: """
          INSERT INTO calendar_scans (
            id, owner_id, status, display_window_start, display_window_end,
            matching_window_start, matching_window_end, started_at
          ) VALUES (?, ?, 'running', ?, ?, ?, ?, ?)
          """,
        arguments: [
          scanID.uuidString.lowercased(),
          owner,
          window.displayStart.timeIntervalSince1970,
          window.displayEnd.timeIntervalSince1970,
          window.matchingStart.timeIntervalSince1970,
          window.matchingEnd.timeIntervalSince1970,
          timestamp,
        ]
      )
    }
  }

  func failScan(
    ownerID: UUID,
    scanID: UUID,
    safeErrorCode: String,
    failedAt: Date
  ) async throws {
    try await database.pool.write { database in
      try database.execute(
        sql: """
          UPDATE calendar_scans
          SET status = 'failed', finished_at = ?, safe_error_code = ?
          WHERE owner_id = ? AND id = ? AND status = 'running'
          """,
        arguments: [
          failedAt.timeIntervalSince1970,
          String(safeErrorCode.prefix(80)),
          ownerID.uuidString.lowercased(),
          scanID.uuidString.lowercased(),
        ]
      )
    }
  }

  func commitScan(_ commit: CalendarScanCommit) async throws -> CalendarScanResult {
    try await database.pool.write { database in
      let owner = commit.ownerID.uuidString.lowercased()
      let scan = commit.scanID.uuidString.lowercased()
      let timestamp = commit.completedAt.timeIntervalSince1970
      guard
        let scanStatus: String = try String.fetchOne(
          database,
          sql: "SELECT status FROM calendar_scans WHERE owner_id = ? AND id = ?",
          arguments: [owner, scan]
        ), scanStatus == "running"
      else {
        throw CalendarDomainError.corruptedStoredCalendar
      }

      let sourceRows = try Row.fetchAll(
        database,
        sql: """
          SELECT id, external_id_hmac
          FROM calendar_sources
          WHERE owner_id = ? AND desired_selected = 1 AND access_state = 'selected'
          """,
        arguments: [owner]
      )
      var sourceIDs: [Data: UUID] = [:]
      for row in sourceRows {
        guard let sourceID = UUID(uuidString: row["id"] as String) else {
          throw CalendarDomainError.corruptedStoredCalendar
        }
        sourceIDs[row["external_id_hmac"] as Data] = sourceID
      }

      var seenOccurrenceIDs = Set<UUID>()
      var activeCount = 0
      var outOfWindowCount = 0
      var cancelledCount = 0
      var changedCount = 0

      for snapshot in commit.occurrences {
        guard let sourceID = sourceIDs[snapshot.sourceExternalIdentityHMAC] else {
          throw CalendarDomainError.selectedSourceUnavailable
        }
        let seriesID = try Self.upsertSeries(
          database: database,
          ownerID: commit.ownerID,
          sourceID: sourceID,
          snapshot: snapshot,
          changedAt: commit.completedAt
        )
        let desiredState: CalendarOccurrenceSourceState
        if snapshot.isCancelled {
          desiredState = .cancelled
          cancelledCount += 1
        } else if commit.window.containsInDisplayWindow(
          startsAt: snapshot.startsAt,
          endsAt: snapshot.endsAt
        ) {
          desiredState = .active
          activeCount += 1
        } else {
          desiredState = .outOfWindow
          outOfWindowCount += 1
        }
        let upserted = try Self.upsertOccurrence(
          database: database,
          ownerID: commit.ownerID,
          sourceID: sourceID,
          seriesID: seriesID,
          scanID: commit.scanID,
          state: desiredState,
          snapshot: snapshot,
          changedAt: commit.completedAt
        )
        seenOccurrenceIDs.insert(upserted.id)
        if upserted.didChange { changedCount += 1 }
      }

      let selectedSourceIDStrings = sourceIDs.values.map { $0.uuidString.lowercased() }
      if !selectedSourceIDStrings.isEmpty {
        let placeholders = Array(repeating: "?", count: selectedSourceIDStrings.count)
          .joined(separator: ", ")
        var arguments: StatementArguments = [
          timestamp,
          owner,
          commit.window.displayEnd.timeIntervalSince1970,
          commit.window.displayStart.timeIntervalSince1970,
        ]
        arguments += StatementArguments(selectedSourceIDStrings)
        arguments += [scan]
        try database.execute(
          sql: """
            UPDATE calendar_occurrences
            SET source_state = 'missing',
                missing_scan_count = missing_scan_count + 1,
                updated_at = ?
            WHERE owner_id = ?
              AND starts_at < ?
              AND ends_at > ?
              AND calendar_source_id IN (\(placeholders))
              AND (last_seen_scan_id IS NULL OR last_seen_scan_id <> ?)
              AND source_state IN ('active', 'missing')
            """,
          arguments: arguments
        )

        var outsideArguments: StatementArguments = [
          timestamp,
          owner,
        ]
        outsideArguments += StatementArguments(selectedSourceIDStrings)
        outsideArguments += [
          commit.window.displayEnd.timeIntervalSince1970,
          commit.window.displayStart.timeIntervalSince1970,
        ]
        try database.execute(
          sql: """
            UPDATE calendar_occurrences
            SET source_state = 'out_of_window', updated_at = ?
            WHERE owner_id = ?
              AND calendar_source_id IN (\(placeholders))
              AND (starts_at >= ? OR ends_at <= ?)
              AND source_state IN ('active', 'missing')
            """,
          arguments: outsideArguments
        )
      }

      try database.execute(
        sql: """
          UPDATE calendar_sources
          SET last_successful_scan_at = ?,
              last_display_window_start = ?,
              last_display_window_end = ?,
              updated_at = ?
          WHERE owner_id = ? AND desired_selected = 1 AND access_state = 'selected'
          """,
        arguments: [
          timestamp,
          commit.window.displayStart.timeIntervalSince1970,
          commit.window.displayEnd.timeIntervalSince1970,
          timestamp,
          owner,
        ]
      )
      try database.execute(
        sql: """
          UPDATE calendar_scans
          SET status = 'completed', finished_at = ?
          WHERE owner_id = ? AND id = ? AND status = 'running'
          """,
        arguments: [timestamp, owner, scan]
      )
      return CalendarScanResult(
        scanID: commit.scanID,
        importedCount: seenOccurrenceIDs.count,
        activeCount: activeCount,
        outOfWindowCount: outOfWindowCount,
        cancelledCount: cancelledCount,
        changedCount: changedCount
      )
    }
  }

  func occurrences(
    ownerID: UUID,
    from startDate: Date,
    through endDate: Date
  ) async throws -> [CalendarOccurrenceSummary] {
    try await database.pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT
            occurrence.id,
            occurrence.calendar_source_id,
            source.title AS source_title,
            occurrence.source_version,
            occurrence.source_state,
            occurrence.is_all_day,
            occurrence.starts_at,
            occurrence.ends_at,
            occurrence.local_start_date,
            occurrence.local_end_date_exclusive,
            occurrence.timezone_id,
            occurrence.title,
            occurrence.location_text,
            EXISTS (
              SELECT 1
              FROM calendar_occurrence_revisions revision
              WHERE revision.owner_id = occurrence.owner_id
                AND revision.calendar_occurrence_id = occurrence.id
                AND revision.resolution_state = 'pending'
            ) AS has_pending_revision
            ,(
              SELECT COUNT(*)
              FROM event_trip_links link
              WHERE link.owner_id = occurrence.owner_id
                AND link.calendar_occurrence_id = occurrence.id
            ) AS linked_plan_count
          FROM calendar_occurrences occurrence
          JOIN calendar_sources source
            ON source.id = occurrence.calendar_source_id
           AND source.owner_id = occurrence.owner_id
          WHERE occurrence.owner_id = ?
            AND occurrence.starts_at < ?
            AND occurrence.ends_at > ?
            AND source.access_state = 'selected'
            AND occurrence.source_state <> 'out_of_window'
          ORDER BY occurrence.starts_at, occurrence.id
          """,
        arguments: [
          ownerID.uuidString.lowercased(),
          endDate.timeIntervalSince1970,
          startDate.timeIntervalSince1970,
        ]
      )
      return try rows.map(Self.decodeOccurrenceSummary)
    }
  }

  func pendingRevisions(
    ownerID: UUID,
    occurrenceID: UUID
  ) async throws -> [CalendarOccurrenceRevisionSummary] {
    try await database.pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT
            id, calendar_occurrence_id, from_version, to_version,
            old_starts_at, new_starts_at, old_ends_at, new_ends_at,
            old_timezone_id, new_timezone_id, old_title, new_title,
            old_location_text, new_location_text, detected_at,
            resolution_state, resolved_at
          FROM calendar_occurrence_revisions
          WHERE owner_id = ?
            AND calendar_occurrence_id = ?
            AND resolution_state = 'pending'
          ORDER BY to_version, id
          """,
        arguments: [
          ownerID.uuidString.lowercased(),
          occurrenceID.uuidString.lowercased(),
        ]
      )
      return try rows.map(Self.decodeRevisionSummary)
    }
  }

  func ignorePendingRevisions(
    ownerID: UUID,
    command: IgnoreCalendarRevisionsCommand
  ) async throws {
    guard command.throughSourceVersion >= 2 else {
      throw CalendarDomainError.staleOccurrenceVersion
    }
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      let occurrence = command.occurrenceID.uuidString.lowercased()
      guard
        let currentSourceVersion = try Int.fetchOne(
          database,
          sql: """
            SELECT source_version
            FROM calendar_occurrences
            WHERE owner_id = ? AND id = ?
            """,
          arguments: [owner, occurrence]
        )
      else {
        throw CalendarDomainError.revisionNotFound
      }
      guard currentSourceVersion >= command.throughSourceVersion else {
        throw CalendarDomainError.staleOccurrenceVersion
      }
      guard
        let latestDetectedAt = try Double.fetchOne(
          database,
          sql: """
            SELECT MAX(detected_at)
            FROM calendar_occurrence_revisions
            WHERE owner_id = ?
              AND calendar_occurrence_id = ?
              AND resolution_state = 'pending'
              AND to_version <= ?
            """,
          arguments: [owner, occurrence, command.throughSourceVersion]
        )
      else {
        throw CalendarDomainError.revisionNotFound
      }
      guard command.resolvedAt.timeIntervalSince1970 >= latestDetectedAt else {
        throw CalendarDomainError.invalidResolutionTime
      }
      try database.execute(
        sql: """
          UPDATE calendar_occurrence_revisions
          SET resolution_state = 'ignored', resolved_at = ?
          WHERE owner_id = ?
            AND calendar_occurrence_id = ?
            AND resolution_state = 'pending'
            AND to_version <= ?
          """,
        arguments: [
          command.resolvedAt.timeIntervalSince1970,
          owner,
          occurrence,
          command.throughSourceVersion,
        ]
      )
      guard database.changesCount > 0 else {
        throw CalendarDomainError.revisionNotFound
      }
    }
  }

  private static func fetchSources(
    database: Database,
    ownerID: UUID
  ) throws -> [CalendarSourceSummary] {
    let rows = try Row.fetchAll(
      database,
      sql: """
        SELECT id, title, source_kind, access_state, desired_selected,
               is_subscribed, allows_modifications, last_successful_scan_at
        FROM calendar_sources
        WHERE owner_id = ?
        ORDER BY access_state = 'unavailable', title COLLATE NOCASE, id
        """,
      arguments: [ownerID.uuidString.lowercased()]
    )
    return try rows.map(decodeSourceSummary)
  }

  private static func fetchSource(
    database: Database,
    ownerID: UUID,
    sourceID: UUID
  ) throws -> CalendarSourceSummary {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT id, title, source_kind, access_state, desired_selected,
                 is_subscribed, allows_modifications, last_successful_scan_at
          FROM calendar_sources
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [ownerID.uuidString.lowercased(), sourceID.uuidString.lowercased()]
      )
    else {
      throw CalendarDomainError.selectedSourceUnavailable
    }
    return try decodeSourceSummary(row)
  }

  private static func decodeSourceSummary(_ row: Row) throws -> CalendarSourceSummary {
    let idRaw: String = row["id"]
    let kindRaw: String = row["source_kind"]
    let stateRaw: String = row["access_state"]
    let scanTimestamp: Double? = row["last_successful_scan_at"]
    guard let id = UUID(uuidString: idRaw),
      let kind = CalendarSourceKind(rawValue: kindRaw),
      let state = CalendarSourceAccessState(rawValue: stateRaw)
    else {
      throw CalendarDomainError.corruptedStoredCalendar
    }
    return CalendarSourceSummary(
      id: id,
      title: row["title"],
      kind: kind,
      accessState: state,
      isSelected: row["desired_selected"],
      isSubscribed: row["is_subscribed"],
      allowsContentModifications: row["allows_modifications"],
      lastSuccessfulScanAt: scanTimestamp.map(Date.init(timeIntervalSince1970:))
    )
  }

  private static func upsertSeries(
    database: Database,
    ownerID: UUID,
    sourceID: UUID,
    snapshot: SystemCalendarOccurrenceSnapshot,
    changedAt: Date
  ) throws -> UUID {
    if let idRaw: String = try String.fetchOne(
      database,
      sql: """
        SELECT id FROM calendar_series
        WHERE owner_id = ? AND calendar_source_id = ? AND external_id_hmac = ?
        """,
      arguments: [
        ownerID.uuidString.lowercased(),
        sourceID.uuidString.lowercased(),
        snapshot.seriesExternalIdentityHMAC,
      ]
    ) {
      guard let id = UUID(uuidString: idRaw) else {
        throw CalendarDomainError.corruptedStoredCalendar
      }
      try database.execute(
        sql: "UPDATE calendar_series SET has_recurrence = ?, updated_at = ? WHERE id = ?",
        arguments: [snapshot.hasRecurrence, changedAt.timeIntervalSince1970, idRaw]
      )
      return id
    }

    let id = UUID()
    let timestamp = changedAt.timeIntervalSince1970
    try database.execute(
      sql: """
        INSERT INTO calendar_series (
          id, owner_id, calendar_source_id, external_id_hmac,
          has_recurrence, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id.uuidString.lowercased(),
        ownerID.uuidString.lowercased(),
        sourceID.uuidString.lowercased(),
        snapshot.seriesExternalIdentityHMAC,
        snapshot.hasRecurrence,
        timestamp,
        timestamp,
      ]
    )
    return id
  }

  private static func upsertOccurrence(
    database: Database,
    ownerID: UUID,
    sourceID: UUID,
    seriesID: UUID,
    scanID: UUID,
    state: CalendarOccurrenceSourceState,
    snapshot: SystemCalendarOccurrenceSnapshot,
    changedAt: Date
  ) throws -> (id: UUID, didChange: Bool) {
    var row = try Row.fetchOne(
      database,
      sql: "SELECT * FROM calendar_occurrences WHERE owner_id = ? AND external_id_hmac = ?",
      arguments: [ownerID.uuidString.lowercased(), snapshot.occurrenceExternalIdentityHMAC]
    )
    if row == nil {
      let matches = try Row.fetchAll(
        database,
        sql: "SELECT * FROM calendar_occurrences WHERE owner_id = ? AND match_key_hmac = ?",
        arguments: [ownerID.uuidString.lowercased(), snapshot.matchKeyHMAC]
      )
      if matches.count == 1 {
        row = matches[0]
      }
    }

    let timestamp = changedAt.timeIntervalSince1970
    if let row {
      guard let id = UUID(uuidString: row["id"] as String) else {
        throw CalendarDomainError.corruptedStoredCalendar
      }
      let oldFingerprint = row["source_fingerprint"] as Data
      let didChange = oldFingerprint != snapshot.sourceFingerprint
      let oldVersion = row["source_version"] as Int
      let nextVersion = didChange ? oldVersion + 1 : oldVersion
      if didChange {
        try database.execute(
          sql: """
            INSERT INTO calendar_occurrence_revisions (
              id, owner_id, calendar_occurrence_id, from_version, to_version,
              old_starts_at, new_starts_at, old_ends_at, new_ends_at,
              old_timezone_id, new_timezone_id, old_title, new_title,
              old_location_text, new_location_text, detected_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            UUID().uuidString.lowercased(),
            ownerID.uuidString.lowercased(),
            id.uuidString.lowercased(),
            oldVersion,
            nextVersion,
            row["starts_at"] as Double,
            snapshot.startsAt.timeIntervalSince1970,
            row["ends_at"] as Double,
            snapshot.endsAt.timeIntervalSince1970,
            row["timezone_id"] as String,
            snapshot.timeZoneIdentifier,
            row["title"] as String?,
            snapshot.title,
            row["location_text"] as String?,
            snapshot.locationText,
            timestamp,
          ]
        )
      }
      try database.execute(
        sql: """
          UPDATE calendar_occurrences
          SET calendar_source_id = ?,
              calendar_series_id = ?,
              external_id_hmac = ?,
              match_key_hmac = ?,
              source_fingerprint = ?,
              source_version = ?,
              source_state = ?,
              is_all_day = ?,
              starts_at = ?,
              ends_at = ?,
              local_start_date = ?,
              local_end_date_exclusive = ?,
              timezone_id = ?,
              title = ?,
              location_text = ?,
              last_seen_scan_id = ?,
              missing_scan_count = 0,
              updated_at = ?
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [
          sourceID.uuidString.lowercased(),
          seriesID.uuidString.lowercased(),
          snapshot.occurrenceExternalIdentityHMAC,
          snapshot.matchKeyHMAC,
          snapshot.sourceFingerprint,
          nextVersion,
          state.rawValue,
          snapshot.isAllDay,
          snapshot.startsAt.timeIntervalSince1970,
          snapshot.endsAt.timeIntervalSince1970,
          snapshot.localStartDate,
          snapshot.localEndDateExclusive,
          snapshot.timeZoneIdentifier,
          snapshot.title,
          snapshot.locationText,
          scanID.uuidString.lowercased(),
          timestamp,
          ownerID.uuidString.lowercased(),
          id.uuidString.lowercased(),
        ]
      )
      return (id, didChange)
    }

    let id = UUID()
    try database.execute(
      sql: """
        INSERT INTO calendar_occurrences (
          id, owner_id, calendar_source_id, calendar_series_id,
          external_id_hmac, match_key_hmac, source_fingerprint, source_version,
          source_state, is_all_day, starts_at, ends_at, local_start_date,
          local_end_date_exclusive, timezone_id, title, location_text,
          last_seen_scan_id, missing_scan_count, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        """,
      arguments: [
        id.uuidString.lowercased(),
        ownerID.uuidString.lowercased(),
        sourceID.uuidString.lowercased(),
        seriesID.uuidString.lowercased(),
        snapshot.occurrenceExternalIdentityHMAC,
        snapshot.matchKeyHMAC,
        snapshot.sourceFingerprint,
        state.rawValue,
        snapshot.isAllDay,
        snapshot.startsAt.timeIntervalSince1970,
        snapshot.endsAt.timeIntervalSince1970,
        snapshot.localStartDate,
        snapshot.localEndDateExclusive,
        snapshot.timeZoneIdentifier,
        snapshot.title,
        snapshot.locationText,
        scanID.uuidString.lowercased(),
        timestamp,
        timestamp,
      ]
    )
    return (id, false)
  }

  private static func decodeOccurrenceSummary(_ row: Row) throws -> CalendarOccurrenceSummary {
    let idRaw: String = row["id"]
    let sourceIDRaw: String = row["calendar_source_id"]
    let stateRaw: String = row["source_state"]
    guard let id = UUID(uuidString: idRaw),
      let sourceID = UUID(uuidString: sourceIDRaw),
      let state = CalendarOccurrenceSourceState(rawValue: stateRaw)
    else {
      throw CalendarDomainError.corruptedStoredCalendar
    }
    return CalendarOccurrenceSummary(
      id: id,
      sourceID: sourceID,
      sourceTitle: row["source_title"],
      sourceVersion: row["source_version"],
      sourceState: state,
      isAllDay: row["is_all_day"],
      startsAt: Date(timeIntervalSince1970: row["starts_at"]),
      endsAt: Date(timeIntervalSince1970: row["ends_at"]),
      localStartDate: row["local_start_date"],
      localEndDateExclusive: row["local_end_date_exclusive"],
      timeZoneIdentifier: row["timezone_id"],
      title: row["title"],
      locationText: row["location_text"],
      hasPendingRevision: row["has_pending_revision"],
      linkedPlanCount: row["linked_plan_count"]
    )
  }

  private static func decodeRevisionSummary(_ row: Row) throws
    -> CalendarOccurrenceRevisionSummary
  {
    let idRaw: String = row["id"]
    let occurrenceIDRaw: String = row["calendar_occurrence_id"]
    let resolutionRaw: String = row["resolution_state"]
    guard let id = UUID(uuidString: idRaw),
      let occurrenceID = UUID(uuidString: occurrenceIDRaw),
      let resolution = CalendarRevisionResolutionState(rawValue: resolutionRaw)
    else {
      throw CalendarDomainError.corruptedStoredCalendar
    }
    return CalendarOccurrenceRevisionSummary(
      id: id,
      occurrenceID: occurrenceID,
      fromVersion: row["from_version"],
      toVersion: row["to_version"],
      oldStartsAt: Date(timeIntervalSince1970: row["old_starts_at"]),
      newStartsAt: Date(timeIntervalSince1970: row["new_starts_at"]),
      oldEndsAt: Date(timeIntervalSince1970: row["old_ends_at"]),
      newEndsAt: Date(timeIntervalSince1970: row["new_ends_at"]),
      oldTimeZoneIdentifier: row["old_timezone_id"],
      newTimeZoneIdentifier: row["new_timezone_id"],
      oldTitle: row["old_title"],
      newTitle: row["new_title"],
      oldLocationText: row["old_location_text"],
      newLocationText: row["new_location_text"],
      detectedAt: Date(timeIntervalSince1970: row["detected_at"]),
      resolutionState: resolution,
      resolvedAt: (row["resolved_at"] as Double?).map(Date.init(timeIntervalSince1970:))
    )
  }

  private static func normalizedTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return String((trimmed.isEmpty ? "未命名日历" : trimmed).prefix(200))
  }
}
