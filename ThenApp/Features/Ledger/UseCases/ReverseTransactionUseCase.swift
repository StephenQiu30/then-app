nonisolated struct ReverseTransactionUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    _ request: ReverseLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction {
    try await repository.reverseTransaction(request)
  }
}
