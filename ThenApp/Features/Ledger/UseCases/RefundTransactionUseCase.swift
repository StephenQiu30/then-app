nonisolated struct RefundTransactionUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    _ request: RefundLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction {
    try await repository.refundTransaction(request)
  }
}
