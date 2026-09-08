nonisolated struct CreateTransactionUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    _ request: CreateLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction {
    try await repository.createTransaction(request)
  }
}
