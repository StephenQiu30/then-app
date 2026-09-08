import Foundation

nonisolated enum CalendarAuthorizationState: Sendable, Equatable {
  case notDetermined
  case fullAccess
  case denied
  case restricted
  case writeOnly
}

nonisolated enum CalendarSourceKind: String, Sendable, Codable {
  case local
  case exchange
  case caldav
  case mobileme
  case subscribed
  case birthdays
  case unknown
}

nonisolated enum CalendarSourceAccessState: String, Sendable, Codable {
  case selected
  case unselected
  case unavailable
}

nonisolated enum CalendarOccurrenceSourceState: String, Sendable, Codable {
  case active
  case missing
  case sourceDeleted = "source_deleted"
  case outOfWindow = "out_of_window"
  case cancelled
  case ambiguous
}

nonisolated struct SystemCalendarSourceSnapshot: Sendable, Equatable {
  let externalIdentityHMAC: Data
  let title: String
  let kind: CalendarSourceKind
  let isSubscribed: Bool
  let allowsContentModifications: Bool
}

nonisolated struct SystemCalendarOccurrenceSnapshot: Sendable, Equatable {
  let sourceExternalIdentityHMAC: Data
  let seriesExternalIdentityHMAC: Data
  let occurrenceExternalIdentityHMAC: Data
  let matchKeyHMAC: Data
  let sourceFingerprint: Data
  let hasRecurrence: Bool
  let isCancelled: Bool
  let isAllDay: Bool
  let startsAt: Date
  let endsAt: Date
  let localStartDate: String
  let localEndDateExclusive: String
  let timeZoneIdentifier: String
  let title: String?
  let locationText: String?
}

nonisolated struct CalendarScanWindow: Sendable, Equatable {
  let displayStart: Date
  let displayEnd: Date
  let matchingStart: Date
  let matchingEnd: Date

  init(referenceDate: Date, calendar: Calendar = .current) throws {
    guard let displayStart = calendar.date(byAdding: .day, value: -30, to: referenceDate),
      let displayEnd = calendar.date(byAdding: .day, value: 90, to: referenceDate),
      let matchingStart = calendar.date(byAdding: .day, value: -60, to: referenceDate),
      let matchingEnd = calendar.date(byAdding: .day, value: 180, to: referenceDate)
    else {
      throw CalendarDomainError.invalidScanWindow
    }
    self.init(
      displayStart: displayStart,
      displayEnd: displayEnd,
      matchingStart: matchingStart,
      matchingEnd: matchingEnd
    )
  }

  init(displayStart: Date, displayEnd: Date, matchingStart: Date, matchingEnd: Date) {
    self.displayStart = displayStart
    self.displayEnd = displayEnd
    self.matchingStart = matchingStart
    self.matchingEnd = matchingEnd
  }

  func containsInDisplayWindow(startsAt: Date, endsAt: Date) -> Bool {
    startsAt < displayEnd && endsAt > displayStart
  }
}

nonisolated struct CalendarSourceSummary: Identifiable, Sendable, Equatable {
  let id: UUID
  let title: String
  let kind: CalendarSourceKind
  let accessState: CalendarSourceAccessState
  let isSelected: Bool
  let isSubscribed: Bool
  let allowsContentModifications: Bool
  let lastSuccessfulScanAt: Date?

  var isAvailable: Bool { accessState != .unavailable }
}

nonisolated struct SelectedCalendarSource: Sendable, Equatable {
  let id: UUID
  let externalIdentityHMAC: Data
}

nonisolated struct CalendarOccurrenceSummary: Identifiable, Sendable, Equatable {
  let id: UUID
  let sourceID: UUID
  let sourceTitle: String
  let sourceVersion: Int
  let sourceState: CalendarOccurrenceSourceState
  let isAllDay: Bool
  let startsAt: Date
  let endsAt: Date
  let localStartDate: String
  let localEndDateExclusive: String
  let timeZoneIdentifier: String
  let title: String?
  let locationText: String?
  let hasPendingRevision: Bool
  let linkedPlanCount: Int
}

nonisolated enum CalendarRevisionResolutionState: String, Sendable, Codable {
  case pending
  case accepted
  case ignored
}

nonisolated struct CalendarOccurrenceRevisionSummary: Identifiable, Sendable, Equatable {
  let id: UUID
  let occurrenceID: UUID
  let fromVersion: Int
  let toVersion: Int
  let oldStartsAt: Date
  let newStartsAt: Date
  let oldEndsAt: Date
  let newEndsAt: Date
  let oldTimeZoneIdentifier: String
  let newTimeZoneIdentifier: String
  let oldTitle: String?
  let newTitle: String?
  let oldLocationText: String?
  let newLocationText: String?
  let detectedAt: Date
  let resolutionState: CalendarRevisionResolutionState
  let resolvedAt: Date?
}

nonisolated struct IgnoreCalendarRevisionsCommand: Sendable, Equatable {
  let occurrenceID: UUID
  let throughSourceVersion: Int
  let resolvedAt: Date
}

nonisolated struct CalendarScanCommit: Sendable, Equatable {
  let scanID: UUID
  let ownerID: UUID
  let window: CalendarScanWindow
  let occurrences: [SystemCalendarOccurrenceSnapshot]
  let completedAt: Date
}

nonisolated struct CalendarScanResult: Sendable, Equatable {
  let scanID: UUID
  let importedCount: Int
  let activeCount: Int
  let outOfWindowCount: Int
  let cancelledCount: Int
  let changedCount: Int
}

nonisolated enum CalendarDomainError: Error, Sendable, Equatable {
  case invalidScanWindow
  case calendarPermissionDenied
  case calendarPermissionRestricted
  case calendarWriteOnlyAccess
  case identityKeyUnavailable
  case selectedSourceUnavailable
  case eventQueryFailed
  case corruptedStoredCalendar
  case revisionNotFound
  case staleOccurrenceVersion
  case invalidResolutionTime
}

nonisolated protocol CalendarService: Sendable {
  func authorizationState() async -> CalendarAuthorizationState
  func requestFullAccess() async throws -> CalendarAuthorizationState
  func availableSources() async throws -> [SystemCalendarSourceSnapshot]
  func occurrences(
    selectedSourceIdentityHMACs: Set<Data>,
    matchingFrom startDate: Date,
    through endDate: Date
  ) async throws -> [SystemCalendarOccurrenceSnapshot]
  func eventStoreChanges() async -> AsyncStream<Void>
}

nonisolated protocol CalendarRepository: Sendable {
  func reconcileSources(
    ownerID: UUID,
    snapshots: [SystemCalendarSourceSnapshot],
    observedAt: Date
  ) async throws -> [CalendarSourceSummary]

  func markSourcesUnavailable(ownerID: UUID, changedAt: Date) async throws

  func setSourceSelection(
    ownerID: UUID,
    sourceID: UUID,
    isSelected: Bool,
    changedAt: Date
  ) async throws -> CalendarSourceSummary

  func sources(ownerID: UUID) async throws -> [CalendarSourceSummary]
  func selectedSources(ownerID: UUID) async throws -> [SelectedCalendarSource]

  func beginScan(
    ownerID: UUID,
    scanID: UUID,
    window: CalendarScanWindow,
    startedAt: Date
  ) async throws

  func failScan(
    ownerID: UUID,
    scanID: UUID,
    safeErrorCode: String,
    failedAt: Date
  ) async throws

  func commitScan(_ commit: CalendarScanCommit) async throws -> CalendarScanResult

  func occurrences(
    ownerID: UUID,
    from startDate: Date,
    through endDate: Date
  ) async throws -> [CalendarOccurrenceSummary]

  func pendingRevisions(
    ownerID: UUID,
    occurrenceID: UUID
  ) async throws -> [CalendarOccurrenceRevisionSummary]

  func ignorePendingRevisions(
    ownerID: UUID,
    command: IgnoreCalendarRevisionsCommand
  ) async throws
}
