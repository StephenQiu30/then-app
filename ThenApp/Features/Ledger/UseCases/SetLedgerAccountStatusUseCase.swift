nonisolated struct SetLedgerAccountStatusUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    _ request: SetLedgerAccountStatusRequest
  ) async throws -> LedgerAccount {
    try await repository.setAccountStatus(request)
  }
}
