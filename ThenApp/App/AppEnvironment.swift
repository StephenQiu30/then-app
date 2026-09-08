import Foundation

nonisolated struct AppEnvironment: Sendable {
  let database: AppDatabase
  let localLedgerIdentity: LocalLedgerIdentity
  let launchMode: AppLaunchMode
  let confirmBaseCurrency: ConfirmBaseCurrencyUseCase
  let createLedgerAccount: CreateLedgerAccountUseCase
  let setLedgerAccountStatus: SetLedgerAccountStatusUseCase
  let createTransaction: CreateTransactionUseCase
  let refundTransaction: RefundTransactionUseCase
  let reverseTransaction: ReverseTransactionUseCase
  let correctTransaction: CorrectTransactionUseCase
  let ledgerQuery: LedgerQueryService
  let receiptOCR: any ReceiptOCRService
  let receiptCameraAccess: any ReceiptCameraAccessService
  let calendarImport: CalendarImportService
  let tripPlanning: TripPlanningService
  let journeyRecording: JourneyRecordingService
  let journeyNavigation: JourneyNavigationCoordinator
  let lifeLinks: LifeLinkService
  let todaySnapshot: TodaySnapshotService
  let permissionStatus: any PermissionStatusService
  let localData: any LocalDataManaging

  static func bootstrap() throws -> AppEnvironment {
    let database = try makeDatabase()
    let currentCurrencyIdentifier = Locale.current.currency?.identifier
    let suggestedCurrencyCode =
      currentCurrencyIdentifier
      .flatMap { CurrencyCode(rawValue: $0) } ?? CurrencyCode.cny
    let localLedgerIdentity = try LocalLedgerBootstrap(database: database)
      .initializeIfNeeded(suggestedCurrencyCode: suggestedCurrencyCode)
    let ledgerRepository = GRDBLedgerRepository(database: database)
    let calendarRepository = GRDBCalendarRepository(database: database)
    let calendarService = makeCalendarService()
    let tripPlanRepository = GRDBTripPlanRepository(database: database)
    let journeyRepository = GRDBJourneyRepository(database: database)
    let lifeLinkRepository = GRDBLifeLinkRepository(database: database)
    let reminderService = LocalNotificationReminderService()
    let recordingDeviceID = try JourneyDeviceIdentityStore().loadOrCreateID()
    let ledgerQuery = LedgerQueryService(repository: ledgerRepository)

    let tripPlanning = TripPlanningService(
      ownerID: localLedgerIdentity.profileID,
      repository: tripPlanRepository,
      placeSearch: MapKitPlaceSearchService(),
      routePlanning: MapKitRoutePlanningService(),
      reminders: reminderService,
      navigation: makeNavigationService()
    )
    let journeyRecording = JourneyRecordingService(
      ownerID: localLedgerIdentity.profileID,
      recordingDeviceID: recordingDeviceID,
      repository: journeyRepository,
      locationDriver: CoreLocationJourneyDriver()
    )
    let todaySnapshot = TodaySnapshotService(
      occurrences: { referenceDate in
        try await CalendarImportService(
          ownerID: localLedgerIdentity.profileID,
          service: calendarService,
          repository: calendarRepository
        ).visibleOccurrences(referenceDate: referenceDate)
      },
      plans: {
        try await tripPlanning.plans()
      },
      journeys: {
        try await journeyRecording.journeys()
      },
      ledger: { referenceDate, timeZoneIdentifier in
        let profile = try await ledgerQuery.localProfile(ownerID: localLedgerIdentity.profileID)
        async let recentTransactions = ledgerQuery.recentTransactions(
          ownerID: localLedgerIdentity.profileID
        )
        let monthlyReport: LedgerMonthlyReport?
        if profile.baseCurrencyState == .confirmed {
          monthlyReport = try await ledgerQuery.monthlyReport(
            ownerID: localLedgerIdentity.profileID,
            containing: referenceDate,
            timeZoneIdentifier: timeZoneIdentifier
          )
        } else {
          monthlyReport = nil
        }
        return try await TodayLedgerSnapshot(
          profile: profile,
          recentTransactions: recentTransactions,
          monthlyReport: monthlyReport
        )
      }
    )

    return AppEnvironment(
      database: database,
      localLedgerIdentity: localLedgerIdentity,
      launchMode: .local,
      confirmBaseCurrency: ConfirmBaseCurrencyUseCase(repository: ledgerRepository),
      createLedgerAccount: CreateLedgerAccountUseCase(repository: ledgerRepository),
      setLedgerAccountStatus: SetLedgerAccountStatusUseCase(repository: ledgerRepository),
      createTransaction: CreateTransactionUseCase(repository: ledgerRepository),
      refundTransaction: RefundTransactionUseCase(repository: ledgerRepository),
      reverseTransaction: ReverseTransactionUseCase(repository: ledgerRepository),
      correctTransaction: CorrectTransactionUseCase(repository: ledgerRepository),
      ledgerQuery: ledgerQuery,
      receiptOCR: VisionReceiptOCRService(),
      receiptCameraAccess: AVReceiptCameraAccessService(),
      calendarImport: CalendarImportService(
        ownerID: localLedgerIdentity.profileID,
        service: calendarService,
        repository: calendarRepository
      ),
      tripPlanning: tripPlanning,
      journeyRecording: journeyRecording,
      journeyNavigation: JourneyNavigationCoordinator(
        recording: journeyRecording,
        tripPlanning: tripPlanning
      ),
      lifeLinks: LifeLinkService(
        ownerID: localLedgerIdentity.profileID,
        repository: lifeLinkRepository
      ),
      todaySnapshot: todaySnapshot,
      permissionStatus: SystemPermissionStatusService(),
      localData: GRDBLocalDataManagementService(
        database: database,
        ownerID: localLedgerIdentity.profileID,
        journeyRecording: journeyRecording,
        reminders: reminderService
      )
    )
  }

  private static func makeDatabase() throws -> AppDatabase {
    #if DEBUG
      let prefix = "--then-ui-testing-storage-id="
      if let argument = ProcessInfo.processInfo.arguments.first(where: {
        $0.hasPrefix(prefix)
      }) {
        guard let storageID = UUID(uuidString: String(argument.dropFirst(prefix.count))) else {
          throw AppDatabaseError.invalidUITestStorageID
        }
        return try AppDatabase.makeUITesting(storageID: storageID)
      }
    #endif
    return try AppDatabase.makeProduction()
  }

  private static func makeCalendarService() -> any CalendarService {
    #if DEBUG
      let prefix = "--then-ui-testing-calendar-trip="
      if let argument = ProcessInfo.processInfo.arguments.first(where: {
        $0.hasPrefix(prefix)
      }) {
        let scenario = String(argument.dropFirst(prefix.count))
        if scenario == "all-day" || scenario == "regular" || scenario == "revision" {
          return DebugCalendarFixtureService(scenario: scenario)
        }
      }
    #endif
    return EventKitCalendarService()
  }

  private static func makeNavigationService() -> any ExternalNavigationService {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--then-ui-testing-navigation-failure") {
        return DebugFailedNavigationService()
      }
    #endif
    return AppleMapsNavigationService()
  }
}

#if DEBUG
  private nonisolated struct DebugFailedNavigationService: ExternalNavigationService {
    @MainActor
    func openAppleMaps(
      destination: ConfirmedLocation,
      transportMode: TripTransportMode
    ) async -> Bool {
      false
    }
  }

  private actor DebugCalendarFixtureService: CalendarService {
    private let sourceIdentity = Data(repeating: 0xa1, count: 32)
    private let initialOccurrence: SystemCalendarOccurrenceSnapshot
    private let changedOccurrence: SystemCalendarOccurrenceSnapshot?
    private var occurrenceQueryCount = 0

    init(scenario: String, referenceDate: Date = Date()) {
      let isAllDay = scenario == "all-day"
      var calendar = Calendar(identifier: .gregorian)
      let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
      calendar.timeZone = timeZone
      let startOfToday = calendar.startOfDay(for: referenceDate)
      let startsAt =
        calendar.date(byAdding: .day, value: 1, to: startOfToday)
        ?? referenceDate.addingTimeInterval(24 * 60 * 60)
      let endsAt =
        calendar.date(byAdding: .hour, value: 1, to: startsAt)
        ?? startsAt.addingTimeInterval(60 * 60)
      let localEnd =
        calendar.date(byAdding: .day, value: 1, to: startsAt)
        ?? endsAt
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = calendar
      formatter.timeZone = timeZone
      formatter.dateFormat = "yyyy-MM-dd"
      initialOccurrence = SystemCalendarOccurrenceSnapshot(
        sourceExternalIdentityHMAC: sourceIdentity,
        seriesExternalIdentityHMAC: Data(repeating: 0xa2, count: 32),
        occurrenceExternalIdentityHMAC: Data(repeating: 0xa3, count: 32),
        matchKeyHMAC: Data(repeating: 0xa4, count: 32),
        sourceFingerprint: Data(repeating: 0xa5, count: 32),
        hasRecurrence: false,
        isCancelled: false,
        isAllDay: isAllDay,
        startsAt: startsAt,
        endsAt: endsAt,
        localStartDate: formatter.string(from: startsAt),
        localEndDateExclusive: formatter.string(from: localEnd),
        timeZoneIdentifier: timeZone.identifier,
        title: isAllDay ? "自动化全天会议" : "自动化会议",
        locationText: "自动化会场"
      )
      if scenario == "revision" {
        let changedStart = startsAt.addingTimeInterval(30 * 60)
        changedOccurrence = SystemCalendarOccurrenceSnapshot(
          sourceExternalIdentityHMAC: sourceIdentity,
          seriesExternalIdentityHMAC: Data(repeating: 0xa2, count: 32),
          occurrenceExternalIdentityHMAC: Data(repeating: 0xa3, count: 32),
          matchKeyHMAC: Data(repeating: 0xa4, count: 32),
          sourceFingerprint: Data(repeating: 0xa6, count: 32),
          hasRecurrence: false,
          isCancelled: false,
          isAllDay: false,
          startsAt: changedStart,
          endsAt: changedStart.addingTimeInterval(60 * 60),
          localStartDate: formatter.string(from: changedStart),
          localEndDateExclusive: formatter.string(from: localEnd),
          timeZoneIdentifier: timeZone.identifier,
          title: "自动化改期会议",
          locationText: "自动化新会场"
        )
      } else {
        changedOccurrence = nil
      }
    }

    func authorizationState() async -> CalendarAuthorizationState { .fullAccess }

    func requestFullAccess() async throws -> CalendarAuthorizationState { .fullAccess }

    func availableSources() async throws -> [SystemCalendarSourceSnapshot] {
      [
        SystemCalendarSourceSnapshot(
          externalIdentityHMAC: sourceIdentity,
          title: "自动化日历",
          kind: .local,
          isSubscribed: false,
          allowsContentModifications: true
        )
      ]
    }

    func occurrences(
      selectedSourceIdentityHMACs: Set<Data>,
      matchingFrom startDate: Date,
      through endDate: Date
    ) async throws -> [SystemCalendarOccurrenceSnapshot] {
      let occurrence: SystemCalendarOccurrenceSnapshot
      if occurrenceQueryCount > 0, let changedOccurrence {
        occurrence = changedOccurrence
      } else {
        occurrence = initialOccurrence
      }
      occurrenceQueryCount += 1
      guard selectedSourceIdentityHMACs.contains(sourceIdentity),
        occurrence.startsAt < endDate,
        occurrence.endsAt > startDate
      else {
        return []
      }
      return [occurrence]
    }

    func eventStoreChanges() async -> AsyncStream<Void> {
      AsyncStream { continuation in continuation.finish() }
    }
  }
#endif
