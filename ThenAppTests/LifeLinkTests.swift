import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("账务与行程生活关联")
struct LifeLinkTests {
  @Test("关联稳定账务根且更正退款后按正式分录净额汇总")
  func summaryFollowsCanonicalRootAcrossCorrectionAndRefund() async throws {
    try await withAsyncTestDatabase { database in
      let context = try await makeContext(database)
      let repository = GRDBLifeLinkRepository(database: database)
      let linkID = UUID()
      let request = LinkTransactionToJourneyRequest(
        linkID: linkID,
        ownerID: context.identity.profileID,
        transactionRootID: context.rootID,
        journeyID: context.journeyID,
        role: .transport,
        confirmedAt: lifeDate(500)
      )

      let first = try await repository.linkTransactionToJourney(request)
      let repeated = try await repository.linkTransactionToJourney(request)
      #expect(first == repeated)
      #expect(first.id == linkID)
      #expect(first.transactionRootID == context.rootID)

      let correction = try await context.ledger.correctTransaction(
        CorrectLedgerTransactionRequest(
          correctionGroupID: UUID(),
          reversalTransactionID: UUID(),
          replacementTransactionID: UUID(),
          ownerID: context.identity.profileID,
          rootID: context.rootID,
          currentTransactionID: context.original.id,
          expectedRootRevision: 1,
          replacementDetails: .expense(
            paymentAccountID: context.identity.defaultCashAccountID,
            categoryAccountID: context.categoryID
          ),
          replacementMoney: PositiveMoney(minorUnits: 8_000, currencyCode: .cny),
          replacementOccurredAt: lifeDate(300),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "地铁",
          submittedAt: lifeDate(310)
        )
      )
      _ = try await context.ledger.refundTransaction(
        RefundLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: context.identity.profileID,
          rootID: context.rootID,
          currentTransactionID: correction.replacement.id,
          expectedRootRevision: 2,
          destinationAccountID: context.identity.defaultCashAccountID,
          money: PositiveMoney(minorUnits: 2_000, currencyCode: .cny),
          occurredAt: lifeDate(400),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: lifeDate(410)
        )
      )

      let summary = try await repository.journeyExpenseSummary(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID
      )
      #expect(summary.reviewState == .hasExpense)
      #expect(summary.expenses.count == 1)
      #expect(summary.expenses[0].payee == "地铁")
      #expect(summary.expenses[0].netExpense.minorUnits == 6_000)
      #expect(summary.total == SignedMoney(minorUnits: 6_000, currencyCode: .cny))
      let linkedJourneys = try await repository.transactionJourneys(
        ownerID: context.identity.profileID,
        transactionRootID: context.rootID
      )
      #expect(linkedJourneys.count == 1)
      #expect(linkedJourneys[0].link.id == linkID)
      #expect(linkedJourneys[0].status == .reviewing)
    }
  }

  @Test("只允许用户确认的正式根与已收口行程且解绑不删除业务实体")
  func validationAndUnlinkPreserveEntities() async throws {
    try await withAsyncTestDatabase { database in
      let context = try await makeContext(database)
      let repository = GRDBLifeLinkRepository(database: database)
      let linkID = UUID()
      let request = LinkTransactionToJourneyRequest(
        linkID: linkID,
        ownerID: context.identity.profileID,
        transactionRootID: context.rootID,
        journeyID: context.journeyID,
        role: .meal,
        confirmedAt: lifeDate(500)
      )
      _ = try await repository.linkTransactionToJourney(request)

      await #expect(throws: LifeLinkError.existingLinkHasDifferentRole) {
        try await repository.linkTransactionToJourney(
          LinkTransactionToJourneyRequest(
            linkID: UUID(),
            ownerID: request.ownerID,
            transactionRootID: request.transactionRootID,
            journeyID: request.journeyID,
            role: .other,
            confirmedAt: lifeDate(501)
          )
        )
      }

      let recordingJourneyID = UUID()
      _ = try await context.journeys.startJourney(
        makeLifeJourneyStart(
          journeyID: recordingJourneyID,
          ownerID: context.identity.profileID,
          deviceID: UUID()
        )
      )
      await #expect(throws: LifeLinkError.journeyNotLinkable) {
        try await repository.linkTransactionToJourney(
          LinkTransactionToJourneyRequest(
            linkID: UUID(),
            ownerID: context.identity.profileID,
            transactionRootID: context.rootID,
            journeyID: recordingJourneyID,
            role: .transport,
            confirmedAt: lifeDate(502)
          )
        )
      }

      let before = try entityCounts(database)
      try await repository.unlinkTransactionFromJourney(
        ownerID: context.identity.profileID,
        linkID: linkID,
        unlinkedAt: lifeDate(600)
      )
      let after = try entityCounts(database)
      #expect(before.transactions == after.transactions)
      #expect(before.postings == after.postings)
      #expect(before.journeys == after.journeys)
      #expect(after.links == 0)
      await #expect(throws: LifeLinkError.linkNotFound) {
        try await repository.unlinkTransactionFromJourney(
          ownerID: context.identity.profileID,
          linkID: linkID,
          unlinkedAt: lifeDate(601)
        )
      }
    }
  }

  @Test("显式无消费与关系写入解除原子维护复盘状态")
  func explicitNoExpenseAndLinksMaintainReviewState() async throws {
    try await withAsyncTestDatabase { database in
      let context = try await makeContext(database)
      let repository = GRDBLifeLinkRepository(database: database)

      var summary = try await repository.journeyExpenseSummary(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID
      )
      #expect(summary.reviewState == .pending)
      #expect(summary.expenses.isEmpty)

      try await repository.markJourneyNoExpense(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID,
        reviewedAt: lifeDate(300)
      )
      try await repository.markJourneyNoExpense(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID,
        reviewedAt: lifeDate(301)
      )
      summary = try await repository.journeyExpenseSummary(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID
      )
      #expect(summary.reviewState == .noExpense)
      #expect(summary.expenses.isEmpty)

      let link = try await repository.linkTransactionToJourney(
        LinkTransactionToJourneyRequest(
          linkID: UUID(),
          ownerID: context.identity.profileID,
          transactionRootID: context.rootID,
          journeyID: context.journeyID,
          role: .transport,
          confirmedAt: lifeDate(400)
        )
      )
      summary = try await repository.journeyExpenseSummary(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID
      )
      #expect(summary.reviewState == .hasExpense)
      #expect(summary.expenses.count == 1)

      await #expect(throws: LifeLinkError.journeyHasLinkedExpenses) {
        try await repository.markJourneyNoExpense(
          ownerID: context.identity.profileID,
          journeyID: context.journeyID,
          reviewedAt: lifeDate(500)
        )
      }

      try await repository.unlinkTransactionFromJourney(
        ownerID: context.identity.profileID,
        linkID: link.id,
        unlinkedAt: lifeDate(600)
      )
      summary = try await repository.journeyExpenseSummary(
        ownerID: context.identity.profileID,
        journeyID: context.journeyID
      )
      #expect(summary.reviewState == .pending)
      #expect(summary.expenses.isEmpty)
    }
  }

  private struct Context {
    let identity: LocalLedgerIdentity
    let ledger: GRDBLedgerRepository
    let journeys: GRDBJourneyRepository
    let categoryID: UUID
    let rootID: UUID
    let original: PostedLedgerTransaction
    let journeyID: UUID
  }

  private func makeContext(_ database: AppDatabase) async throws -> Context {
    let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
      suggestedCurrencyCode: .cny,
      now: lifeDate(10)
    )
    let ledger = GRDBLedgerRepository(database: database)
    _ = try await ledger.confirmBaseCurrency(
      BaseCurrencyConfirmation(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: lifeDate(20)
      )
    )
    let categoryID = try requiredLifeAccountID(
      database: database,
      systemKey: "expense.transport"
    )
    let rootID = UUID()
    let original = try await ledger.createTransaction(
      CreateLedgerTransactionRequest(
        transactionID: rootID,
        ownerID: identity.profileID,
        details: .expense(
          paymentAccountID: identity.defaultCashAccountID,
          categoryAccountID: categoryID
        ),
        money: PositiveMoney(minorUnits: 10_000, currencyCode: .cny),
        occurredAt: lifeDate(100),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        payee: "打车",
        submittedAt: lifeDate(110)
      )
    )
    let journeys = GRDBJourneyRepository(database: database)
    let journeyID = UUID()
    _ = try await journeys.startJourney(
      makeLifeJourneyStart(
        journeyID: journeyID,
        ownerID: identity.profileID,
        deviceID: UUID()
      )
    )
    _ = try await journeys.beginFinalization(
      ownerID: identity.profileID,
      journeyID: journeyID,
      reason: .userEnded,
      endedAt: lifeDate(200)
    )
    _ = try await journeys.finalizeJourney(
      ownerID: identity.profileID,
      journeyID: journeyID,
      finalizedAt: lifeDate(210)
    )
    return Context(
      identity: identity,
      ledger: ledger,
      journeys: journeys,
      categoryID: categoryID,
      rootID: rootID,
      original: original,
      journeyID: journeyID
    )
  }

  private func requiredLifeAccountID(
    database: AppDatabase,
    systemKey: String
  ) throws -> UUID {
    let rawValue = try database.pool.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT id FROM ledger_accounts WHERE system_key = ?",
        arguments: [systemKey]
      )
    }
    guard let rawValue, let identifier = UUID(uuidString: rawValue) else {
      throw LedgerError.corruptedStoredLedger
    }
    return identifier
  }

  private func entityCounts(_ database: AppDatabase) throws -> (
    transactions: Int,
    postings: Int,
    journeys: Int,
    links: Int
  ) {
    try database.pool.read { database in
      (
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM ledger_transactions") ?? 0,
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM postings") ?? 0,
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM journeys") ?? 0,
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transaction_journey_links") ?? 0
      )
    }
  }
}

private nonisolated func makeLifeJourneyStart(
  journeyID: UUID,
  ownerID: UUID,
  deviceID: UUID
) -> JourneyStartRequest {
  JourneyStartRequest(
    journeyID: journeyID,
    ownerID: ownerID,
    tripPlanID: nil,
    recordingDeviceID: deviceID,
    transportMode: .walking,
    startedAt: lifeDate(120),
    trackingConsentVersion: 1
  )
}

private nonisolated func lifeDate(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}
