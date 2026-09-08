import Foundation

nonisolated struct CalendarImportService: Sendable {
  private let ownerID: UUID
  private let service: any CalendarService
  private let repository: any CalendarRepository
  private let now: @Sendable () -> Date
  private let calendar: @Sendable () -> Calendar

  init(
    ownerID: UUID,
    service: any CalendarService,
    repository: any CalendarRepository,
    now: @escaping @Sendable () -> Date = Date.init,
    calendar: @escaping @Sendable () -> Calendar = { .current }
  ) {
    self.ownerID = ownerID
    self.service = service
    self.repository = repository
    self.now = now
    self.calendar = calendar
  }

  func authorizationState() async -> CalendarAuthorizationState {
    await service.authorizationState()
  }

  func requestFullAccess() async throws -> CalendarAuthorizationState {
    let state = try await service.requestFullAccess()
    if state == .fullAccess {
      _ = try await refreshSources()
    } else {
      try await repository.markSourcesUnavailable(ownerID: ownerID, changedAt: now())
    }
    return state
  }

  func refreshSources() async throws -> [CalendarSourceSummary] {
    let state = await service.authorizationState()
    guard state == .fullAccess else {
      try await repository.markSourcesUnavailable(ownerID: ownerID, changedAt: now())
      return try await repository.sources(ownerID: ownerID)
    }
    let snapshots = try await service.availableSources()
    return try await repository.reconcileSources(
      ownerID: ownerID,
      snapshots: snapshots,
      observedAt: now()
    )
  }

  func setSourceSelection(sourceID: UUID, isSelected: Bool) async throws {
    _ = try await repository.setSourceSelection(
      ownerID: ownerID,
      sourceID: sourceID,
      isSelected: isSelected,
      changedAt: now()
    )
  }

  func scan() async throws -> CalendarScanResult? {
    let state = await service.authorizationState()
    guard state == .fullAccess else {
      try await repository.markSourcesUnavailable(ownerID: ownerID, changedAt: now())
      throw Self.authorizationError(state)
    }

    _ = try await refreshSources()
    let selectedSources = try await repository.selectedSources(ownerID: ownerID)
    guard !selectedSources.isEmpty else { return nil }
    let startedAt = now()
    let window = try CalendarScanWindow(referenceDate: startedAt, calendar: calendar())
    let scanID = UUID()
    try await repository.beginScan(
      ownerID: ownerID,
      scanID: scanID,
      window: window,
      startedAt: startedAt
    )

    do {
      let occurrences = try await service.occurrences(
        selectedSourceIdentityHMACs: Set(selectedSources.map(\.externalIdentityHMAC)),
        matchingFrom: window.matchingStart,
        through: window.matchingEnd
      )
      return try await repository.commitScan(
        CalendarScanCommit(
          scanID: scanID,
          ownerID: ownerID,
          window: window,
          occurrences: occurrences,
          completedAt: now()
        )
      )
    } catch is CancellationError {
      try? await repository.failScan(
        ownerID: ownerID,
        scanID: scanID,
        safeErrorCode: "cancelled",
        failedAt: now()
      )
      throw CancellationError()
    } catch {
      try? await repository.failScan(
        ownerID: ownerID,
        scanID: scanID,
        safeErrorCode: Self.safeErrorCode(error),
        failedAt: now()
      )
      throw error
    }
  }

  func sources() async throws -> [CalendarSourceSummary] {
    try await repository.sources(ownerID: ownerID)
  }

  func visibleOccurrences(referenceDate: Date? = nil) async throws
    -> [CalendarOccurrenceSummary]
  {
    let date = referenceDate ?? now()
    let window = try CalendarScanWindow(referenceDate: date, calendar: calendar())
    return try await repository.occurrences(
      ownerID: ownerID,
      from: window.displayStart,
      through: window.displayEnd
    )
  }

  func pendingRevisions(occurrenceID: UUID) async throws
    -> [CalendarOccurrenceRevisionSummary]
  {
    try await repository.pendingRevisions(
      ownerID: ownerID,
      occurrenceID: occurrenceID
    )
  }

  func ignorePendingRevisions(
    occurrenceID: UUID,
    throughSourceVersion: Int
  ) async throws {
    try await repository.ignorePendingRevisions(
      ownerID: ownerID,
      command: IgnoreCalendarRevisionsCommand(
        occurrenceID: occurrenceID,
        throughSourceVersion: throughSourceVersion,
        resolvedAt: now()
      )
    )
  }

  func eventStoreChanges() async -> AsyncStream<Void> {
    await service.eventStoreChanges()
  }

  private static func authorizationError(
    _ state: CalendarAuthorizationState
  ) -> CalendarDomainError {
    switch state {
    case .restricted:
      .calendarPermissionRestricted
    case .writeOnly:
      .calendarWriteOnlyAccess
    case .notDetermined, .denied:
      .calendarPermissionDenied
    case .fullAccess:
      .eventQueryFailed
    }
  }

  private static func safeErrorCode(_ error: Error) -> String {
    switch error {
    case CalendarDomainError.calendarPermissionDenied:
      "permission_denied"
    case CalendarDomainError.calendarPermissionRestricted:
      "permission_restricted"
    case CalendarDomainError.calendarWriteOnlyAccess:
      "permission_write_only"
    case CalendarDomainError.identityKeyUnavailable:
      "identity_key_unavailable"
    case CalendarDomainError.selectedSourceUnavailable:
      "selected_source_unavailable"
    case CalendarDomainError.invalidScanWindow:
      "invalid_window"
    default:
      "event_query_failed"
    }
  }
}
