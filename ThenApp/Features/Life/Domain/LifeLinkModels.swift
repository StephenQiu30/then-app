import Foundation

nonisolated enum JourneyExpenseRole: String, CaseIterable, Codable, Sendable, Identifiable {
  case transport
  case parking
  case toll
  case meal
  case other

  var id: String { rawValue }
}

nonisolated enum JourneyExpenseReviewState: String, Codable, Sendable {
  case pending
  case noExpense = "no_expense"
  case hasExpense = "has_expense"
}

nonisolated struct LinkTransactionToJourneyRequest: Sendable, Equatable {
  let linkID: UUID
  let ownerID: UUID
  let transactionRootID: UUID
  let journeyID: UUID
  let role: JourneyExpenseRole
  let confirmedAt: Date
}

nonisolated struct TransactionJourneyLink: Identifiable, Sendable, Equatable {
  let id: UUID
  let transactionRootID: UUID
  let journeyID: UUID
  let role: JourneyExpenseRole
  let confirmedAt: Date
}

nonisolated struct JourneyLinkedExpense: Identifiable, Sendable, Equatable {
  let link: TransactionJourneyLink
  let payee: String?
  let occurredAt: Date
  let netExpense: SignedMoney

  var id: UUID { link.id }
}

nonisolated struct JourneyExpenseSummary: Sendable, Equatable {
  let journeyID: UUID
  let reviewState: JourneyExpenseReviewState
  let expenses: [JourneyLinkedExpense]
  let total: SignedMoney
}

nonisolated struct TransactionLinkedJourney: Identifiable, Sendable, Equatable {
  let link: TransactionJourneyLink
  let status: JourneyStatus
  let transportMode: TripTransportMode
  let startedAt: Date
  let endedAt: Date?

  var id: UUID { link.id }
}

nonisolated enum LifeLinkError: Error, Sendable, Equatable {
  case transactionRootNotFound
  case transactionRootNotPosted
  case journeyNotFound
  case journeyNotLinkable
  case journeyHasLinkedExpenses
  case duplicateLinkIdentifier
  case existingLinkHasDifferentRole
  case linkNotFound
  case corruptedStoredLink
}

nonisolated protocol LifeLinkRepository: Sendable {
  func linkTransactionToJourney(
    _ request: LinkTransactionToJourneyRequest
  ) async throws -> TransactionJourneyLink

  func unlinkTransactionFromJourney(
    ownerID: UUID,
    linkID: UUID,
    unlinkedAt: Date
  ) async throws

  func markJourneyNoExpense(
    ownerID: UUID,
    journeyID: UUID,
    reviewedAt: Date
  ) async throws

  func journeyExpenseSummary(
    ownerID: UUID,
    journeyID: UUID
  ) async throws -> JourneyExpenseSummary

  func transactionJourneys(
    ownerID: UUID,
    transactionRootID: UUID
  ) async throws -> [TransactionLinkedJourney]
}
