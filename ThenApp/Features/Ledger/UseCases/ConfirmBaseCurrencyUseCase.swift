import Foundation

nonisolated struct ConfirmBaseCurrencyUseCase: Sendable {
  private let repository: any LedgerRepository

  init(repository: any LedgerRepository) {
    self.repository = repository
  }

  func execute(
    ownerID: UUID,
    currencyCode: CurrencyCode,
    confirmedAt: Date = Date()
  ) async throws -> LocalLedgerProfile {
    try await repository.confirmBaseCurrency(
      BaseCurrencyConfirmation(
        ownerID: ownerID,
        currencyCode: currencyCode,
        confirmedAt: confirmedAt
      )
    )
  }
}
