import Foundation

nonisolated protocol LedgerQuerying: Sendable {
  func localProfile(ownerID: UUID) async throws -> LocalLedgerProfile
  func recentTransactions(ownerID: UUID, limit: Int) async throws -> [LedgerTransactionSummary]
  func filteredTransactions(
    ownerID: UUID,
    filter: LedgerTransactionFilter,
    limit: Int
  ) async throws -> [LedgerTransactionSummary]
  func monthlyReport(
    ownerID: UUID,
    containing date: Date,
    timeZoneIdentifier: String,
    filter: LedgerTransactionFilter
  ) async throws -> LedgerMonthlyReport
  func accountSummaries(ownerID: UUID) async throws -> [LedgerAccountSummary]
}

nonisolated struct LedgerQueryService: LedgerQuerying, Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func localProfile(ownerID: UUID) async throws -> LocalLedgerProfile {
    try await repository.localProfile(ownerID: ownerID)
  }

  func recentTransactions(
    ownerID: UUID,
    limit: Int = 20
  ) async throws -> [LedgerTransactionSummary] {
    try await repository.recentTransactions(
      ownerID: ownerID,
      limit: max(1, min(limit, 100))
    )
  }

  func searchTransactions(
    ownerID: UUID,
    searchText: String,
    amountMinorUnits: Int64?,
    limit: Int = 100
  ) async throws -> [LedgerTransactionSummary] {
    let normalizedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty else {
      return try await recentTransactions(ownerID: ownerID, limit: limit)
    }
    return try await repository.searchTransactions(
      ownerID: ownerID,
      searchText: normalizedText,
      amountMinorUnits: amountMinorUnits,
      limit: max(1, min(limit, 100))
    )
  }

  func filteredTransactions(
    ownerID: UUID,
    filter: LedgerTransactionFilter,
    limit: Int = 100
  ) async throws -> [LedgerTransactionSummary] {
    try await repository.filteredTransactions(
      ownerID: ownerID,
      filter: filter,
      limit: max(1, min(limit, 100))
    )
  }

  func monthlyReport(
    ownerID: UUID,
    containing date: Date,
    timeZoneIdentifier: String,
    filter: LedgerTransactionFilter = LedgerTransactionFilter()
  ) async throws -> LedgerMonthlyReport {
    try await repository.monthlyReport(
      ownerID: ownerID,
      month: LedgerMonth(
        containing: date,
        timeZoneIdentifier: timeZoneIdentifier
      ),
      filter: filter
    )
  }

  func accountSummaries(ownerID: UUID) async throws -> [LedgerAccountSummary] {
    try await repository.accountSummaries(ownerID: ownerID)
  }

  func transactionRoot(
    ownerID: UUID,
    rootID: UUID
  ) async throws -> LedgerTransactionRootSnapshot {
    try await repository.transactionRoot(ownerID: ownerID, rootID: rootID)
  }
}
