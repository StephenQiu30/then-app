import Foundation

nonisolated protocol LedgerRepository: Sendable {
  func localProfile(ownerID: UUID) async throws -> LocalLedgerProfile

  func confirmBaseCurrency(
    _ confirmation: BaseCurrencyConfirmation
  ) async throws -> LocalLedgerProfile

  func createAccount(
    _ request: CreateLedgerAccountRequest
  ) async throws -> LedgerAccount

  func setAccountStatus(
    _ request: SetLedgerAccountStatusRequest
  ) async throws -> LedgerAccount

  func createTransaction(
    _ request: CreateLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction

  func refundTransaction(
    _ request: RefundLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction

  func reverseTransaction(
    _ request: ReverseLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction

  func correctTransaction(
    _ request: CorrectLedgerTransactionRequest
  ) async throws -> CorrectedLedgerTransaction

  func recentTransactions(
    ownerID: UUID,
    limit: Int
  ) async throws -> [LedgerTransactionSummary]

  func searchTransactions(
    ownerID: UUID,
    searchText: String,
    amountMinorUnits: Int64?,
    limit: Int
  ) async throws -> [LedgerTransactionSummary]

  func filteredTransactions(
    ownerID: UUID,
    filter: LedgerTransactionFilter,
    limit: Int
  ) async throws -> [LedgerTransactionSummary]

  func monthlyReport(
    ownerID: UUID,
    month: LedgerMonth,
    filter: LedgerTransactionFilter
  ) async throws -> LedgerMonthlyReport

  func accountSummaries(ownerID: UUID) async throws -> [LedgerAccountSummary]

  func transactionRoot(
    ownerID: UUID,
    rootID: UUID
  ) async throws -> LedgerTransactionRootSnapshot
}

extension LedgerRepository {
  func monthlyReport(
    ownerID: UUID,
    month: LedgerMonth
  ) async throws -> LedgerMonthlyReport {
    try await monthlyReport(
      ownerID: ownerID,
      month: month,
      filter: LedgerTransactionFilter()
    )
  }
}
