import Foundation
import Testing

@testable import ThenApp

@Suite("今天只读快照")
struct TodaySnapshotTests {
  @Test("按设备自然日筛选全天与跨日事件并选择最早待出发计划")
  func composesNaturalDayAndNextDeparture() async throws {
    let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let referenceDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12))
    )
    let startOfDay = calendar.startOfDay(for: referenceDate)
    let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: startOfDay))
    let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: startOfDay))

    let todayTimed = occurrence(
      byte: 0x11,
      startsAt: startOfDay.addingTimeInterval(3_600),
      endsAt: startOfDay.addingTimeInterval(7_200)
    )
    let crossingMidnight = occurrence(
      byte: 0x12,
      startsAt: previousDay.addingTimeInterval(23 * 3_600),
      endsAt: startOfDay.addingTimeInterval(1_800),
      pending: true
    )
    let allDay = occurrence(
      byte: 0x13,
      startsAt: previousDay,
      endsAt: nextDay,
      isAllDay: true,
      localStartDate: "2026-08-09",
      localEndDateExclusive: "2026-08-11"
    )
    let endedAtBoundary = occurrence(
      byte: 0x14,
      startsAt: previousDay,
      endsAt: startOfDay
    )
    let cancelled = occurrence(
      byte: 0x15,
      startsAt: startOfDay,
      endsAt: nextDay,
      state: .cancelled
    )
    let earlyPlan = plan(
      byte: 0x21,
      departure: referenceDate.addingTimeInterval(1_800),
      status: .planned
    )
    let laterPlan = plan(
      byte: 0x22,
      departure: referenceDate.addingTimeInterval(3_600),
      status: .planned
    )
    let pastPlan = plan(
      byte: 0x23,
      departure: referenceDate.addingTimeInterval(-60),
      status: .planned
    )
    let currentJourney = journey(byte: 0x31, status: .paused)
    let reviewingJourney = journey(byte: 0x32, status: .reviewing)

    let service = TodaySnapshotService(
      occurrences: { _ in
        [todayTimed, crossingMidnight, allDay, endedAtBoundary, cancelled]
      },
      plans: { [laterPlan, pastPlan, earlyPlan] },
      journeys: { [currentJourney, reviewingJourney] },
      ledger: { _, _ in ledgerSnapshot() }
    )
    let snapshot = await service.snapshot(
      at: referenceDate,
      timeZoneIdentifier: "Asia/Shanghai"
    )

    #expect(snapshot.issues.isEmpty)
    #expect(snapshot.occurrences?.map(\.id) == [allDay.id, crossingMidnight.id, todayTimed.id])
    #expect(snapshot.nextTripPlan?.id == earlyPlan.id)
    #expect(snapshot.currentJourney?.id == currentJourney.id)
    #expect(snapshot.pending.calendarRevisionCount == 1)
    #expect(snapshot.pending.journeyReviewCount == 1)
    #expect(snapshot.pending.total == 2)
  }

  @Test("单个读取器失败不清空其他成功区块且未确认本币不伪造报表")
  func isolatesSourceFailures() async {
    let referenceDate = Date(timeIntervalSince1970: 1_786_377_600)
    let plan = plan(
      byte: 0x41,
      departure: referenceDate.addingTimeInterval(600),
      status: .planned
    )
    let service = TodaySnapshotService(
      occurrences: { _ in throw TodaySnapshotFixtureError.unavailable },
      plans: { [plan] },
      journeys: { [] },
      ledger: { _, _ in
        TodayLedgerSnapshot(
          profile: LocalLedgerProfile(
            id: fixtureUUID(0x50),
            baseCurrencyCode: .cny,
            baseCurrencyState: .suggested
          ),
          recentTransactions: [],
          monthlyReport: nil
        )
      }
    )
    let snapshot = await service.snapshot(
      at: referenceDate,
      timeZoneIdentifier: "Asia/Shanghai"
    )

    #expect(snapshot.issues == [.calendar])
    #expect(snapshot.occurrences == nil)
    #expect(snapshot.nextTripPlan?.id == plan.id)
    #expect(snapshot.journeys == [])
    #expect(snapshot.ledger?.monthlyReport == nil)
    #expect(snapshot.pending.calendarRevisionCount == nil)
    #expect(snapshot.pending.journeyReviewCount == 0)
  }

  private func occurrence(
    byte: UInt8,
    startsAt: Date,
    endsAt: Date,
    isAllDay: Bool = false,
    localStartDate: String = "2026-08-10",
    localEndDateExclusive: String = "2026-08-11",
    state: CalendarOccurrenceSourceState = .active,
    pending: Bool = false
  ) -> CalendarOccurrenceSummary {
    CalendarOccurrenceSummary(
      id: fixtureUUID(byte),
      sourceID: fixtureUUID(byte &+ 0x60),
      sourceTitle: "合成日历",
      sourceVersion: 1,
      sourceState: state,
      isAllDay: isAllDay,
      startsAt: startsAt,
      endsAt: endsAt,
      localStartDate: localStartDate,
      localEndDateExclusive: localEndDateExclusive,
      timeZoneIdentifier: "Asia/Shanghai",
      title: "合成事件",
      locationText: nil,
      hasPendingRevision: pending,
      linkedPlanCount: 0
    )
  }

  private func plan(
    byte: UInt8,
    departure: Date,
    status: TripPlanStatus
  ) -> TripPlanSummary {
    TripPlanSummary(
      id: fixtureUUID(byte),
      planVersion: 1,
      displayName: "合成计划",
      destination: ConfirmedLocation(
        id: fixtureUUID(byte &+ 0x20),
        name: "目的地",
        address: nil,
        latitude: nil,
        longitude: nil,
        source: .manual,
        horizontalAccuracy: nil
      ),
      origin: nil,
      transportMode: .walking,
      targetArrivalAt: departure.addingTimeInterval(1_800),
      plannedDepartureAt: departure,
      timezoneIdentifier: "Asia/Shanghai",
      preparationBufferSeconds: 600,
      status: status,
      routeEstimate: nil,
      reminderStatus: .disabled,
      reminderFireAt: nil,
      linkedOccurrenceID: nil,
      sourceOccurrenceVersion: nil,
      displayNameValueSource: .user,
      destinationValueSource: .user,
      targetArrivalValueSource: .user,
      departureValueSource: .user
    )
  }

  private func journey(byte: UInt8, status: JourneyStatus) -> JourneySnapshot {
    JourneySnapshot(
      id: fixtureUUID(byte),
      tripPlanID: nil,
      recordingDeviceID: fixtureUUID(byte &+ 0x40),
      status: status,
      transportMode: .walking,
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: status == .reviewing ? Date(timeIntervalSince1970: 200) : nil,
      distanceMeters: nil,
      durationSeconds: nil,
      captureCompleteness: .none,
      rawTrackState: status == .reviewing ? .awaitingSummaryConfirmation : .collecting,
      finalSequence: nil,
      pointCount: nil,
      terminationReason: nil,
      pauseReason: nil
    )
  }

  private nonisolated func ledgerSnapshot() -> TodayLedgerSnapshot {
    TodayLedgerSnapshot(
      profile: LocalLedgerProfile(
        id: fixtureUUID(0x70),
        baseCurrencyCode: .cny,
        baseCurrencyState: .confirmed
      ),
      recentTransactions: [],
      monthlyReport: nil
    )
  }
}

private nonisolated enum TodaySnapshotFixtureError: Error {
  case unavailable
}

private nonisolated func fixtureUUID(_ byte: UInt8) -> UUID {
  UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}
