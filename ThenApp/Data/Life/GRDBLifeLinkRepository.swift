import Foundation
import GRDB

nonisolated struct GRDBLifeLinkRepository: LifeLinkRepository {
  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  func linkTransactionToJourney(
    _ request: LinkTransactionToJourneyRequest
  ) async throws -> TransactionJourneyLink {
    guard request.confirmedAt.timeIntervalSince1970 >= 0 else {
      throw LifeLinkError.corruptedStoredLink
    }
    return try await database.pool.write { database in
      let owner = request.ownerID.uuidString.lowercased()
      let root = request.transactionRootID.uuidString.lowercased()
      let journey = request.journeyID.uuidString.lowercased()

      guard
        let transaction = try Row.fetchOne(
          database,
          sql: """
            SELECT status, canonical_root_id
            FROM ledger_transactions
            WHERE owner_id = ? AND id = ?
            """,
          arguments: [owner, root]
        )
      else {
        throw LifeLinkError.transactionRootNotFound
      }
      let transactionStatus: String = transaction["status"]
      let canonicalRootID: String = transaction["canonical_root_id"]
      guard transactionStatus == "posted", canonicalRootID == root else {
        throw LifeLinkError.transactionRootNotPosted
      }

      guard
        let journeyStatus = try String.fetchOne(
          database,
          sql: "SELECT status FROM journeys WHERE owner_id = ? AND id = ?",
          arguments: [owner, journey]
        )
      else {
        throw LifeLinkError.journeyNotFound
      }
      guard journeyStatus == "reviewing" || journeyStatus == "completed" else {
        throw LifeLinkError.journeyNotLinkable
      }

      if let existing = try Self.fetchLink(
        database: database,
        ownerID: request.ownerID,
        transactionRootID: request.transactionRootID,
        journeyID: request.journeyID
      ) {
        guard existing.role == request.role else {
          throw LifeLinkError.existingLinkHasDifferentRole
        }
        try Self.updateReviewState(
          database: database,
          ownerID: request.ownerID,
          journeyID: request.journeyID,
          state: .hasExpense,
          updatedAt: request.confirmedAt
        )
        return existing
      }
      if try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM transaction_journey_links WHERE owner_id = ? AND id = ?",
        arguments: [owner, request.linkID.uuidString.lowercased()]
      ) == 1 {
        throw LifeLinkError.duplicateLinkIdentifier
      }

      let timestamp = request.confirmedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          INSERT INTO transaction_journey_links (
            id, owner_id, transaction_root_id, journey_id, role,
            created_by, confirmed_at, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, 'user', ?, ?, ?)
          """,
        arguments: [
          request.linkID.uuidString.lowercased(),
          owner,
          root,
          journey,
          request.role.rawValue,
          timestamp,
          timestamp,
          timestamp,
        ]
      )
      try Self.updateReviewState(
        database: database,
        ownerID: request.ownerID,
        journeyID: request.journeyID,
        state: .hasExpense,
        updatedAt: request.confirmedAt
      )
      guard
        let stored = try Self.fetchLink(
          database: database,
          ownerID: request.ownerID,
          linkID: request.linkID
        )
      else {
        throw LifeLinkError.corruptedStoredLink
      }
      return stored
    }
  }

  func unlinkTransactionFromJourney(
    ownerID: UUID,
    linkID: UUID,
    unlinkedAt: Date
  ) async throws {
    guard unlinkedAt.timeIntervalSince1970 >= 0 else {
      throw LifeLinkError.corruptedStoredLink
    }
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      let link = linkID.uuidString.lowercased()
      guard
        let journeyRaw = try String.fetchOne(
          database,
          sql: "SELECT journey_id FROM transaction_journey_links WHERE owner_id = ? AND id = ?",
          arguments: [owner, link]
        ),
        let journeyID = UUID(uuidString: journeyRaw)
      else {
        throw LifeLinkError.linkNotFound
      }
      try database.execute(
        sql: "DELETE FROM transaction_journey_links WHERE owner_id = ? AND id = ?",
        arguments: [owner, link]
      )
      guard database.changesCount == 1 else {
        throw LifeLinkError.linkNotFound
      }
      let remainingLinks =
        try Int.fetchOne(
          database,
          sql:
            "SELECT COUNT(*) FROM transaction_journey_links WHERE owner_id = ? AND journey_id = ?",
          arguments: [owner, journeyRaw]
        ) ?? 0
      try Self.updateReviewState(
        database: database,
        ownerID: ownerID,
        journeyID: journeyID,
        state: remainingLinks == 0 ? .pending : .hasExpense,
        updatedAt: unlinkedAt
      )
    }
  }

  func markJourneyNoExpense(
    ownerID: UUID,
    journeyID: UUID,
    reviewedAt: Date
  ) async throws {
    guard reviewedAt.timeIntervalSince1970 >= 0 else {
      throw LifeLinkError.corruptedStoredLink
    }
    try await database.pool.write { database in
      let owner = ownerID.uuidString.lowercased()
      let journey = journeyID.uuidString.lowercased()
      guard
        let status = try String.fetchOne(
          database,
          sql: "SELECT status FROM journeys WHERE owner_id = ? AND id = ?",
          arguments: [owner, journey]
        )
      else {
        throw LifeLinkError.journeyNotFound
      }
      guard status == "reviewing" || status == "completed" else {
        throw LifeLinkError.journeyNotLinkable
      }
      let linkCount =
        try Int.fetchOne(
          database,
          sql:
            "SELECT COUNT(*) FROM transaction_journey_links WHERE owner_id = ? AND journey_id = ?",
          arguments: [owner, journey]
        ) ?? 0
      guard linkCount == 0 else {
        throw LifeLinkError.journeyHasLinkedExpenses
      }
      try Self.updateReviewState(
        database: database,
        ownerID: ownerID,
        journeyID: journeyID,
        state: .noExpense,
        updatedAt: reviewedAt
      )
    }
  }

  func journeyExpenseSummary(
    ownerID: UUID,
    journeyID: UUID
  ) async throws -> JourneyExpenseSummary {
    try await database.pool.read { database in
      let owner = ownerID.uuidString.lowercased()
      let journey = journeyID.uuidString.lowercased()
      guard
        let reviewStateRaw = try String.fetchOne(
          database,
          sql: "SELECT expense_review_state FROM journeys WHERE owner_id = ? AND id = ?",
          arguments: [owner, journey]
        )
      else {
        throw LifeLinkError.journeyNotFound
      }
      guard let reviewState = JourneyExpenseReviewState(rawValue: reviewStateRaw) else {
        throw LifeLinkError.corruptedStoredLink
      }
      guard
        let currencyRaw = try String.fetchOne(
          database,
          sql: "SELECT base_currency_code FROM local_profiles WHERE id = ?",
          arguments: [owner]
        ),
        let currency = CurrencyCode(rawValue: currencyRaw)
      else {
        throw LifeLinkError.corruptedStoredLink
      }

      let rows = try Row.fetchAll(
        database,
        sql: """
          WITH current_transactions AS (
            SELECT transaction_record.*
            FROM ledger_transactions AS transaction_record
            WHERE transaction_record.owner_id = ?
              AND transaction_record.status = 'posted'
              AND transaction_record.kind NOT IN ('refund', 'reversal')
              AND NOT EXISTS (
                SELECT 1
                FROM ledger_transactions AS replacement
                WHERE replacement.owner_id = transaction_record.owner_id
                  AND replacement.status = 'posted'
                  AND replacement.replacement_for_id = transaction_record.id
              )
          )
          SELECT
            link.id,
            link.transaction_root_id,
            link.journey_id,
            link.role,
            link.confirmed_at,
            current_transaction.payee,
            current_transaction.occurred_at,
            COALESCE(
              (
                SELECT SUM(
                  CASE
                    WHEN account.kind = 'expense' AND posting.side = 'debit'
                      THEN posting.amount_minor
                    WHEN account.kind = 'expense' AND posting.side = 'credit'
                      THEN -posting.amount_minor
                    ELSE 0
                  END
                )
                FROM ledger_transactions AS root_transaction
                JOIN postings AS posting
                  ON posting.owner_id = root_transaction.owner_id
                  AND posting.transaction_id = root_transaction.id
                JOIN ledger_accounts AS account
                  ON account.owner_id = posting.owner_id
                  AND account.id = posting.ledger_account_id
                WHERE root_transaction.owner_id = link.owner_id
                  AND root_transaction.canonical_root_id = link.transaction_root_id
                  AND root_transaction.status = 'posted'
                  AND account.kind = 'expense'
              ),
              0
            ) AS net_expense_minor
          FROM transaction_journey_links AS link
          JOIN current_transactions AS current_transaction
            ON current_transaction.owner_id = link.owner_id
            AND current_transaction.canonical_root_id = link.transaction_root_id
          WHERE link.owner_id = ? AND link.journey_id = ?
          ORDER BY current_transaction.occurred_at, link.id
          """,
        arguments: [owner, owner, journey]
      )

      var expenses: [JourneyLinkedExpense] = []
      var totalMinorUnits: Int64 = 0
      for row in rows {
        let link = try Self.decodeLink(row)
        let netExpenseMinorUnits: Int64 = row["net_expense_minor"]
        let (nextTotal, overflow) = totalMinorUnits.addingReportingOverflow(netExpenseMinorUnits)
        guard !overflow else { throw LifeLinkError.corruptedStoredLink }
        totalMinorUnits = nextTotal
        expenses.append(
          JourneyLinkedExpense(
            link: link,
            payee: row["payee"],
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
            netExpense: SignedMoney(
              minorUnits: netExpenseMinorUnits,
              currencyCode: currency
            )
          )
        )
      }
      guard
        (expenses.isEmpty && reviewState != .hasExpense)
          || (!expenses.isEmpty && reviewState == .hasExpense)
      else {
        throw LifeLinkError.corruptedStoredLink
      }
      return JourneyExpenseSummary(
        journeyID: journeyID,
        reviewState: reviewState,
        expenses: expenses,
        total: SignedMoney(minorUnits: totalMinorUnits, currencyCode: currency)
      )
    }
  }

  func transactionJourneys(
    ownerID: UUID,
    transactionRootID: UUID
  ) async throws -> [TransactionLinkedJourney] {
    try await database.pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT
            link.id,
            link.transaction_root_id,
            link.journey_id,
            link.role,
            link.confirmed_at,
            journey.status,
            journey.transport_mode,
            journey.started_at,
            journey.ended_at
          FROM transaction_journey_links AS link
          JOIN journeys AS journey
            ON journey.owner_id = link.owner_id AND journey.id = link.journey_id
          WHERE link.owner_id = ? AND link.transaction_root_id = ?
          ORDER BY journey.started_at DESC, link.id
          """,
        arguments: [
          ownerID.uuidString.lowercased(),
          transactionRootID.uuidString.lowercased(),
        ]
      )
      return try rows.map { row in
        guard
          let status = JourneyStatus(rawValue: row["status"]),
          let transportMode = TripTransportMode(rawValue: row["transport_mode"])
        else {
          throw LifeLinkError.corruptedStoredLink
        }
        return TransactionLinkedJourney(
          link: try Self.decodeLink(row),
          status: status,
          transportMode: transportMode,
          startedAt: Date(timeIntervalSince1970: row["started_at"]),
          endedAt: (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        )
      }
    }
  }

  private static func fetchLink(
    database: Database,
    ownerID: UUID,
    linkID: UUID
  ) throws -> TransactionJourneyLink? {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT id, transaction_root_id, journey_id, role, confirmed_at
          FROM transaction_journey_links
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [ownerID.uuidString.lowercased(), linkID.uuidString.lowercased()]
      )
    else {
      return nil
    }
    return try decodeLink(row)
  }

  private static func fetchLink(
    database: Database,
    ownerID: UUID,
    transactionRootID: UUID,
    journeyID: UUID
  ) throws -> TransactionJourneyLink? {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT id, transaction_root_id, journey_id, role, confirmed_at
          FROM transaction_journey_links
          WHERE owner_id = ? AND transaction_root_id = ? AND journey_id = ?
          """,
        arguments: [
          ownerID.uuidString.lowercased(),
          transactionRootID.uuidString.lowercased(),
          journeyID.uuidString.lowercased(),
        ]
      )
    else {
      return nil
    }
    return try decodeLink(row)
  }

  private static func decodeLink(_ row: Row) throws -> TransactionJourneyLink {
    let idRaw: String = row["id"]
    let rootRaw: String = row["transaction_root_id"]
    let journeyRaw: String = row["journey_id"]
    let roleRaw: String = row["role"]
    guard let id = UUID(uuidString: idRaw),
      let rootID = UUID(uuidString: rootRaw),
      let journeyID = UUID(uuidString: journeyRaw),
      let role = JourneyExpenseRole(rawValue: roleRaw)
    else {
      throw LifeLinkError.corruptedStoredLink
    }
    return TransactionJourneyLink(
      id: id,
      transactionRootID: rootID,
      journeyID: journeyID,
      role: role,
      confirmedAt: Date(timeIntervalSince1970: row["confirmed_at"])
    )
  }

  private static func updateReviewState(
    database: Database,
    ownerID: UUID,
    journeyID: UUID,
    state: JourneyExpenseReviewState,
    updatedAt: Date
  ) throws {
    try database.execute(
      sql: """
        UPDATE journeys
        SET expense_review_state = ?, updated_at = MAX(updated_at, ?)
        WHERE owner_id = ? AND id = ?
        """,
      arguments: [
        state.rawValue,
        updatedAt.timeIntervalSince1970,
        ownerID.uuidString.lowercased(),
        journeyID.uuidString.lowercased(),
      ]
    )
    guard database.changesCount == 1 else {
      throw LifeLinkError.journeyNotFound
    }
  }
}
