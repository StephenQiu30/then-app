import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("本地数据库")
struct AppDatabaseTests {
  @Test("受保护数据库目录和 SQLite 文件使用首次解锁后保护")
  func protectedDatabaseAppliesExpectedFileProtection() throws {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory.appending(
      path: "ThenAppProtectionTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appending(path: "protected.sqlite")
    let recordingFileManager = RecordingFileManager()
    let expectedProtection = FileProtectionType.completeUntilFirstUserAuthentication.rawValue

    let database = try AppDatabase.makeProtected(
      at: databaseURL,
      fileManager: recordingFileManager
    )
    let now = Date().timeIntervalSince1970
    try database.pool.write { database in
      try database.execute(
        sql:
          "INSERT INTO local_profiles (id, base_currency_code, base_currency_state, created_at, updated_at) VALUES (?, 'CNY', 'suggested', ?, ?)",
        arguments: [UUID().uuidString.lowercased(), now, now]
      )
    }

    let protectedURLs = [
      directoryURL,
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ]
    for protectedURL in protectedURLs {
      #expect(fileManager.fileExists(atPath: protectedURL.path))
    }
    #expect(
      recordingFileManager.directoryCreations.contains(
        .init(path: directoryURL.standardizedFileURL.path, protection: expectedProtection)
      ))
    #expect(
      Set(recordingFileManager.attributeUpdates.map(\.path))
        == Set(protectedURLs.map(\.standardizedFileURL.path)))
    #expect(
      recordingFileManager.attributeUpdates.allSatisfy {
        $0.protection == expectedProtection
      })
  }

  @Test("迁移集中创建账本日历计划行程和生活关联表并启用 WAL 与外键")
  func migrationCreatesLocalLedgerSchema() throws {
    try withTestDatabase { database in
      let snapshot = try database.pool.read { database in
        let tableNames = try String.fetchAll(
          database,
          sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        )
        let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode")
        let foreignKeysEnabled = try Int.fetchOne(database, sql: "PRAGMA foreign_keys")
        let migrationIdentifiers = try String.fetchAll(
          database,
          sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
        )
        return (tableNames, journalMode, foreignKeysEnabled, migrationIdentifiers)
      }

      #expect(snapshot.0.contains("local_profiles"))
      #expect(snapshot.0.contains("ledger_accounts"))
      #expect(snapshot.0.contains("ledger_transactions"))
      #expect(snapshot.0.contains("postings"))
      #expect(snapshot.0.contains("calendar_sources"))
      #expect(snapshot.0.contains("calendar_scans"))
      #expect(snapshot.0.contains("calendar_series"))
      #expect(snapshot.0.contains("calendar_occurrences"))
      #expect(snapshot.0.contains("calendar_occurrence_revisions"))
      #expect(snapshot.0.contains("location_snapshots"))
      #expect(snapshot.0.contains("trip_plans"))
      #expect(snapshot.0.contains("route_estimates"))
      #expect(snapshot.0.contains("departure_reminders"))
      #expect(snapshot.0.contains("navigation_handoffs"))
      #expect(snapshot.0.contains("event_trip_links"))
      #expect(snapshot.0.contains("journeys"))
      #expect(snapshot.0.contains("track_segments"))
      #expect(snapshot.0.contains("track_points"))
      #expect(snapshot.0.contains("transaction_journey_links"))
      #expect(!snapshot.0.contains("today_items"))
      #expect(snapshot.1 == "wal")
      #expect(snapshot.2 == 1)
      #expect(
        snapshot.3 == [
          DatabaseMigrations.initialLocalLedgerIdentifier,
          DatabaseMigrations.calendarCacheIdentifier,
          DatabaseMigrations.tripPlanningIdentifier,
          DatabaseMigrations.journeyRecordingIdentifier,
          DatabaseMigrations.lifeLinksIdentifier,
          DatabaseMigrations.manualLocationCompatibilityIdentifier,
          DatabaseMigrations.journeyExpenseReviewIdentifier,
          DatabaseMigrations.tripPlanRevisionReviewIdentifier,
        ])
      let journeyExpenseReviewDefault = try database.pool.read { database in
        try String.fetchOne(
          database,
          sql: """
            SELECT dflt_value
            FROM pragma_table_info('journeys')
            WHERE name = 'expense_review_state'
            """
        )
      }
      #expect(journeyExpenseReviewDefault == "'pending'")
      let revisionReviewColumns = try database.pool.read { database in
        let planVersionDefault = try String.fetchOne(
          database,
          sql: """
            SELECT dflt_value
            FROM pragma_table_info('trip_plans')
            WHERE name = 'plan_version'
            """
        )
        let displayNameSourceDefault = try String.fetchOne(
          database,
          sql: """
            SELECT dflt_value
            FROM pragma_table_info('trip_plans')
            WHERE name = 'display_name_value_source'
            """
        )
        let resolvedAtCount = try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM pragma_table_info('calendar_occurrence_revisions')
            WHERE name = 'resolved_at'
            """
        )
        return (planVersionDefault, displayNameSourceDefault, resolvedAtCount)
      }
      #expect(revisionReviewColumns.0 == "1")
      #expect(revisionReviewColumns.1 == "'user'")
      #expect(revisionReviewColumns.2 == 1)
    }
  }

  @Test("旧版地点表升级保留计划路线并支持纯文字地址")
  func legacyLocationSchemaUpgradesWithoutDataLoss() async throws {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory.appending(
      path: "ThenAppLegacyMigrationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appending(path: "legacy.sqlite")
    let origin = ConfirmedLocation(
      id: UUID(),
      name: "旧起点",
      address: "旧起点地址",
      latitude: 31.23,
      longitude: 121.47,
      source: .mapkit,
      horizontalAccuracy: 10
    )
    let destination = ConfirmedLocation(
      id: UUID(),
      name: "旧目的地",
      address: "旧目的地地址",
      latitude: 31.24,
      longitude: 121.48,
      source: .mapkit,
      horizontalAccuracy: 10
    )
    let legacyPlanID = UUID()
    let legacyTransactionID = UUID()
    let legacyJourneyID = UUID()

    do {
      let database = try AppDatabase.make(at: databaseURL)
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_000)
      )
      try await database.pool.writeWithoutTransaction { database in
        try database.execute(sql: "PRAGMA foreign_keys = OFF")
        defer { try? database.execute(sql: "PRAGMA foreign_keys = ON") }
        try database.inTransaction {
          try database.execute(sql: "PRAGMA legacy_alter_table = ON")
          defer { try? database.execute(sql: "PRAGMA legacy_alter_table = OFF") }
          try database.execute(sql: legacyLocationSnapshotsFixtureSQL)
          try database.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
            arguments: [DatabaseMigrations.manualLocationCompatibilityIdentifier]
          )
          return .commit
        }
      }

      let route = RouteEstimateDraft(
        id: UUID(),
        origin: origin,
        destination: destination,
        transportMode: .driving,
        distanceMeters: 5_000,
        expectedTravelSeconds: 1_200,
        calculatedAt: Date(timeIntervalSince1970: 1_100),
        expiresAt: Date(timeIntervalSince1970: 2_900)
      )
      _ = try await GRDBTripPlanRepository(database: database).savePlan(
        SaveTripPlanRequest(
          planID: legacyPlanID,
          ownerID: identity.profileID,
          displayName: "旧计划",
          origin: origin,
          destination: destination,
          transportMode: .driving,
          targetArrivalAt: Date(timeIntervalSince1970: 3_000),
          plannedDepartureAt: Date(timeIntervalSince1970: 2_000),
          timezoneIdentifier: "Asia/Shanghai",
          preparationBufferSeconds: 600,
          routeEstimate: route,
          eventSource: nil,
          displayNameValueSource: .user,
          destinationValueSource: .user,
          targetArrivalValueSource: .user,
          departureValueSource: .derived,
          reminderEnabled: false,
          reminderFollowsSource: false,
          submittedAt: Date(timeIntervalSince1970: 1_000)
        )
      )
      let ledgerRepository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: ledgerRepository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_050)
      )
      let expenseCategoryID = try await database.pool.read { database in
        let rawID = try String.fetchOne(
          database,
          sql: "SELECT id FROM ledger_accounts WHERE system_key = 'expense.uncategorized'"
        )
        return try #require(rawID.flatMap(UUID.init(uuidString:)))
      }
      _ = try await CreateTransactionUseCase(repository: ledgerRepository).execute(
        CreateLedgerTransactionRequest(
          transactionID: legacyTransactionID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: expenseCategoryID
          ),
          money: PositiveMoney(minorUnits: 888, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_150),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "旧版账务",
          note: nil,
          submittedAt: Date(timeIntervalSince1970: 1_160)
        )
      )
      _ = try await GRDBJourneyRepository(database: database).startJourney(
        JourneyStartRequest(
          journeyID: legacyJourneyID,
          ownerID: identity.profileID,
          tripPlanID: legacyPlanID,
          recordingDeviceID: UUID(),
          transportMode: .driving,
          startedAt: Date(timeIntervalSince1970: 1_200),
          trackingConsentVersion: 1
        )
      )
      try database.pool.close()
    }

    let upgradedDatabase = try AppDatabase.make(at: databaseURL)
    let upgradedSnapshot = try await upgradedDatabase.pool.read { database in
      try database.checkForeignKeys()
      let latitudeIsRequired = try Int.fetchOne(
        database,
        sql: """
          SELECT "notnull"
          FROM pragma_table_info('location_snapshots')
          WHERE name = 'latitude'
          """
      )
      let migrationCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
        arguments: [DatabaseMigrations.manualLocationCompatibilityIdentifier]
      )
      let locationCount = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM location_snapshots")
      let planName = try String.fetchOne(
        database,
        sql: "SELECT display_name FROM trip_plans WHERE id = ?",
        arguments: [legacyPlanID.uuidString.lowercased()]
      )
      let routeCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM route_estimates")
      let reminderCount = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM departure_reminders")
      let referencedTables = try String.fetchAll(
        database,
        sql: """
          SELECT DISTINCT "table"
          FROM pragma_foreign_key_list('trip_plans')
          ORDER BY "table"
          """
      )
      let locationIndexCount = try Int.fetchOne(
        database,
        sql: """
          SELECT COUNT(*)
          FROM sqlite_master
          WHERE type = 'index' AND name = 'location_snapshots_owner_created_idx'
          """
      )
      let integrity = try String.fetchOne(database, sql: "PRAGMA integrity_check")
      return (
        latitudeIsRequired,
        migrationCount,
        locationCount,
        planName,
        routeCount,
        reminderCount,
        referencedTables,
        locationIndexCount,
        integrity
      )
    }
    #expect(upgradedSnapshot.0 == 0)
    #expect(upgradedSnapshot.1 == 1)
    #expect(upgradedSnapshot.2 == 2)
    #expect(upgradedSnapshot.3 == "旧计划")
    #expect(upgradedSnapshot.4 == 1)
    #expect(upgradedSnapshot.5 == 1)
    #expect(upgradedSnapshot.6.contains("location_snapshots"))
    #expect(!upgradedSnapshot.6.contains("location_snapshots_v5"))
    #expect(upgradedSnapshot.7 == 1)
    #expect(upgradedSnapshot.8 == "ok")
    let preservedDomainCounts = try await upgradedDatabase.pool.read { database in
      let transactionCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM ledger_transactions WHERE id = ?",
        arguments: [legacyTransactionID.uuidString.lowercased()]
      )
      let journeyCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM journeys WHERE id = ? AND trip_plan_id = ?",
        arguments: [
          legacyJourneyID.uuidString.lowercased(),
          legacyPlanID.uuidString.lowercased(),
        ]
      )
      let staleSchemaReferenceCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM sqlite_schema WHERE sql LIKE '%location_snapshots_v5%'"
      )
      return (transactionCount, journeyCount, staleSchemaReferenceCount)
    }
    #expect(preservedDomainCounts == (1, 1, 0))

    let ownerID = try await upgradedDatabase.pool.read { database in
      let rawID = try String.fetchOne(database, sql: "SELECT id FROM local_profiles")
      return try #require(rawID.flatMap(UUID.init(uuidString:)))
    }
    let manualDestination = ConfirmedLocation(
      id: UUID(),
      name: "上海市人民广场",
      address: "上海市人民广场",
      latitude: nil,
      longitude: nil,
      source: .manual,
      horizontalAccuracy: nil
    )
    _ = try await GRDBTripPlanRepository(database: upgradedDatabase).savePlan(
      SaveTripPlanRequest(
        planID: UUID(),
        ownerID: ownerID,
        displayName: "升级后的手动计划",
        origin: nil,
        destination: manualDestination,
        transportMode: .walking,
        targetArrivalAt: Date(timeIntervalSince1970: 5_000),
        plannedDepartureAt: Date(timeIntervalSince1970: 4_000),
        timezoneIdentifier: "Asia/Shanghai",
        preparationBufferSeconds: 300,
        routeEstimate: nil,
        eventSource: nil,
        displayNameValueSource: .user,
        destinationValueSource: .user,
        targetArrivalValueSource: .user,
        departureValueSource: .user,
        reminderEnabled: false,
        reminderFollowsSource: false,
        submittedAt: Date(timeIntervalSince1970: 3_000)
      )
    )
    let finalSnapshot = try await upgradedDatabase.pool.read { database in
      try database.checkForeignKeys()
      let plans = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM trip_plans")
      let manualLocations = try Int.fetchOne(
        database,
        sql: """
          SELECT COUNT(*)
          FROM location_snapshots
          WHERE latitude IS NULL AND longitude IS NULL AND coordinate_system IS NULL
          """
      )
      return (plans, manualLocations)
    }
    #expect(finalSnapshot == (2, 1))
    try upgradedDatabase.pool.close()

    let secondLaunch = try AppDatabase.make(at: databaseURL)
    let repeatedMigrationCount = try await secondLaunch.pool.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
        arguments: [DatabaseMigrations.manualLocationCompatibilityIdentifier]
      )
    }
    #expect(repeatedMigrationCount == 1)
  }

  @Test("v6 历史库升级消费复盘状态并保留关系与账务")
  func legacyJourneyExpenseReviewStateUpgradesWithoutDataLoss() async throws {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory.appending(
      path: "ThenAppJourneyExpenseMigrationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appending(path: "legacy.sqlite")
    let transactionID = UUID()
    let linkedJourneyID = UUID()
    let pendingJourneyID = UUID()
    var profileID: UUID?

    do {
      let database = try AppDatabase.make(at: databaseURL)
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 10)
      )
      profileID = identity.profileID
      let ledger = GRDBLedgerRepository(database: database)
      _ = try await ledger.confirmBaseCurrency(
        BaseCurrencyConfirmation(
          ownerID: identity.profileID,
          currencyCode: .cny,
          confirmedAt: Date(timeIntervalSince1970: 20)
        )
      )
      let categoryID = try await database.pool.read { database in
        let rawID = try String.fetchOne(
          database,
          sql: "SELECT id FROM ledger_accounts WHERE system_key = 'expense.transport'"
        )
        return try #require(rawID.flatMap(UUID.init(uuidString:)))
      }
      _ = try await ledger.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: transactionID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: categoryID
          ),
          money: PositiveMoney(minorUnits: 2_600, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "历史行程支出",
          note: nil,
          submittedAt: Date(timeIntervalSince1970: 110)
        )
      )
      let journeys = GRDBJourneyRepository(database: database)
      for (journeyID, deviceID) in [
        (linkedJourneyID, UUID()),
        (pendingJourneyID, UUID()),
      ] {
        _ = try await journeys.startJourney(
          JourneyStartRequest(
            journeyID: journeyID,
            ownerID: identity.profileID,
            tripPlanID: nil,
            recordingDeviceID: deviceID,
            transportMode: .walking,
            startedAt: Date(timeIntervalSince1970: 120),
            trackingConsentVersion: 1
          )
        )
        _ = try await journeys.beginFinalization(
          ownerID: identity.profileID,
          journeyID: journeyID,
          reason: .userEnded,
          endedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try await journeys.finalizeJourney(
          ownerID: identity.profileID,
          journeyID: journeyID,
          finalizedAt: Date(timeIntervalSince1970: 210)
        )
      }
      _ = try await GRDBLifeLinkRepository(database: database).linkTransactionToJourney(
        LinkTransactionToJourneyRequest(
          linkID: UUID(),
          ownerID: identity.profileID,
          transactionRootID: transactionID,
          journeyID: linkedJourneyID,
          role: .transport,
          confirmedAt: Date(timeIntervalSince1970: 300)
        )
      )

      try await database.pool.writeWithoutTransaction { database in
        try database.execute(sql: "PRAGMA foreign_keys = OFF")
        defer { try? database.execute(sql: "PRAGMA foreign_keys = ON") }
        try database.inTransaction {
          try database.execute(sql: "ALTER TABLE journeys DROP COLUMN expense_review_state")
          try database.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
            arguments: [DatabaseMigrations.journeyExpenseReviewIdentifier]
          )
          return .commit
        }
      }
      try database.pool.close()
    }

    let ownerID = try #require(profileID)
    let upgradedDatabase = try AppDatabase.make(at: databaseURL)
    let snapshot = try await upgradedDatabase.pool.read { database in
      try database.checkForeignKeys()
      let states = try Row.fetchAll(
        database,
        sql: """
          SELECT id, expense_review_state
          FROM journeys
          WHERE owner_id = ?
          ORDER BY id
          """,
        arguments: [ownerID.uuidString.lowercased()]
      ).reduce(into: [String: String]()) { values, row in
        values[row["id"]] = row["expense_review_state"]
      }
      let migrationCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
        arguments: [DatabaseMigrations.journeyExpenseReviewIdentifier]
      )
      let transactionCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM ledger_transactions WHERE id = ?",
        arguments: [transactionID.uuidString.lowercased()]
      )
      let linkCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM transaction_journey_links WHERE journey_id = ?",
        arguments: [linkedJourneyID.uuidString.lowercased()]
      )
      let integrity = try String.fetchOne(database, sql: "PRAGMA integrity_check")
      return (states, migrationCount, transactionCount, linkCount, integrity)
    }
    #expect(snapshot.0[linkedJourneyID.uuidString.lowercased()] == "has_expense")
    #expect(snapshot.0[pendingJourneyID.uuidString.lowercased()] == "pending")
    #expect(snapshot.1 == 1)
    #expect(snapshot.2 == 1)
    #expect(snapshot.3 == 1)
    #expect(snapshot.4 == "ok")

    let summary = try await GRDBLifeLinkRepository(database: upgradedDatabase)
      .journeyExpenseSummary(ownerID: ownerID, journeyID: linkedJourneyID)
    #expect(summary.reviewState == .hasExpense)
    #expect(summary.expenses.count == 1)
  }

  @Test("v7 历史库升级计划版本和来源解决状态且不丢数据")
  func legacyTripPlanRevisionReviewUpgradesWithoutDataLoss() async throws {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory.appending(
      path: "ThenAppTripRevisionMigrationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directoryURL) }
    let databaseURL = directoryURL.appending(path: "legacy.sqlite")
    let planID = UUID()
    var profileID: UUID?
    var occurrenceID: UUID?

    do {
      let database = try AppDatabase.make(at: databaseURL)
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 10)
      )
      profileID = identity.profileID
      let occurrence = try await persistRevisionReviewOccurrence(
        database: database,
        ownerID: identity.profileID,
        fingerprintByte: 0xc1,
        title: "历史事件",
        locationText: "历史地点",
        scanTime: 900
      )
      occurrenceID = occurrence.id
      _ = try await GRDBTripPlanRepository(database: database).savePlan(
        SaveTripPlanRequest(
          planID: planID,
          ownerID: identity.profileID,
          displayName: "历史计划",
          origin: nil,
          destination: ConfirmedLocation(
            id: UUID(),
            name: "历史地点",
            address: "历史地点",
            latitude: nil,
            longitude: nil,
            source: .manual,
            horizontalAccuracy: nil
          ),
          transportMode: .walking,
          targetArrivalAt: occurrence.startsAt,
          plannedDepartureAt: occurrence.startsAt.addingTimeInterval(-1_800),
          timezoneIdentifier: "Asia/Shanghai",
          preparationBufferSeconds: 300,
          routeEstimate: nil,
          eventSource: TripPlanEventSource(
            occurrenceID: occurrence.id,
            sourceVersion: occurrence.sourceVersion
          ),
          displayNameValueSource: .event,
          destinationValueSource: .user,
          targetArrivalValueSource: .event,
          departureValueSource: .user,
          reminderEnabled: false,
          reminderFollowsSource: false,
          submittedAt: Date(timeIntervalSince1970: 1_000)
        )
      )
      _ = try await persistRevisionReviewOccurrence(
        database: database,
        ownerID: identity.profileID,
        fingerprintByte: 0xc2,
        title: "第一次变化",
        locationText: "地点二",
        scanTime: 1_100
      )
      try await database.pool.write { database in
        try database.execute(
          sql: """
            UPDATE calendar_occurrence_revisions
            SET resolution_state = 'ignored', resolved_at = detected_at + 1
            WHERE calendar_occurrence_id = ? AND to_version = 2
            """,
          arguments: [occurrence.id.uuidString.lowercased()]
        )
      }
      _ = try await persistRevisionReviewOccurrence(
        database: database,
        ownerID: identity.profileID,
        fingerprintByte: 0xc3,
        title: "第二次变化",
        locationText: "地点三",
        scanTime: 1_200
      )

      try await database.pool.writeWithoutTransaction { database in
        try database.execute(sql: "PRAGMA foreign_keys = OFF")
        defer { try? database.execute(sql: "PRAGMA foreign_keys = ON") }
        try database.inTransaction {
          try database.execute(sql: legacyTripPlanRevisionReviewFixtureSQL)
          try database.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
            arguments: [DatabaseMigrations.tripPlanRevisionReviewIdentifier]
          )
          return .commit
        }
      }
      try database.pool.close()
    }

    let ownerID = try #require(profileID)
    let sourceOccurrenceID = try #require(occurrenceID)
    let upgradedDatabase = try AppDatabase.make(at: databaseURL)
    let snapshot = try await upgradedDatabase.pool.read { database in
      try database.checkForeignKeys()
      let plan = try #require(
        try Row.fetchOne(
          database,
          sql: """
            SELECT display_name, plan_version, display_name_value_source,
                   display_name_user_overridden_at
            FROM trip_plans
            WHERE owner_id = ? AND id = ?
            """,
          arguments: [ownerID.uuidString.lowercased(), planID.uuidString.lowercased()]
        )
      )
      let revisions = try Row.fetchAll(
        database,
        sql: """
          SELECT to_version, detected_at, resolution_state, resolved_at
          FROM calendar_occurrence_revisions
          WHERE owner_id = ? AND calendar_occurrence_id = ?
          ORDER BY to_version
          """,
        arguments: [ownerID.uuidString.lowercased(), sourceOccurrenceID.uuidString.lowercased()]
      )
      let migrationCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
        arguments: [DatabaseMigrations.tripPlanRevisionReviewIdentifier]
      )
      let linkCount = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM event_trip_links WHERE trip_plan_id = ?",
        arguments: [planID.uuidString.lowercased()]
      )
      let integrity = try String.fetchOne(database, sql: "PRAGMA integrity_check")
      return (plan, revisions, migrationCount, linkCount, integrity)
    }
    #expect(snapshot.0["display_name"] as String? == "历史计划")
    #expect(snapshot.0["plan_version"] as Int == 1)
    #expect(snapshot.0["display_name_value_source"] as String == "user")
    #expect(snapshot.0["display_name_user_overridden_at"] as Double? == nil)
    #expect(snapshot.1.count == 2)
    #expect(snapshot.1[0]["resolution_state"] as String == "ignored")
    #expect(snapshot.1[0]["resolved_at"] as Double == snapshot.1[0]["detected_at"] as Double)
    #expect(snapshot.1[1]["resolution_state"] as String == "pending")
    #expect(snapshot.1[1]["resolved_at"] as Double? == nil)
    #expect(snapshot.2 == 1)
    #expect(snapshot.3 == 1)
    #expect(snapshot.4 == "ok")

    await #expect(throws: DatabaseError.self) {
      try await upgradedDatabase.pool.write { database in
        try database.execute(
          sql: """
            UPDATE calendar_occurrence_revisions
            SET resolved_at = detected_at
            WHERE calendar_occurrence_id = ? AND resolution_state = 'pending'
            """,
          arguments: [sourceOccurrenceID.uuidString.lowercased()]
        )
      }
    }
  }

  @Test("首次账本初始化可重试且不会改变最初建议币种")
  func localLedgerBootstrapIsIdempotent() throws {
    try withTestDatabase { database in
      let bootstrap = LocalLedgerBootstrap(database: database)
      let firstIdentity = try bootstrap.initializeIfNeeded(
        suggestedCurrencyCode: CurrencyCode(rawValue: "cny")!,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let secondIdentity = try bootstrap.initializeIfNeeded(
        suggestedCurrencyCode: CurrencyCode(rawValue: "usd")!,
        now: Date(timeIntervalSince1970: 1_786_287_100)
      )

      let snapshot = try database.pool.read { database in
        let profileCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM local_profiles")
        let accountCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ledger_accounts")
        let currencyCode = try String.fetchOne(
          database,
          sql: "SELECT base_currency_code FROM local_profiles"
        )
        let currencyState = try String.fetchOne(
          database,
          sql: "SELECT base_currency_state FROM local_profiles"
        )
        let cashConfigurationState = try String.fetchOne(
          database,
          sql: """
            SELECT configuration_state
            FROM ledger_accounts
            WHERE system_key = 'asset.cash.default'
            """
        )
        return (
          profileCount,
          accountCount,
          currencyCode,
          currencyState,
          cashConfigurationState
        )
      }

      #expect(firstIdentity == secondIdentity)
      #expect(snapshot.0 == 1)
      #expect(snapshot.1 == 11)
      #expect(snapshot.2 == "CNY")
      #expect(snapshot.3 == "suggested")
      #expect(snapshot.4 == "pending_currency_confirmation")
    }
  }

  @Test("schema 拒绝第二个本地资料和非法正式交易")
  func schemaRejectsInvalidWrites() throws {
    try withTestDatabase { database in
      let bootstrap = LocalLedgerBootstrap(database: database)
      let identity = try bootstrap.initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )

      #expect(throws: DatabaseError.self) {
        try database.pool.write { database in
          try database.execute(
            sql: """
              INSERT INTO local_profiles (
                id,
                singleton_key,
                base_currency_code,
                base_currency_state,
                created_at,
                updated_at
              ) VALUES (?, 1, 'CNY', 'suggested', 1, 1)
              """,
            arguments: [UUID().uuidString.lowercased()]
          )
        }
      }

      #expect(throws: DatabaseError.self) {
        try database.pool.write { database in
          try database.execute(
            sql: """
              INSERT INTO ledger_accounts (
                id,
                owner_id,
                kind,
                subtype,
                name,
                native_currency_code,
                configuration_state,
                status,
                display_order,
                created_at,
                updated_at
              ) VALUES (?, ?, 'asset', 'invalid_subtype', '非法账户', 'CNY', 'ready', 'active', 0, 1, 1)
              """,
            arguments: [
              UUID().uuidString.lowercased(),
              identity.profileID.uuidString.lowercased(),
            ]
          )
        }
      }

      #expect(throws: DatabaseError.self) {
        try database.pool.write { database in
          let transactionID = UUID().uuidString.lowercased()
          try database.execute(
            sql: """
              INSERT INTO ledger_transactions (
                id,
                owner_id,
                status,
                kind,
                canonical_root_id,
                local_root_revision,
                occurred_at,
                original_timezone_id,
                local_date,
                source_type,
                posted_at,
                created_at,
                updated_at
              ) VALUES (?, ?, 'posted', 'expense', ?, 0, 1, 'Asia/Shanghai', '2026-08-09', 'manual', NULL, 1, 1)
              """,
            arguments: [transactionID, identity.profileID.uuidString, transactionID]
          )
        }
      }
    }
  }
}

nonisolated(unsafe) private let legacyLocationSnapshotsFixtureSQL = """
    ALTER TABLE location_snapshots RENAME TO location_snapshots_current;
    DROP INDEX location_snapshots_owner_created_idx;

    CREATE TABLE location_snapshots (
      id TEXT PRIMARY KEY NOT NULL,
      owner_id TEXT NOT NULL,
      name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
      address TEXT CHECK (address IS NULL OR length(trim(address)) BETWEEN 1 AND 500),
      latitude REAL NOT NULL CHECK (latitude BETWEEN -90 AND 90),
      longitude REAL NOT NULL CHECK (longitude BETWEEN -180 AND 180),
      coordinate_system TEXT NOT NULL CHECK (coordinate_system = 'wgs84'),
      source TEXT NOT NULL CHECK (source IN ('manual', 'mapkit')),
      horizontal_accuracy REAL CHECK (horizontal_accuracy IS NULL OR horizontal_accuracy >= 0),
      created_at REAL NOT NULL CHECK (created_at >= 0),
      UNIQUE (id, owner_id),
      FOREIGN KEY (owner_id) REFERENCES local_profiles(id) ON DELETE CASCADE
    ) STRICT;

    INSERT INTO location_snapshots
    SELECT * FROM location_snapshots_current;
    DROP TABLE location_snapshots_current;

    CREATE INDEX location_snapshots_owner_created_idx
      ON location_snapshots(owner_id, created_at DESC, id);
  """

private nonisolated func persistRevisionReviewOccurrence(
  database: AppDatabase,
  ownerID: UUID,
  fingerprintByte: UInt8,
  title: String,
  locationText: String,
  scanTime: TimeInterval
) async throws -> CalendarOccurrenceSummary {
  let repository = GRDBCalendarRepository(database: database)
  let sourceIdentity = Data(repeating: 0xb1, count: 32)
  let sourceID = try #require(
    try await repository.reconcileSources(
      ownerID: ownerID,
      snapshots: [
        SystemCalendarSourceSnapshot(
          externalIdentityHMAC: sourceIdentity,
          title: "历史日历",
          kind: .local,
          isSubscribed: false,
          allowsContentModifications: true
        )
      ],
      observedAt: Date(timeIntervalSince1970: scanTime - 2)
    ).first?.id
  )
  _ = try await repository.setSourceSelection(
    ownerID: ownerID,
    sourceID: sourceID,
    isSelected: true,
    changedAt: Date(timeIntervalSince1970: scanTime - 1)
  )
  let window = CalendarScanWindow(
    displayStart: Date(timeIntervalSince1970: 2_000),
    displayEnd: Date(timeIntervalSince1970: 5_000),
    matchingStart: Date(timeIntervalSince1970: 1_500),
    matchingEnd: Date(timeIntervalSince1970: 6_000)
  )
  let scanID = UUID()
  try await repository.beginScan(
    ownerID: ownerID,
    scanID: scanID,
    window: window,
    startedAt: Date(timeIntervalSince1970: scanTime)
  )
  _ = try await repository.commitScan(
    CalendarScanCommit(
      scanID: scanID,
      ownerID: ownerID,
      window: window,
      occurrences: [
        SystemCalendarOccurrenceSnapshot(
          sourceExternalIdentityHMAC: sourceIdentity,
          seriesExternalIdentityHMAC: Data(repeating: 0xb2, count: 32),
          occurrenceExternalIdentityHMAC: Data(repeating: 0xb3, count: 32),
          matchKeyHMAC: Data(repeating: 0xb4, count: 32),
          sourceFingerprint: Data(repeating: fingerprintByte, count: 32),
          hasRecurrence: false,
          isCancelled: false,
          isAllDay: false,
          startsAt: Date(timeIntervalSince1970: 3_000 + scanTime - 900),
          endsAt: Date(timeIntervalSince1970: 3_600 + scanTime - 900),
          localStartDate: "2026-08-12",
          localEndDateExclusive: "2026-08-12",
          timeZoneIdentifier: "Asia/Shanghai",
          title: title,
          locationText: locationText
        )
      ],
      completedAt: Date(timeIntervalSince1970: scanTime + 1)
    )
  )
  return try #require(
    try await repository.occurrences(
      ownerID: ownerID,
      from: window.displayStart,
      through: window.displayEnd
    ).first
  )
}

nonisolated(unsafe) private let legacyTripPlanRevisionReviewFixtureSQL = """
  ALTER TABLE trip_plans DROP COLUMN display_name_user_overridden_at;
  ALTER TABLE trip_plans DROP COLUMN display_name_value_source;
  ALTER TABLE trip_plans DROP COLUMN plan_version;

  DROP INDEX calendar_occurrence_revisions_owner_pending_idx;
  ALTER TABLE calendar_occurrence_revisions
    RENAME TO calendar_occurrence_revisions_v8;

  CREATE TABLE calendar_occurrence_revisions (
    id TEXT PRIMARY KEY NOT NULL,
    owner_id TEXT NOT NULL,
    calendar_occurrence_id TEXT NOT NULL,
    from_version INTEGER NOT NULL CHECK (from_version >= 1),
    to_version INTEGER NOT NULL CHECK (to_version = from_version + 1),
    old_starts_at REAL NOT NULL,
    new_starts_at REAL NOT NULL,
    old_ends_at REAL NOT NULL,
    new_ends_at REAL NOT NULL,
    old_timezone_id TEXT NOT NULL,
    new_timezone_id TEXT NOT NULL,
    old_title TEXT,
    new_title TEXT,
    old_location_text TEXT,
    new_location_text TEXT,
    detected_at REAL NOT NULL CHECK (detected_at >= 0),
    resolution_state TEXT NOT NULL DEFAULT 'pending'
      CHECK (resolution_state IN ('pending', 'accepted', 'ignored')),
    UNIQUE (calendar_occurrence_id, to_version),
    FOREIGN KEY (calendar_occurrence_id, owner_id)
      REFERENCES calendar_occurrences(id, owner_id) ON DELETE CASCADE
  ) STRICT;

  INSERT INTO calendar_occurrence_revisions (
    id, owner_id, calendar_occurrence_id, from_version, to_version,
    old_starts_at, new_starts_at, old_ends_at, new_ends_at,
    old_timezone_id, new_timezone_id, old_title, new_title,
    old_location_text, new_location_text, detected_at, resolution_state
  )
  SELECT
    id, owner_id, calendar_occurrence_id, from_version, to_version,
    old_starts_at, new_starts_at, old_ends_at, new_ends_at,
    old_timezone_id, new_timezone_id, old_title, new_title,
    old_location_text, new_location_text, detected_at, resolution_state
  FROM calendar_occurrence_revisions_v8;

  DROP TABLE calendar_occurrence_revisions_v8;

  CREATE INDEX calendar_occurrence_revisions_owner_pending_idx
    ON calendar_occurrence_revisions(owner_id, resolution_state, detected_at, id);
  """
