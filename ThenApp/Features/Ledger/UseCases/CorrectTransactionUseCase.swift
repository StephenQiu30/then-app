nonisolated struct CorrectTransactionUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    _ request: CorrectLedgerTransactionRequest
  ) async throws -> CorrectedLedgerTransaction {
    try await repository.correctTransaction(request)
  }
}
