import Foundation

actor LifeLinkService {
  private let ownerID: UUID
  private let repository: any LifeLinkRepository

  init(ownerID: UUID, repository: any LifeLinkRepository) {
    self.ownerID = ownerID
    self.repository = repository
  }

  func linkTransaction(
    rootID: UUID,
    to journeyID: UUID,
    role: JourneyExpenseRole,
    linkID: UUID = UUID(),
    confirmedAt: Date = Date()
  ) async throws -> TransactionJourneyLink {
    try await repository.linkTransactionToJourney(
      LinkTransactionToJourneyRequest(
        linkID: linkID,
        ownerID: ownerID,
        transactionRootID: rootID,
        journeyID: journeyID,
        role: role,
        confirmedAt: confirmedAt
      )
    )
  }

  func unlink(linkID: UUID, unlinkedAt: Date = Date()) async throws {
    try await repository.unlinkTransactionFromJourney(
      ownerID: ownerID,
      linkID: linkID,
      unlinkedAt: unlinkedAt
    )
  }

  func markNoExpense(journeyID: UUID, reviewedAt: Date = Date()) async throws {
    try await repository.markJourneyNoExpense(
      ownerID: ownerID,
      journeyID: journeyID,
      reviewedAt: reviewedAt
    )
  }

  func summary(journeyID: UUID) async throws -> JourneyExpenseSummary {
    try await repository.journeyExpenseSummary(ownerID: ownerID, journeyID: journeyID)
  }

  func journeys(rootID: UUID) async throws -> [TransactionLinkedJourney] {
    try await repository.transactionJourneys(ownerID: ownerID, transactionRootID: rootID)
  }
}
