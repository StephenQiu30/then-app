import Foundation
import Observation

@MainActor
@Observable
final class TodayViewModel {
  private let ownerID: UUID
  private let ledgerQuery: LedgerQueryService
  private let snapshotService: TodaySnapshotService
  private let now: @Sendable () -> Date
  private let timeZoneIdentifier: @Sendable () -> String
  private var searchGeneration = 0

  let launchMode: AppLaunchMode
  var ledgerIdentity: LocalLedgerIdentity
  var recentTransactions: [LedgerTransactionSummary] = []
  var searchResults: [LedgerTransactionSummary] = []
  var monthlyReport: LedgerMonthlyReport?
  var todayOccurrences: [CalendarOccurrenceSummary] = []
  var nextTripPlan: TripPlanSummary?
  var currentJourney: JourneySnapshot?
  var pending = TodayPendingSummary(calendarRevisionCount: 0, journeyReviewCount: 0)
  var snapshotIssues: Set<TodaySnapshotIssue> = []
  var searchText = ""
  var isLoading = false
  var isSearching = false
  var errorMessage: LocalizedStringResource?

  init(
    ledgerIdentity: LocalLedgerIdentity,
    launchMode: AppLaunchMode,
    ledgerQuery: LedgerQueryService,
    snapshotService: TodaySnapshotService,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
  ) {
    ownerID = ledgerIdentity.profileID
    self.ledgerIdentity = ledgerIdentity
    self.launchMode = launchMode
    self.ledgerQuery = ledgerQuery
    self.snapshotService = snapshotService
    self.now = now
    self.timeZoneIdentifier = timeZoneIdentifier
  }

  var isSearchActive: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func loadRecentTransactions() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    let snapshot = await snapshotService.snapshot(
      at: now(),
      timeZoneIdentifier: timeZoneIdentifier()
    )
    snapshotIssues = snapshot.issues
    if !snapshot.issues.contains(.calendar) {
      todayOccurrences = snapshot.occurrences ?? []
    }
    if !snapshot.issues.contains(.tripPlans) {
      nextTripPlan = snapshot.nextTripPlan
    }
    if !snapshot.issues.contains(.journeys) {
      currentJourney = snapshot.currentJourney
    }
    pending = TodayPendingSummary(
      calendarRevisionCount: snapshot.pending.calendarRevisionCount
        ?? pending.calendarRevisionCount,
      journeyReviewCount: snapshot.pending.journeyReviewCount
        ?? pending.journeyReviewCount
    )
    if let ledger = snapshot.ledger {
      do {
        ledgerIdentity = try ledgerIdentity.updating(profile: ledger.profile)
        recentTransactions = ledger.recentTransactions
        monthlyReport = ledger.monthlyReport
      } catch {
        snapshotIssues.insert(.ledger)
      }
    }
  }

  func search() async {
    searchGeneration += 1
    let generation = searchGeneration
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }
    isSearching = true
    errorMessage = nil
    defer {
      if searchGeneration == generation {
        isSearching = false
      }
    }

    do {
      let amountMinorUnits = try? LedgerAmountText.parsePositiveMoney(
        query,
        currencyCode: ledgerIdentity.baseCurrencyCode
      ).minorUnits
      let results = try await ledgerQuery.searchTransactions(
        ownerID: ownerID,
        searchText: query,
        amountMinorUnits: amountMinorUnits
      )
      guard searchGeneration == generation,
        searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
      else {
        return
      }
      searchResults = results
    } catch {
      errorMessage = "无法搜索本地账目，请稍后重试。"
    }
  }
}
