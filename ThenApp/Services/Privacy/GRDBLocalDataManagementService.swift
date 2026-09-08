import Foundation
import GRDB

nonisolated enum LocalDataManagementFailurePoint: Sendable, Equatable {
  case none
  case exportCleanup
  case exportWrite
  case afterLedgerDeletion
}

actor GRDBLocalDataManagementService: LocalDataManaging {
  private let database: AppDatabase
  private let ownerID: UUID
  private let journeyRecording: JourneyRecordingService?
  private let reminders: (any ReminderService)?
  private let exportRootDirectory: URL
  private let fileManager: any ProtectedFileManaging
  private let now: @Sendable () -> Date
  private let failurePoint: LocalDataManagementFailurePoint
  private var hasExportCleanupFailure: Bool

  init(
    database: AppDatabase,
    ownerID: UUID,
    journeyRecording: JourneyRecordingService? = nil,
    reminders: (any ReminderService)? = nil,
    exportRootDirectory: URL? = nil,
    fileManager: any ProtectedFileManaging = SystemProtectedFileManager(),
    now: @escaping @Sendable () -> Date = Date.init,
    failurePoint: LocalDataManagementFailurePoint = .none
  ) {
    let resolvedExportRoot =
      exportRootDirectory
      ?? fileManager.temporaryDirectory.appending(
        path: "ThenAppExports",
        directoryHint: .isDirectory
      )
    self.database = database
    self.ownerID = ownerID
    self.journeyRecording = journeyRecording
    self.reminders = reminders
    self.fileManager = fileManager
    self.now = now
    self.failurePoint = failurePoint
    self.exportRootDirectory = resolvedExportRoot
    self.hasExportCleanupFailure =
      failurePoint == .exportCleanup
      || !Self.removeAbandonedExports(
        below: resolvedExportRoot,
        fileManager: fileManager
      )
  }

  func createExport() async throws -> LocalDataExportArtifact {
    guard failurePoint != .exportCleanup else {
      throw LocalDataManagementError.exportCleanupFailed
    }
    hasExportCleanupFailure = !Self.removeAbandonedExports(
      below: exportRootDirectory,
      fileManager: fileManager
    )
    guard !hasExportCleanupFailure else {
      throw LocalDataManagementError.exportCleanupFailed
    }

    let document = try await database.pool.read { database in
      try Self.fetchExportDocument(
        database: database,
        ownerID: ownerID,
        exportedAt: now()
      )
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    let exportID = UUID()
    let directoryURL = exportRootDirectory.appending(
      path: exportID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    let fileURL = directoryURL.appending(path: "于是数据导出.json")
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete]
      )
      if failurePoint == .exportWrite {
        throw LocalDataManagementError.exportWriteFailed
      }
      let data = try encoder.encode(document)
      try fileManager.write(data, to: fileURL, options: .atomic)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: fileURL.path
      )
      return LocalDataExportArtifact(id: exportID, fileURL: fileURL)
    } catch {
      try? fileManager.removeItem(at: directoryURL)
      if Self.isInsufficientStorage(error as NSError) {
        throw LocalDataManagementError.insufficientStorage
      }
      throw LocalDataManagementError.exportWriteFailed
    }
  }

  func cleanupExport(_ artifact: LocalDataExportArtifact) async throws {
    let directoryURL = artifact.fileURL.deletingLastPathComponent().standardizedFileURL
    guard directoryURL.deletingLastPathComponent() == exportRootDirectory.standardizedFileURL else {
      throw LocalDataManagementError.exportCleanupFailed
    }
    do {
      if fileManager.fileExists(atPath: directoryURL.path) {
        try fileManager.removeItem(at: directoryURL)
      }
    } catch {
      throw LocalDataManagementError.exportCleanupFailed
    }
  }

  func clearCalendarCache() async throws {
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      for table in [
        "event_trip_links",
        "calendar_occurrence_revisions",
        "calendar_occurrences",
        "calendar_series",
        "calendar_scans",
        "calendar_sources",
      ] {
        try database.execute(
          sql: "DELETE FROM \(table) WHERE owner_id = ?",
          arguments: [owner]
        )
      }
    }
  }

  func resetAllLocalData() async throws {
    let suspendedJourney = await journeyRecording?.suspendForLocalDataReset()
    let reminderRequestIDs = try await database.pool.read { database in
      try String.fetchAll(
        database,
        sql: "SELECT notification_request_id FROM departure_reminders WHERE owner_id = ?",
        arguments: [ownerID.uuidString.lowercased()]
      )
    }

    do {
      try await database.pool.write { database in
        try database.execute(sql: "PRAGMA defer_foreign_keys = ON")
        let owner = ownerID.uuidString.lowercased()
        for table in [
          "transaction_journey_links",
          "track_points",
          "track_segments",
          "journeys",
          "event_trip_links",
          "navigation_handoffs",
          "departure_reminders",
        ] {
          try database.execute(
            sql: "DELETE FROM \(table) WHERE owner_id = ?",
            arguments: [owner]
          )
        }
        try database.execute(
          sql: "UPDATE trip_plans SET selected_route_estimate_id = NULL WHERE owner_id = ?",
          arguments: [owner]
        )
        for table in [
          "route_estimates",
          "trip_plans",
          "location_snapshots",
          "calendar_occurrence_revisions",
          "calendar_occurrences",
          "calendar_series",
          "calendar_scans",
          "calendar_sources",
          "postings",
          "ledger_transactions",
        ] {
          try database.execute(
            sql: "DELETE FROM \(table) WHERE owner_id = ?",
            arguments: [owner]
          )
        }
        if failurePoint == .afterLedgerDeletion {
          throw LocalDataManagementError.localDataResetFailed
        }
        try database.execute(
          sql: "DELETE FROM ledger_accounts WHERE owner_id = ?",
          arguments: [owner]
        )
        try database.execute(
          sql: "DELETE FROM local_profiles WHERE id = ?",
          arguments: [owner]
        )
      }
    } catch {
      if let suspendedJourney {
        try? await journeyRecording?.restoreAfterFailedLocalDataReset(suspendedJourney)
      }
      throw error
    }

    for requestID in reminderRequestIDs {
      await reminders?.cancel(requestIdentifier: requestID)
    }
  }

  private nonisolated static func fetchExportDocument(
    database: Database,
    ownerID: UUID,
    exportedAt: Date
  ) throws -> LocalDataExportDocument {
    let owner = ownerID.uuidString.lowercased()
    guard
      let profileRow = try Row.fetchOne(
        database,
        sql: "SELECT base_currency_code, base_currency_state FROM local_profiles WHERE id = ?",
        arguments: [owner]
      )
    else {
      throw LocalDataManagementError.profileNotFound
    }

    let accountRows = try Row.fetchAll(
      database,
      sql: """
        SELECT id, parent_id, kind, subtype, name, native_currency_code,
               configuration_state, status, system_key, display_order, created_at, updated_at
        FROM ledger_accounts
        WHERE owner_id = ?
        ORDER BY display_order, id
        """,
      arguments: [owner]
    )
    let transactionRows = try Row.fetchAll(
      database,
      sql: """
        SELECT id, canonical_root_id, kind, status, source_type, occurred_at,
               original_timezone_id, payee, note, refund_of_id, reversal_of_id,
               replacement_for_id, created_at
        FROM ledger_transactions
        WHERE owner_id = ? AND status = 'posted'
        ORDER BY occurred_at, created_at, id
        """,
      arguments: [owner]
    )
    let postingRows = try Row.fetchAll(
      database,
      sql: """
        SELECT p.transaction_id, p.ledger_account_id, p.side, p.amount_minor,
               p.currency_code, p.memo
        FROM postings p
        JOIN ledger_transactions t
          ON t.id = p.transaction_id AND t.owner_id = p.owner_id
        WHERE p.owner_id = ? AND t.status = 'posted'
        ORDER BY t.occurred_at, p.transaction_id, p.sequence
        """,
      arguments: [owner]
    )
    let planRows = try Row.fetchAll(
      database,
      sql: """
        SELECT p.id, p.display_name, origin.name AS origin_name,
               origin.address AS origin_address, destination.name AS destination_name,
               destination.address AS destination_address, p.transport_mode,
               p.target_arrival_at, p.planned_departure_at, p.timezone_id,
               p.preparation_buffer_seconds, p.status, p.created_at, p.updated_at
        FROM trip_plans p
        LEFT JOIN location_snapshots origin
          ON origin.id = p.origin_snapshot_id AND origin.owner_id = p.owner_id
        JOIN location_snapshots destination
          ON destination.id = p.destination_snapshot_id AND destination.owner_id = p.owner_id
        WHERE p.owner_id = ? AND p.status <> 'draft'
        ORDER BY p.target_arrival_at, p.id
        """,
      arguments: [owner]
    )
    let journeyRows = try Row.fetchAll(
      database,
      sql: """
        SELECT id, trip_plan_id, status, transport_mode, started_at, ended_at,
               distance_meters, duration_seconds, capture_completeness, termination_reason
        FROM journeys
        WHERE owner_id = ? AND status IN ('completed', 'discarded')
        ORDER BY started_at, id
        """,
      arguments: [owner]
    )
    let linkRows = try Row.fetchAll(
      database,
      sql: """
        SELECT transaction_root_id, journey_id, role, confirmed_at
        FROM transaction_journey_links
        WHERE owner_id = ?
        ORDER BY confirmed_at, id
        """,
      arguments: [owner]
    )

    return LocalDataExportDocument(
      schemaVersion: 1,
      exportedAt: exportedAt,
      appName: "于是",
      profile: .init(
        baseCurrencyCode: profileRow["base_currency_code"],
        baseCurrencyState: profileRow["base_currency_state"]
      ),
      accounts: accountRows.map { row in
        .init(
          id: row["id"],
          parentID: row["parent_id"],
          kind: row["kind"],
          subtype: row["subtype"],
          name: row["name"],
          nativeCurrencyCode: row["native_currency_code"],
          configurationState: row["configuration_state"],
          status: row["status"],
          systemKey: row["system_key"],
          displayOrder: row["display_order"],
          createdAt: date(row["created_at"] as Double),
          updatedAt: date(row["updated_at"] as Double)
        )
      },
      transactions: transactionRows.map { row in
        .init(
          id: row["id"],
          canonicalRootID: row["canonical_root_id"],
          kind: row["kind"],
          status: row["status"],
          source: row["source_type"],
          occurredAt: date(row["occurred_at"] as Double),
          timezoneIdentifier: row["original_timezone_id"],
          payee: row["payee"],
          note: row["note"],
          refundOfID: row["refund_of_id"],
          reversalOfID: row["reversal_of_id"],
          replacementForID: row["replacement_for_id"],
          createdAt: date(row["created_at"] as Double)
        )
      },
      postings: postingRows.map { row in
        .init(
          transactionID: row["transaction_id"],
          ledgerAccountID: row["ledger_account_id"],
          direction: row["side"],
          amountMinor: row["amount_minor"],
          currencyCode: row["currency_code"],
          memo: row["memo"]
        )
      },
      tripPlans: planRows.map { row in
        let departure: Double? = row["planned_departure_at"]
        return .init(
          id: row["id"],
          displayName: row["display_name"],
          originName: row["origin_name"],
          originAddress: row["origin_address"],
          destinationName: row["destination_name"],
          destinationAddress: row["destination_address"],
          transportMode: row["transport_mode"],
          targetArrivalAt: date(row["target_arrival_at"] as Double),
          plannedDepartureAt: departure.map(date),
          timezoneIdentifier: row["timezone_id"],
          preparationBufferSeconds: row["preparation_buffer_seconds"],
          status: row["status"],
          createdAt: date(row["created_at"] as Double),
          updatedAt: date(row["updated_at"] as Double)
        )
      },
      journeys: journeyRows.map { row in
        let endedAt: Double? = row["ended_at"]
        return .init(
          id: row["id"],
          tripPlanID: row["trip_plan_id"],
          status: row["status"],
          transportMode: row["transport_mode"],
          startedAt: date(row["started_at"] as Double),
          endedAt: endedAt.map(date),
          distanceMeters: row["distance_meters"],
          durationSeconds: row["duration_seconds"],
          captureCompleteness: row["capture_completeness"],
          terminationReason: row["termination_reason"]
        )
      },
      transactionJourneyLinks: linkRows.map { row in
        .init(
          transactionRootID: row["transaction_root_id"],
          journeyID: row["journey_id"],
          role: row["role"],
          confirmedAt: date(row["confirmed_at"] as Double)
        )
      }
    )
  }

  private nonisolated static func date(_ timestamp: Double) -> Date {
    Date(timeIntervalSince1970: timestamp)
  }

  private nonisolated static func removeAbandonedExports(
    below exportRootDirectory: URL,
    fileManager: any ProtectedFileManaging
  ) -> Bool {
    let root = exportRootDirectory.standardizedFileURL
    guard fileManager.fileExists(atPath: root.path) else { return true }
    do {
      for item in try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        guard item.deletingLastPathComponent().standardizedFileURL == root else {
          return false
        }
        try fileManager.removeItem(at: item)
      }
      return true
    } catch {
      return false
    }
  }

  private nonisolated static func isInsufficientStorage(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain,
      error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue
    {
      return true
    }
    if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlyingError !== error
    {
      return isInsufficientStorage(underlyingError)
    }
    return false
  }
}
