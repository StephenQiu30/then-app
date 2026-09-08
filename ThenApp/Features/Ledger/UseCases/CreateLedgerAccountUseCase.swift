nonisolated struct CreateLedgerAccountUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    _ request: CreateLedgerAccountRequest
  ) async throws -> LedgerAccount {
    try await repository.createAccount(request)
  }
}
