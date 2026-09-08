import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("系统日历导入")
struct CalendarImportTests {
  @Test("新发现的日历默认不选择且暂时不可用不会被当作删除")
  func sourceSelectionIsExplicitAndSurvivesTemporaryUnavailability() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeIdentity(database)
      let repository = GRDBCalendarRepository(database: database)
      let source = makeSource(byte: 0x11, title: "工作")

      let discovered = try await repository.reconcileSources(
        ownerID: identity.profileID,
        snapshots: [source],
        observedAt: date(1_000)
      )
      let sourceID = try #require(discovered.first?.id)
      #expect(discovered.first?.accessState == .unselected)
      #expect(discovered.first?.isSelected == false)
      #expect(try await repository.selectedSources(ownerID: identity.profileID).isEmpty)

      let selected = try await repository.setSourceSelection(
        ownerID: identity.profileID,
        sourceID: sourceID,
        isSelected: true,
        changedAt: date(1_001)
      )
      #expect(selected.accessState == .selected)
      #expect(selected.isSelected)

      let unavailable = try await repository.reconcileSources(
        ownerID: identity.profileID,
        snapshots: [],
        observedAt: date(1_002)
      )
      #expect(unavailable.first?.accessState == .unavailable)
      #expect(unavailable.first?.isSelected == true)
      #expect(try await repository.selectedSources(ownerID: identity.profileID).isEmpty)

      let restored = try await repository.reconcileSources(
        ownerID: identity.profileID,
        snapshots: [source],
        observedAt: date(1_003)
      )
      #expect(restored.first?.id == sourceID)
      #expect(restored.first?.accessState == .selected)
      #expect(restored.first?.isSelected == true)
    }
  }

  @Test("成功扫描原子写入并区分变更、移出窗口、缺失和取消")
  func successfulScansTrackOccurrenceLifecycle() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeIdentity(database)
      let repository = GRDBCalendarRepository(database: database)
      let source = makeSource(byte: 0x21, title: "个人")
      let sourceID = try #require(
        try await repository.reconcileSources(
          ownerID: identity.profileID,
          snapshots: [source],
          observedAt: date(900)
        ).first?.id
      )
      _ = try await repository.setSourceSelection(
        ownerID: identity.profileID,
        sourceID: sourceID,
        isSelected: true,
        changedAt: date(901)
      )
      let window = makeWindow()
      let first = makeOccurrence(sourceByte: 0x21, fingerprintByte: 0x31)

      let firstResult = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [first],
        at: 1_000
      )
      #expect(firstResult.importedCount == 1)
      #expect(firstResult.activeCount == 1)
      var visible = try await repository.occurrences(
        ownerID: identity.profileID,
        from: window.displayStart,
        through: window.displayEnd
      )
      #expect(visible.count == 1)
      #expect(visible.first?.sourceVersion == 1)
      #expect(visible.first?.sourceState == .active)
      #expect(visible.first?.isAllDay == true)
      #expect(visible.first?.timeZoneIdentifier == "Asia/Shanghai")

      let changed = makeOccurrence(
        sourceByte: 0x21,
        fingerprintByte: 0x32,
        title: "调整后的会议",
        location: "新地点"
      )
      let changedResult = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [changed],
        at: 1_010
      )
      #expect(changedResult.changedCount == 1)
      visible = try await repository.occurrences(
        ownerID: identity.profileID,
        from: window.displayStart,
        through: window.displayEnd
      )
      #expect(visible.first?.sourceVersion == 2)
      #expect(visible.first?.title == "调整后的会议")
      #expect(visible.first?.hasPendingRevision == true)

      let movedOutside = makeOccurrence(
        sourceByte: 0x21,
        fingerprintByte: 0x33,
        startsAt: date(2_500),
        endsAt: date(2_600),
        title: "移出展示窗口"
      )
      let outsideResult = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [movedOutside],
        at: 1_020
      )
      #expect(outsideResult.outOfWindowCount == 1)
      #expect(
        try await repository.occurrences(
          ownerID: identity.profileID,
          from: window.displayStart,
          through: window.displayEnd
        ).isEmpty
      )

      let backInside = makeOccurrence(sourceByte: 0x21, fingerprintByte: 0x34)
      _ = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [backInside],
        at: 1_030
      )
      _ = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [],
        at: 1_040
      )
      visible = try await repository.occurrences(
        ownerID: identity.profileID,
        from: window.displayStart,
        through: window.displayEnd
      )
      #expect(visible.first?.sourceState == .missing)

      let cancelled = makeOccurrence(
        sourceByte: 0x21,
        fingerprintByte: 0x35,
        isCancelled: true
      )
      let cancelledResult = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [cancelled],
        at: 1_050
      )
      #expect(cancelledResult.cancelledCount == 1)
      visible = try await repository.occurrences(
        ownerID: identity.profileID,
        from: window.displayStart,
        through: window.displayEnd
      )
      #expect(visible.first?.sourceState == .cancelled)

      let databaseState = try await database.pool.read { database in
        let revisionCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM calendar_occurrence_revisions"
        )
        let deletedCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM calendar_occurrences WHERE source_state = 'source_deleted'"
        )
        return (revisionCount, deletedCount)
      }
      #expect(databaseState.0 == 4)
      #expect(databaseState.1 == 0)
    }
  }

  @Test("扫描中出现未知来源时整次提交回滚")
  func invalidScanCommitRollsBackAtomically() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeIdentity(database)
      let repository = GRDBCalendarRepository(database: database)
      let source = makeSource(byte: 0x41, title: "已选")
      let sourceID = try #require(
        try await repository.reconcileSources(
          ownerID: identity.profileID,
          snapshots: [source],
          observedAt: date(900)
        ).first?.id
      )
      _ = try await repository.setSourceSelection(
        ownerID: identity.profileID,
        sourceID: sourceID,
        isSelected: true,
        changedAt: date(901)
      )
      let window = makeWindow()
      let scanID = UUID()
      try await repository.beginScan(
        ownerID: identity.profileID,
        scanID: scanID,
        window: window,
        startedAt: date(1_000)
      )

      do {
        _ = try await repository.commitScan(
          CalendarScanCommit(
            scanID: scanID,
            ownerID: identity.profileID,
            window: window,
            occurrences: [
              makeOccurrence(sourceByte: 0x41, occurrenceByte: 0x51),
              makeOccurrence(sourceByte: 0x7f, occurrenceByte: 0x52),
            ],
            completedAt: date(1_001)
          )
        )
        Issue.record("未知来源必须拒绝整次扫描")
      } catch let error as CalendarDomainError {
        #expect(error == .selectedSourceUnavailable)
      }

      let state = try await database.pool.read { database in
        let occurrenceCount = try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM calendar_occurrences"
        )
        let scanStatus = try String.fetchOne(
          database,
          sql: "SELECT status FROM calendar_scans WHERE id = ?",
          arguments: [scanID.uuidString.lowercased()]
        )
        return (occurrenceCount, scanStatus)
      }
      #expect(state.0 == 0)
      #expect(state.1 == "running")
    }
  }

  @Test("权限失效只将来源标记不可用且不篡改事件状态")
  func permissionLossPreservesOccurrenceState() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeIdentity(database)
      let repository = GRDBCalendarRepository(database: database)
      let source = makeSource(byte: 0x61, title: "系统日历")
      let sourceID = try #require(
        try await repository.reconcileSources(
          ownerID: identity.profileID,
          snapshots: [source],
          observedAt: date(900)
        ).first?.id
      )
      _ = try await repository.setSourceSelection(
        ownerID: identity.profileID,
        sourceID: sourceID,
        isSelected: true,
        changedAt: date(901)
      )
      _ = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: makeWindow(),
        occurrences: [makeOccurrence(sourceByte: 0x61)],
        at: 1_000
      )
      let importService = CalendarImportService(
        ownerID: identity.profileID,
        service: FixedCalendarService(state: .denied),
        repository: repository,
        now: { date(1_100) },
        calendar: { Calendar(identifier: .gregorian) }
      )

      let sources = try await importService.refreshSources()
      #expect(sources.first?.accessState == .unavailable)
      let rawState = try await database.pool.read { database in
        try String.fetchOne(database, sql: "SELECT source_state FROM calendar_occurrences")
      }
      #expect(rawState == "active")
    }
  }

  @Test("忽略所见来源变化不吞掉更新版本且解决状态原子持久化")
  func ignoringSeenRevisionsPreservesNewerPendingRevision() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try makeIdentity(database)
      let repository = GRDBCalendarRepository(database: database)
      let source = makeSource(byte: 0x81, title: "变化日历")
      let sourceID = try #require(
        try await repository.reconcileSources(
          ownerID: identity.profileID,
          snapshots: [source],
          observedAt: date(900)
        ).first?.id
      )
      _ = try await repository.setSourceSelection(
        ownerID: identity.profileID,
        sourceID: sourceID,
        isSelected: true,
        changedAt: date(901)
      )
      let window = makeWindow()
      _ = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [makeOccurrence(sourceByte: 0x81, fingerprintByte: 0x82)],
        at: 1_000
      )
      _ = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [
          makeOccurrence(
            sourceByte: 0x81,
            fingerprintByte: 0x83,
            title: "第一次变化"
          )
        ],
        at: 1_010
      )
      _ = try await commit(
        repository: repository,
        ownerID: identity.profileID,
        window: window,
        occurrences: [
          makeOccurrence(
            sourceByte: 0x81,
            fingerprintByte: 0x84,
            title: "第二次变化"
          )
        ],
        at: 1_020
      )
      let occurrence = try #require(
        try await repository.occurrences(
          ownerID: identity.profileID,
          from: window.displayStart,
          through: window.displayEnd
        ).first
      )
      let initialPending = try await repository.pendingRevisions(
        ownerID: identity.profileID,
        occurrenceID: occurrence.id
      )
      #expect(initialPending.map(\.toVersion) == [2, 3])

      await #expect(throws: CalendarDomainError.invalidResolutionTime) {
        try await repository.ignorePendingRevisions(
          ownerID: identity.profileID,
          command: IgnoreCalendarRevisionsCommand(
            occurrenceID: occurrence.id,
            throughSourceVersion: 2,
            resolvedAt: date(900)
          )
        )
      }
      try await repository.ignorePendingRevisions(
        ownerID: identity.profileID,
        command: IgnoreCalendarRevisionsCommand(
          occurrenceID: occurrence.id,
          throughSourceVersion: 2,
          resolvedAt: date(2_000)
        )
      )

      let remaining = try await repository.pendingRevisions(
        ownerID: identity.profileID,
        occurrenceID: occurrence.id
      )
      #expect(remaining.map(\.toVersion) == [3])
      let rawStates = try await database.pool.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT to_version, resolution_state, resolved_at
            FROM calendar_occurrence_revisions
            WHERE calendar_occurrence_id = ?
            ORDER BY to_version
            """,
          arguments: [occurrence.id.uuidString.lowercased()]
        )
      }
      #expect(rawStates[0]["resolution_state"] as String == "ignored")
      #expect(rawStates[0]["resolved_at"] as Double == 2_000)
      #expect(rawStates[1]["resolution_state"] as String == "pending")
      #expect(rawStates[1]["resolved_at"] as Double? == nil)

      await #expect(throws: CalendarDomainError.revisionNotFound) {
        try await repository.ignorePendingRevisions(
          ownerID: identity.profileID,
          command: IgnoreCalendarRevisionsCommand(
            occurrenceID: occurrence.id,
            throughSourceVersion: 2,
            resolvedAt: date(2_100)
          )
        )
      }
      await #expect(throws: CalendarDomainError.staleOccurrenceVersion) {
        try await repository.ignorePendingRevisions(
          ownerID: identity.profileID,
          command: IgnoreCalendarRevisionsCommand(
            occurrenceID: occurrence.id,
            throughSourceVersion: 4,
            resolvedAt: date(2_100)
          )
        )
      }
    }
  }
}

private nonisolated func makeIdentity(_ database: AppDatabase) throws -> LocalLedgerIdentity {
  try LocalLedgerBootstrap(database: database).initializeIfNeeded(
    suggestedCurrencyCode: .cny,
    now: date(100)
  )
}

private nonisolated func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

private nonisolated func hmac(_ byte: UInt8) -> Data {
  Data(repeating: byte, count: 32)
}

private nonisolated func makeSource(
  byte: UInt8,
  title: String
) -> SystemCalendarSourceSnapshot {
  SystemCalendarSourceSnapshot(
    externalIdentityHMAC: hmac(byte),
    title: title,
    kind: .caldav,
    isSubscribed: false,
    allowsContentModifications: true
  )
}

private nonisolated func makeWindow() -> CalendarScanWindow {
  CalendarScanWindow(
    displayStart: date(1_000),
    displayEnd: date(2_000),
    matchingStart: date(500),
    matchingEnd: date(3_000)
  )
}

private nonisolated func makeOccurrence(
  sourceByte: UInt8,
  seriesByte: UInt8 = 0x71,
  occurrenceByte: UInt8 = 0x72,
  matchByte: UInt8 = 0x73,
  fingerprintByte: UInt8 = 0x74,
  startsAt: Date = date(1_200),
  endsAt: Date = date(1_300),
  title: String = "会议",
  location: String = "上海",
  isCancelled: Bool = false
) -> SystemCalendarOccurrenceSnapshot {
  SystemCalendarOccurrenceSnapshot(
    sourceExternalIdentityHMAC: hmac(sourceByte),
    seriesExternalIdentityHMAC: hmac(seriesByte),
    occurrenceExternalIdentityHMAC: hmac(occurrenceByte),
    matchKeyHMAC: hmac(matchByte),
    sourceFingerprint: hmac(fingerprintByte),
    hasRecurrence: true,
    isCancelled: isCancelled,
    isAllDay: true,
    startsAt: startsAt,
    endsAt: endsAt,
    localStartDate: "2026-08-10",
    localEndDateExclusive: "2026-08-11",
    timeZoneIdentifier: "Asia/Shanghai",
    title: title,
    locationText: location
  )
}

private nonisolated func commit(
  repository: GRDBCalendarRepository,
  ownerID: UUID,
  window: CalendarScanWindow,
  occurrences: [SystemCalendarOccurrenceSnapshot],
  at timestamp: TimeInterval
) async throws -> CalendarScanResult {
  let scanID = UUID()
  try await repository.beginScan(
    ownerID: ownerID,
    scanID: scanID,
    window: window,
    startedAt: date(timestamp)
  )
  return try await repository.commitScan(
    CalendarScanCommit(
      scanID: scanID,
      ownerID: ownerID,
      window: window,
      occurrences: occurrences,
      completedAt: date(timestamp + 1)
    )
  )
}

private actor FixedCalendarService: CalendarService {
  private let state: CalendarAuthorizationState

  init(state: CalendarAuthorizationState) {
    self.state = state
  }

  func authorizationState() async -> CalendarAuthorizationState { state }

  func requestFullAccess() async throws -> CalendarAuthorizationState { state }

  func availableSources() async throws -> [SystemCalendarSourceSnapshot] { [] }

  func occurrences(
    selectedSourceIdentityHMACs: Set<Data>,
    matchingFrom startDate: Date,
    through endDate: Date
  ) async throws -> [SystemCalendarOccurrenceSnapshot] {
    []
  }

  func eventStoreChanges() async -> AsyncStream<Void> {
    AsyncStream { continuation in continuation.finish() }
  }
}
