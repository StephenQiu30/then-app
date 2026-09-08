import Foundation

nonisolated enum TodaySnapshotIssue: String, CaseIterable, Hashable, Sendable {
  case calendar
  case tripPlans = "trip_plans"
  case journeys
  case ledger
}

nonisolated struct TodayLedgerSnapshot: Sendable, Equatable {
  let profile: LocalLedgerProfile
  let recentTransactions: [LedgerTransactionSummary]
  let monthlyReport: LedgerMonthlyReport?
}

nonisolated struct TodayPendingSummary: Sendable, Equatable {
  let calendarRevisionCount: Int?
  let journeyReviewCount: Int?

  var total: Int {
    (calendarRevisionCount ?? 0) + (journeyReviewCount ?? 0)
  }
}

nonisolated struct TodaySnapshot: Sendable, Equatable {
  let generatedAt: Date
  let occurrences: [CalendarOccurrenceSummary]?
  let nextTripPlan: TripPlanSummary?
  let currentJourney: JourneySnapshot?
  let journeys: [JourneySnapshot]?
  let ledger: TodayLedgerSnapshot?
  let pending: TodayPendingSummary
  let issues: Set<TodaySnapshotIssue>
}

nonisolated struct TodaySnapshotService: Sendable {
  typealias OccurrencesProvider =
    @Sendable (Date) async throws -> [CalendarOccurrenceSummary]
  typealias PlansProvider = @Sendable () async throws -> [TripPlanSummary]
  typealias JourneysProvider = @Sendable () async throws -> [JourneySnapshot]
  typealias LedgerProvider = @Sendable (Date, String) async throws -> TodayLedgerSnapshot

  private let occurrencesProvider: OccurrencesProvider
  private let plansProvider: PlansProvider
  private let journeysProvider: JourneysProvider
  private let ledgerProvider: LedgerProvider
  private let calendar: @Sendable (String) -> Calendar

  init(
    occurrences: @escaping OccurrencesProvider,
    plans: @escaping PlansProvider,
    journeys: @escaping JourneysProvider,
    ledger: @escaping LedgerProvider,
    calendar: @escaping @Sendable (String) -> Calendar = { timeZoneIdentifier in
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
      return calendar
    }
  ) {
    occurrencesProvider = occurrences
    plansProvider = plans
    journeysProvider = journeys
    ledgerProvider = ledger
    self.calendar = calendar
  }

  func snapshot(
    at referenceDate: Date,
    timeZoneIdentifier: String
  ) async -> TodaySnapshot {
    async let occurrenceResult = Self.capture {
      try await occurrencesProvider(referenceDate)
    }
    async let planResult = Self.capture {
      try await plansProvider()
    }
    async let journeyResult = Self.capture {
      try await journeysProvider()
    }
    async let ledgerResult = Self.capture {
      try await ledgerProvider(referenceDate, timeZoneIdentifier)
    }

    let results = await (occurrenceResult, planResult, journeyResult, ledgerResult)
    var issues: Set<TodaySnapshotIssue> = []

    let occurrenceValues: [CalendarOccurrenceSummary]?
    let calendarRevisionCount: Int?
    switch results.0 {
    case .success(let occurrences):
      occurrenceValues = todayOccurrences(
        from: occurrences,
        referenceDate: referenceDate,
        timeZoneIdentifier: timeZoneIdentifier
      )
      calendarRevisionCount = occurrences.filter(\.hasPendingRevision).count
    case .failure:
      occurrenceValues = nil
      calendarRevisionCount = nil
      issues.insert(.calendar)
    }

    let nextTripPlan: TripPlanSummary?
    switch results.1 {
    case .success(let plans):
      nextTripPlan =
        plans
        .filter { plan in
          plan.status == .planned
            && (plan.plannedDepartureAt.map { $0 >= referenceDate } ?? false)
        }
        .min { left, right in
          guard let leftDeparture = left.plannedDepartureAt,
            let rightDeparture = right.plannedDepartureAt
          else {
            return left.id.uuidString < right.id.uuidString
          }
          if leftDeparture == rightDeparture {
            return left.id.uuidString < right.id.uuidString
          }
          return leftDeparture < rightDeparture
        }
    case .failure:
      nextTripPlan = nil
      issues.insert(.tripPlans)
    }

    let journeyValues: [JourneySnapshot]?
    let currentJourney: JourneySnapshot?
    let journeyReviewCount: Int?
    switch results.2 {
    case .success(let journeys):
      journeyValues = journeys
      currentJourney = journeys.first { journey in
        [.recording, .paused, .finalizing, .reviewing].contains(journey.status)
      }
      journeyReviewCount =
        journeys.filter { journey in
          journey.status == .finalizing || journey.status == .reviewing
        }.count
    case .failure:
      journeyValues = nil
      currentJourney = nil
      journeyReviewCount = nil
      issues.insert(.journeys)
    }

    let ledger: TodayLedgerSnapshot?
    switch results.3 {
    case .success(let value):
      ledger = value
    case .failure:
      ledger = nil
      issues.insert(.ledger)
    }

    return TodaySnapshot(
      generatedAt: referenceDate,
      occurrences: occurrenceValues,
      nextTripPlan: nextTripPlan,
      currentJourney: currentJourney,
      journeys: journeyValues,
      ledger: ledger,
      pending: TodayPendingSummary(
        calendarRevisionCount: calendarRevisionCount,
        journeyReviewCount: journeyReviewCount
      ),
      issues: issues
    )
  }

  private func todayOccurrences(
    from occurrences: [CalendarOccurrenceSummary],
    referenceDate: Date,
    timeZoneIdentifier: String
  ) -> [CalendarOccurrenceSummary] {
    let calendar = calendar(timeZoneIdentifier)
    let start = calendar.startOfDay(for: referenceDate)
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
      return []
    }
    let todayKey = Self.localDate(start, calendar: calendar)
    return
      occurrences
      .filter { occurrence in
        guard occurrence.sourceState == .active || occurrence.sourceState == .missing else {
          return false
        }
        if occurrence.isAllDay {
          return occurrence.localStartDate <= todayKey
            && occurrence.localEndDateExclusive > todayKey
        }
        return occurrence.startsAt < end && occurrence.endsAt > start
      }
      .sorted { left, right in
        if left.isAllDay != right.isAllDay { return left.isAllDay }
        if left.startsAt != right.startsAt { return left.startsAt < right.startsAt }
        return left.id.uuidString < right.id.uuidString
      }
  }

  private static func localDate(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  private static func capture<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async -> Captured<Value> {
    do {
      return .success(try await operation())
    } catch {
      return .failure
    }
  }
}

private nonisolated enum Captured<Value: Sendable>: Sendable {
  case success(Value)
  case failure
}
