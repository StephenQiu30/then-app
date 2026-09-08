import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("结构化导出与本地分层删除")
struct LocalDataManagementTests {
  @Test("导出只包含批准的可读结构且分享后可清理临时文件")
  func exportUsesAllowlistAndCleansTemporaryFile() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let exportRoot = FileManager.default.temporaryDirectory.appending(
        path: "ThenExportTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let recordingFileManager = RecordingFileManager()
      defer { try? FileManager.default.removeItem(at: exportRoot) }
      let service = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        exportRootDirectory: exportRoot,
        fileManager: recordingFileManager,
        now: { localDataDate(900) }
      )

      let artifact = try await service.createExport()
      #expect(FileManager.default.fileExists(atPath: artifact.fileURL.path))
      let exportDirectory = artifact.fileURL.deletingLastPathComponent()
      let expectedProtection = FileProtectionType.complete.rawValue
      #expect(
        recordingFileManager.directoryCreations.contains(
          .init(
            path: exportDirectory.standardizedFileURL.path,
            protection: expectedProtection
          )
        ))
      #expect(
        recordingFileManager.attributeUpdates.contains(
          .init(
            path: artifact.fileURL.standardizedFileURL.path,
            protection: expectedProtection
          )
        ))
      let data = try Data(contentsOf: artifact.fileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      decoder.keyDecodingStrategy = .custom { path in
        let source = path.last?.stringValue ?? ""
        let parts = source.split(separator: "_")
        var converted = parts.first.map(String.init) ?? source
        for part in parts.dropFirst() {
          converted += part.prefix(1).uppercased() + part.dropFirst()
        }
        if converted != "id", converted.hasSuffix("Id") {
          converted = String(converted.dropLast(2)) + "ID"
        }
        return LocalDataCodingKey(stringValue: converted)
      }
      let document = try decoder.decode(LocalDataExportDocument.self, from: data)
      #expect(document.schemaVersion == 1)
      #expect(document.exportedAt == localDataDate(900))
      #expect(document.accounts.count == 11)
      #expect(document.transactions.count == 1)
      #expect(document.postings.count == 2)
      #expect(document.tripPlans.map(\.id) == [fixture.planID.localDataString])
      #expect(document.journeys.map(\.id) == [fixture.journeyID.localDataString])
      #expect(document.transactionJourneyLinks.count == 1)
      #expect(document.postings.allSatisfy { $0.amountMinor == 2_500 })

      let text = try #require(String(data: data, encoding: .utf8))
      for forbidden in [
        "owner_id",
        "external_id_hmac",
        "SECRET_CALENDAR_TITLE",
        "notification_request_id",
        "recording_device_id",
        "manifest_hash",
        "track_points",
        "latitude",
        "longitude",
      ] {
        #expect(!text.contains(forbidden))
      }

      try await service.cleanupExport(artifact)
      #expect(!FileManager.default.fileExists(atPath: exportDirectory.path))
    }
  }

  @Test("启动和再次导出会清扫旧目录且不会越界删除")
  func abandonedExportsAreCleanedWithinOwnedRoot() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let testRoot = FileManager.default.temporaryDirectory.appending(
        path: "ThenAbandonedExportTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      let exportRoot = testRoot.appending(path: "exports", directoryHint: .isDirectory)
      let outsideFile = testRoot.appending(path: "必须保留.txt")
      let startupLeftover = exportRoot.appending(path: "startup-leftover")
      defer { try? FileManager.default.removeItem(at: testRoot) }
      try FileManager.default.createDirectory(
        at: startupLeftover,
        withIntermediateDirectories: true
      )
      try Data("outside".utf8).write(to: outsideFile)

      let service = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        exportRootDirectory: exportRoot
      )
      #expect(!FileManager.default.fileExists(atPath: startupLeftover.path))
      #expect(FileManager.default.fileExists(atPath: outsideFile.path))

      let retryLeftover = exportRoot.appending(path: "retry-leftover")
      try FileManager.default.createDirectory(
        at: retryLeftover,
        withIntermediateDirectories: true
      )
      let artifact = try await service.createExport()
      #expect(!FileManager.default.fileExists(atPath: retryLeftover.path))
      #expect(FileManager.default.fileExists(atPath: outsideFile.path))
      try await service.cleanupExport(artifact)
    }
  }

  @Test("清扫或写盘失败不产生新导出且不改变源数据")
  func exportFailuresLeaveNoPartialArtifactOrDatabaseChange() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let before = try localDataCounts(database)
      let testRoot = FileManager.default.temporaryDirectory.appending(
        path: "ThenFailedExportTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: testRoot) }

      let cleanupFailure = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        exportRootDirectory: testRoot.appending(path: "cleanup"),
        failurePoint: .exportCleanup
      )
      await #expect(throws: LocalDataManagementError.exportCleanupFailed) {
        try await cleanupFailure.createExport()
      }

      let writeRoot = testRoot.appending(path: "write")
      let writeFailure = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        exportRootDirectory: writeRoot,
        failurePoint: .exportWrite
      )
      await #expect(throws: LocalDataManagementError.exportWriteFailed) {
        try await writeFailure.createExport()
      }

      let remainingItems =
        (try? FileManager.default.contentsOfDirectory(atPath: writeRoot.path)) ?? []
      #expect(remainingItems.isEmpty)
      #expect(try localDataCounts(database) == before)
    }
  }

  @Test("存储空间不足会清理部分文件且不阻止随后重试")
  func insufficientStorageCleansPartialFileAndAllowsRetry() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let before = try localDataCounts(database)
      let exportRoot = FileManager.default.temporaryDirectory.appending(
        path: "ThenOutOfSpaceExportTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: exportRoot) }

      let failingService = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        exportRootDirectory: exportRoot,
        fileManager: RecordingFileManager(writeBehavior: .outOfSpaceAfterPartialFile)
      )
      await #expect(throws: LocalDataManagementError.insufficientStorage) {
        try await failingService.createExport()
      }

      let remainingItems =
        (try? FileManager.default.contentsOfDirectory(atPath: exportRoot.path)) ?? []
      #expect(remainingItems.isEmpty)
      #expect(try localDataCounts(database) == before)

      let retryService = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        exportRootDirectory: exportRoot
      )
      let artifact = try await retryService.createExport()
      #expect(FileManager.default.fileExists(atPath: artifact.fileURL.path))
      #expect(try localDataCounts(database) == before)
      try await retryService.cleanupExport(artifact)
    }
  }

  @Test("清理日历缓存保留计划提醒行程和账务")
  func calendarCleanupPreservesUserOwnedFacts() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let before = try localDataCounts(database)
      let service = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID
      )

      try await service.clearCalendarCache()

      let after = try localDataCounts(database)
      #expect(after.calendarSources == 0)
      #expect(after.calendarScans == 0)
      #expect(after.calendarSeries == 0)
      #expect(after.calendarOccurrences == 0)
      #expect(after.calendarRevisions == 0)
      #expect(after.eventLinks == 0)
      #expect(after.plans == before.plans)
      #expect(after.reminders == before.reminders)
      #expect(after.journeys == before.journeys)
      #expect(after.transactions == before.transactions)
      #expect(after.postings == before.postings)
      #expect(after.lifeLinks == before.lifeLinks)
    }
  }

  @Test("删除已完成行程级联关系但保留计划交易和分录")
  func completedJourneyDeletionPreservesLedgerAndPlan() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let repository = GRDBJourneyRepository(database: database)
      let before = try localDataCounts(database)

      try await repository.deleteJourney(
        ownerID: fixture.identity.profileID,
        journeyID: fixture.journeyID
      )

      let after = try localDataCounts(database)
      #expect(after.journeys == 0)
      #expect(after.lifeLinks == 0)
      #expect(after.plans == before.plans)
      #expect(after.transactions == before.transactions)
      #expect(after.postings == before.postings)
    }
  }

  @Test("全量删除故障会回滚所有用户表")
  func resetFailureRollsBackAllDatabaseChanges() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let before = try localDataCounts(database)
      let service = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        failurePoint: .afterLedgerDeletion
      )

      await #expect(throws: LocalDataManagementError.localDataResetFailed) {
        try await service.resetAllLocalData()
      }

      #expect(try localDataCounts(database) == before)
    }
  }

  @Test("全量删除停止定位并取消提醒且失败时恢复定位")
  func resetCoordinatesJourneyDriverAndReminders() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let driver = LocalDataJourneyDriver()
      let recording = JourneyRecordingService(
        ownerID: fixture.identity.profileID,
        recordingDeviceID: UUID(),
        repository: GRDBJourneyRepository(database: database),
        locationDriver: driver,
        now: { localDataDate(700) }
      )
      _ = try await recording.start(
        tripPlanID: fixture.planID,
        transportMode: .transit
      )
      let reminder = LocalDataReminderService()
      let failingService = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        journeyRecording: recording,
        reminders: reminder,
        failurePoint: .afterLedgerDeletion
      )

      await #expect(throws: LocalDataManagementError.localDataResetFailed) {
        try await failingService.resetAllLocalData()
      }
      #expect(await driver.startCount() == 2)
      #expect(await driver.stopCount() == 1)
      #expect(await reminder.cancelledRequestIDs().isEmpty)

      let successfulService = GRDBLocalDataManagementService(
        database: database,
        ownerID: fixture.identity.profileID,
        journeyRecording: recording,
        reminders: reminder
      )
      try await successfulService.resetAllLocalData()
      #expect(await driver.stopCount() == 2)
      #expect(await reminder.cancelledRequestIDs() == ["test-reminder"])
      #expect(try localDataCounts(database).profiles == 0)
    }
  }

  @Test("全量删除后旧资料消失且新资料回到本币待确认")
  func resetCreatesFreshLocalIdentity() async throws {
    try await withAsyncTestDatabase { database in
      let fixture = try await makeLocalDataFixture(database)
      let oldProfileID = fixture.identity.profileID
      let service = GRDBLocalDataManagementService(
        database: database,
        ownerID: oldProfileID
      )

      try await service.resetAllLocalData()
      let cleared = try localDataCounts(database)
      #expect(cleared.profiles == 0)
      #expect(cleared.accounts == 0)
      #expect(cleared.transactions == 0)
      #expect(cleared.plans == 0)
      #expect(cleared.journeys == 0)

      let fresh = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: localDataDate(1_000)
      )
      #expect(fresh.profileID != oldProfileID)
      #expect(fresh.baseCurrencyState == .suggested)
      let rebuilt = try localDataCounts(database)
      #expect(rebuilt.profiles == 1)
      #expect(rebuilt.accounts == 11)
      #expect(rebuilt.transactions == 0)
    }
  }
}

private nonisolated struct LocalDataFixture {
  let identity: LocalLedgerIdentity
  let planID: UUID
  let journeyID: UUID
}

private actor LocalDataJourneyDriver: JourneyLocationDriver {
  private var starts = 0
  private var stops = 0

  func start(
    transportMode: TripTransportMode,
    handler: @escaping @Sendable (JourneyLocationEvent) async -> Void
  ) async throws {
    starts += 1
  }

  func stop() async {
    stops += 1
  }

  func startCount() -> Int { starts }
  func stopCount() -> Int { stops }
}

private actor LocalDataReminderService: ReminderService {
  private var cancelled: [String] = []

  func authorizationState() async -> ReminderAuthorizationState { .authorized }

  func requestAuthorization() async throws -> ReminderAuthorizationState { .authorized }

  func schedule(_ request: ReminderScheduleRequest) async throws {}

  func cancel(requestIdentifier: String) async {
    cancelled.append(requestIdentifier)
  }

  func cancelledRequestIDs() -> [String] { cancelled }
}

private nonisolated func makeLocalDataFixture(_ database: AppDatabase) async throws
  -> LocalDataFixture
{
  let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
    suggestedCurrencyCode: .cny,
    now: localDataDate(10)
  )
  let ledger = GRDBLedgerRepository(database: database)
  _ = try await ledger.confirmBaseCurrency(
    BaseCurrencyConfirmation(
      ownerID: identity.profileID,
      currencyCode: .cny,
      confirmedAt: localDataDate(20)
    )
  )
  let categoryIDRaw = try await database.pool.read { database in
    try String.fetchOne(
      database,
      sql: "SELECT id FROM ledger_accounts WHERE owner_id = ? AND system_key = 'expense.transport'",
      arguments: [identity.profileID.localDataString]
    )
  }
  let categoryID = try #require(categoryIDRaw.flatMap(UUID.init(uuidString:)))
  let rootID = UUID()
  _ = try await ledger.createTransaction(
    CreateLedgerTransactionRequest(
      transactionID: rootID,
      ownerID: identity.profileID,
      details: .expense(
        paymentAccountID: identity.defaultCashAccountID,
        categoryAccountID: categoryID
      ),
      money: PositiveMoney(minorUnits: 2_500, currencyCode: .cny),
      occurredAt: localDataDate(100),
      originalTimeZoneIdentifier: "Asia/Shanghai",
      payee: "合成出行消费",
      submittedAt: localDataDate(101)
    )
  )

  let planID = UUID()
  let destinationID = UUID()
  let journeyID = UUID()
  let sourceID = UUID()
  let scanID = UUID()
  let seriesID = UUID()
  let occurrenceID = UUID()
  try await database.pool.write { database in
    let owner = identity.profileID.localDataString
    try database.execute(
      sql: """
        INSERT INTO location_snapshots (
          id, owner_id, name, address, source, created_at
        ) VALUES (?, ?, '人民广场', '上海市黄浦区', 'manual', ?)
        """,
      arguments: [destinationID.localDataString, owner, localDataDate(110).timeIntervalSince1970]
    )
    try database.execute(
      sql: """
        INSERT INTO trip_plans (
          id, owner_id, display_name, destination_snapshot_id, transport_mode,
          target_arrival_at, planned_departure_at, timezone_id,
          preparation_buffer_seconds, destination_value_source,
          target_arrival_value_source, transport_value_source, departure_value_source,
          status, created_at, updated_at
        ) VALUES (?, ?, '周末出行', ?, 'transit', ?, ?, 'Asia/Shanghai', 600,
                  'user', 'user', 'user', 'user', 'planned', ?, ?)
        """,
      arguments: [
        planID.localDataString,
        owner,
        destinationID.localDataString,
        localDataDate(500).timeIntervalSince1970,
        localDataDate(400).timeIntervalSince1970,
        localDataDate(120).timeIntervalSince1970,
        localDataDate(120).timeIntervalSince1970,
      ]
    )
    try database.execute(
      sql: """
        INSERT INTO departure_reminders (
          id, owner_id, trip_plan_id, notification_request_id, is_enabled,
          fire_at, schedule_version, status, created_at, updated_at
        ) VALUES (?, ?, ?, 'test-reminder', 1, ?, 1, 'scheduled', ?, ?)
        """,
      arguments: [
        UUID().localDataString,
        owner,
        planID.localDataString,
        localDataDate(390).timeIntervalSince1970,
        localDataDate(130).timeIntervalSince1970,
        localDataDate(130).timeIntervalSince1970,
      ]
    )
    try database.execute(
      sql: """
        INSERT INTO journeys (
          id, owner_id, trip_plan_id, recording_device_id, status, transport_mode,
          started_at, ended_at, distance_meters, duration_seconds,
          capture_completeness, raw_track_state, final_sequence, point_count,
          manifest_hash, termination_reason, tracking_consent_version, created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'completed', 'transit', ?, ?, 3200, 1200,
                  'complete', 'purged', 0, 0, ?, 'user_ended', 1, ?, ?)
        """,
      arguments: [
        journeyID.localDataString,
        owner,
        planID.localDataString,
        UUID().localDataString,
        localDataDate(200).timeIntervalSince1970,
        localDataDate(300).timeIntervalSince1970,
        Data(repeating: 0x44, count: 32),
        localDataDate(200).timeIntervalSince1970,
        localDataDate(301).timeIntervalSince1970,
      ]
    )
    try database.execute(
      sql: """
        INSERT INTO transaction_journey_links (
          id, owner_id, transaction_root_id, journey_id, role,
          created_by, confirmed_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'transport', 'user', ?, ?, ?)
        """,
      arguments: [
        UUID().localDataString,
        owner,
        rootID.localDataString,
        journeyID.localDataString,
        localDataDate(310).timeIntervalSince1970,
        localDataDate(310).timeIntervalSince1970,
        localDataDate(310).timeIntervalSince1970,
      ]
    )
    try insertCalendarFixture(
      database,
      owner: owner,
      sourceID: sourceID,
      scanID: scanID,
      seriesID: seriesID,
      occurrenceID: occurrenceID,
      planID: planID
    )
  }
  return LocalDataFixture(identity: identity, planID: planID, journeyID: journeyID)
}

private nonisolated func insertCalendarFixture(
  _ database: Database,
  owner: String,
  sourceID: UUID,
  scanID: UUID,
  seriesID: UUID,
  occurrenceID: UUID,
  planID: UUID
) throws {
  try database.execute(
    sql: """
      INSERT INTO calendar_sources (
        id, owner_id, external_id_hmac, title, source_kind, access_state,
        desired_selected, is_subscribed, allows_modifications, created_at, updated_at
      ) VALUES (?, ?, ?, 'SECRET_CALENDAR_TITLE', 'local', 'selected', 1, 0, 1, ?, ?)
      """,
    arguments: [
      sourceID.localDataString,
      owner,
      Data([0x01]),
      localDataDate(140).timeIntervalSince1970,
      localDataDate(140).timeIntervalSince1970,
    ]
  )
  try database.execute(
    sql: """
      INSERT INTO calendar_scans (
        id, owner_id, status, display_window_start, display_window_end,
        matching_window_start, matching_window_end, started_at, finished_at
      ) VALUES (?, ?, 'completed', ?, ?, ?, ?, ?, ?)
      """,
    arguments: [
      scanID.localDataString,
      owner,
      localDataDate(1).timeIntervalSince1970,
      localDataDate(800).timeIntervalSince1970,
      localDataDate(1).timeIntervalSince1970,
      localDataDate(900).timeIntervalSince1970,
      localDataDate(141).timeIntervalSince1970,
      localDataDate(142).timeIntervalSince1970,
    ]
  )
  try database.execute(
    sql: """
      INSERT INTO calendar_series (
        id, owner_id, calendar_source_id, external_id_hmac,
        has_recurrence, created_at, updated_at
      ) VALUES (?, ?, ?, ?, 0, ?, ?)
      """,
    arguments: [
      seriesID.localDataString,
      owner,
      sourceID.localDataString,
      Data([0x02]),
      localDataDate(143).timeIntervalSince1970,
      localDataDate(143).timeIntervalSince1970,
    ]
  )
  try database.execute(
    sql: """
      INSERT INTO calendar_occurrences (
        id, owner_id, calendar_source_id, calendar_series_id, external_id_hmac,
        match_key_hmac, source_fingerprint, source_version, source_state,
        is_all_day, starts_at, ends_at, local_start_date, local_end_date_exclusive,
        timezone_id, title, location_text, last_seen_scan_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, 2, 'active', 0, ?, ?, '1970-01-01',
                '1970-01-02', 'Asia/Shanghai', 'SECRET_EVENT_TITLE', 'SECRET_ADDRESS', ?, ?, ?)
      """,
    arguments: [
      occurrenceID.localDataString,
      owner,
      sourceID.localDataString,
      seriesID.localDataString,
      Data([0x03]),
      Data([0x04]),
      Data([0x05]),
      localDataDate(200).timeIntervalSince1970,
      localDataDate(250).timeIntervalSince1970,
      scanID.localDataString,
      localDataDate(144).timeIntervalSince1970,
      localDataDate(145).timeIntervalSince1970,
    ]
  )
  try database.execute(
    sql: """
      INSERT INTO calendar_occurrence_revisions (
        id, owner_id, calendar_occurrence_id, from_version, to_version,
        old_starts_at, new_starts_at, old_ends_at, new_ends_at,
        old_timezone_id, new_timezone_id, detected_at
      ) VALUES (?, ?, ?, 1, 2, ?, ?, ?, ?, 'Asia/Shanghai', 'Asia/Shanghai', ?)
      """,
    arguments: [
      UUID().localDataString,
      owner,
      occurrenceID.localDataString,
      localDataDate(190).timeIntervalSince1970,
      localDataDate(200).timeIntervalSince1970,
      localDataDate(240).timeIntervalSince1970,
      localDataDate(250).timeIntervalSince1970,
      localDataDate(146).timeIntervalSince1970,
    ]
  )
  try database.execute(
    sql: """
      INSERT INTO event_trip_links (
        id, owner_id, calendar_occurrence_id, trip_plan_id,
        source_occurrence_version, created_at
      ) VALUES (?, ?, ?, ?, 2, ?)
      """,
    arguments: [
      UUID().localDataString,
      owner,
      occurrenceID.localDataString,
      planID.localDataString,
      localDataDate(147).timeIntervalSince1970,
    ]
  )
}

private nonisolated struct LocalDataCounts: Equatable {
  let profiles: Int
  let accounts: Int
  let transactions: Int
  let postings: Int
  let calendarSources: Int
  let calendarScans: Int
  let calendarSeries: Int
  let calendarOccurrences: Int
  let calendarRevisions: Int
  let eventLinks: Int
  let plans: Int
  let reminders: Int
  let journeys: Int
  let lifeLinks: Int
}

private nonisolated func localDataCounts(_ appDatabase: AppDatabase) throws -> LocalDataCounts {
  try appDatabase.pool.read { database in
    func count(_ table: String) throws -> Int {
      try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
    return try LocalDataCounts(
      profiles: count("local_profiles"),
      accounts: count("ledger_accounts"),
      transactions: count("ledger_transactions"),
      postings: count("postings"),
      calendarSources: count("calendar_sources"),
      calendarScans: count("calendar_scans"),
      calendarSeries: count("calendar_series"),
      calendarOccurrences: count("calendar_occurrences"),
      calendarRevisions: count("calendar_occurrence_revisions"),
      eventLinks: count("event_trip_links"),
      plans: count("trip_plans"),
      reminders: count("departure_reminders"),
      journeys: count("journeys"),
      lifeLinks: count("transaction_journey_links")
    )
  }
}

private nonisolated func localDataDate(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

private nonisolated struct LocalDataCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}

extension UUID {
  fileprivate nonisolated var localDataString: String { uuidString.lowercased() }
}
