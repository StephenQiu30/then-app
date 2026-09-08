import Foundation
import GRDB

nonisolated struct GRDBLedgerRepository: LedgerRepository, Sendable {
  private struct CanonicalRootContext {
    let rootRevision: Int
    let currentTransaction: PostedLedgerTransaction
    let activeRefunds: [PostedLedgerTransaction]
    let activeRefundMinorUnits: Int64
    let isCurrentReversed: Bool
    let transactions: [PostedLedgerTransaction]
  }

  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  func localProfile(ownerID: UUID) async throws -> LocalLedgerProfile {
    try await database.pool.read { database in
      guard let profile = try Self.fetchProfile(database: database, ownerID: ownerID) else {
        throw LedgerError.localProfileNotFound
      }
      return profile
    }
  }

  func confirmBaseCurrency(
    _ confirmation: BaseCurrencyConfirmation
  ) async throws -> LocalLedgerProfile {
    try await database.pool.write { database in
      guard
        let profile = try Self.fetchProfile(
          database: database,
          ownerID: confirmation.ownerID
        )
      else {
        throw LedgerError.localProfileNotFound
      }

      if profile.baseCurrencyState == .confirmed {
        guard profile.baseCurrencyCode == confirmation.currencyCode else {
          throw LedgerError.baseCurrencyAlreadyConfirmed
        }
        return profile
      }

      let postedTransactionCount =
        try Int.fetchOne(
          database,
          sql: """
            SELECT COUNT(*)
            FROM ledger_transactions
            WHERE owner_id = ? AND status = 'posted'
            """,
          arguments: [confirmation.ownerID.uuidString.lowercased()]
        ) ?? 0
      guard postedTransactionCount == 0 else {
        throw LedgerError.postedTransactionsExistBeforeCurrencyConfirmation
      }

      let ownerID = confirmation.ownerID.uuidString.lowercased()
      let timestamp = confirmation.confirmedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          UPDATE local_profiles
          SET base_currency_code = ?, base_currency_state = 'confirmed', updated_at = ?
          WHERE id = ? AND base_currency_state = 'suggested'
          """,
        arguments: [confirmation.currencyCode.rawValue, timestamp, ownerID]
      )
      guard database.changesCount == 1 else {
        throw LedgerError.inconsistentLocalProfile
      }

      try database.execute(
        sql: """
          UPDATE ledger_accounts
          SET native_currency_code = ?, configuration_state = 'ready', updated_at = ?
          WHERE owner_id = ?
          """,
        arguments: [confirmation.currencyCode.rawValue, timestamp, ownerID]
      )

      guard
        let confirmedProfile = try Self.fetchProfile(
          database: database,
          ownerID: confirmation.ownerID
        )
      else {
        throw LedgerError.inconsistentLocalProfile
      }
      return confirmedProfile
    }
  }

  func createAccount(
    _ request: CreateLedgerAccountRequest
  ) async throws -> LedgerAccount {
    try await database.pool.write { database in
      if try Self.accountIdentifierExists(
        database: database,
        accountID: request.accountID
      ) {
        guard
          let existing = try Self.fetchAccount(
            database: database,
            ownerID: request.ownerID,
            accountID: request.accountID
          ),
          existing.kind == request.creationType.kind,
          existing.subtype == request.creationType.subtype,
          existing.name == request.name,
          existing.parentID == request.parentID,
          existing.systemKey == nil
        else {
          throw LedgerError.duplicateAccountIdentifier
        }
        return existing
      }

      guard
        let profile = try Self.fetchProfile(
          database: database,
          ownerID: request.ownerID
        )
      else {
        throw LedgerError.localProfileNotFound
      }
      guard profile.baseCurrencyState == .confirmed else {
        throw LedgerError.baseCurrencyNotConfirmed
      }

      if let parentID = request.parentID {
        guard
          let parent = try Self.fetchAccount(
            database: database,
            ownerID: request.ownerID,
            accountID: parentID
          )
        else {
          throw LedgerError.accountNotFound(parentID)
        }
        guard parent.status == .active else {
          throw LedgerError.accountArchived(parentID)
        }
        guard parent.kind == request.creationType.kind else {
          throw LedgerError.categoryParentKindMismatch
        }
        guard parent.parentID == nil else {
          throw LedgerError.categoryHierarchyTooDeep
        }
      }

      let maximumDisplayOrder =
        try Int.fetchOne(
          database,
          sql: """
            SELECT MAX(display_order)
            FROM ledger_accounts
            WHERE owner_id = ? AND kind = ?
            """,
          arguments: [
            request.ownerID.uuidString.lowercased(),
            request.creationType.kind.rawValue,
          ]
        ) ?? -1
      let (displayOrder, overflow) = maximumDisplayOrder.addingReportingOverflow(1)
      guard !overflow else {
        throw LedgerError.corruptedStoredLedger
      }

      let timestamp = request.submittedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          INSERT INTO ledger_accounts (
            id,
            owner_id,
            parent_id,
            kind,
            subtype,
            name,
            native_currency_code,
            configuration_state,
            system_key,
            status,
            display_order,
            created_at,
            updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 'ready', NULL, 'active', ?, ?, ?)
          """,
        arguments: [
          request.accountID.uuidString.lowercased(),
          request.ownerID.uuidString.lowercased(),
          request.parentID?.uuidString.lowercased(),
          request.creationType.kind.rawValue,
          request.creationType.subtype.rawValue,
          request.name,
          profile.baseCurrencyCode.rawValue,
          displayOrder,
          timestamp,
          timestamp,
        ]
      )

      guard
        let account = try Self.fetchAccount(
          database: database,
          ownerID: request.ownerID,
          accountID: request.accountID
        )
      else {
        throw LedgerError.corruptedStoredLedger
      }
      return account
    }
  }

  func setAccountStatus(
    _ request: SetLedgerAccountStatusRequest
  ) async throws -> LedgerAccount {
    try await database.pool.write { database in
      guard
        let account = try Self.fetchAccount(
          database: database,
          ownerID: request.ownerID,
          accountID: request.accountID
        )
      else {
        throw LedgerError.accountNotFound(request.accountID)
      }
      guard account.kind != .equity else {
        throw LedgerError.internalAccountProtected
      }
      guard account.status != request.status else {
        return account
      }

      if request.status == .archived {
        let activeChildCount =
          try Int.fetchOne(
            database,
            sql: """
              SELECT COUNT(*)
              FROM ledger_accounts
              WHERE owner_id = ? AND parent_id = ? AND status = 'active'
              """,
            arguments: [
              request.ownerID.uuidString.lowercased(),
              request.accountID.uuidString.lowercased(),
            ]
          ) ?? 0
        guard activeChildCount == 0 else {
          throw LedgerError.accountHasActiveChildren
        }
      } else if let parentID = account.parentID {
        guard
          let parent = try Self.fetchAccount(
            database: database,
            ownerID: request.ownerID,
            accountID: parentID
          )
        else {
          throw LedgerError.corruptedStoredLedger
        }
        guard parent.status == .active else {
          throw LedgerError.accountArchived(parentID)
        }
      }

      try database.execute(
        sql: """
          UPDATE ledger_accounts
          SET status = ?, updated_at = ?
          WHERE owner_id = ? AND id = ?
          """,
        arguments: [
          request.status.rawValue,
          request.changedAt.timeIntervalSince1970,
          request.ownerID.uuidString.lowercased(),
          request.accountID.uuidString.lowercased(),
        ]
      )
      guard database.changesCount == 1,
        let updated = try Self.fetchAccount(
          database: database,
          ownerID: request.ownerID,
          accountID: request.accountID
        )
      else {
        throw LedgerError.corruptedStoredLedger
      }
      return updated
    }
  }

  func createTransaction(
    _ request: CreateLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction {
    try await database.pool.write { database in
      if try Self.transactionExists(database: database, transactionID: request.transactionID) {
        let existing = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.transactionID
        )
        guard Self.matches(existing, request: request) else {
          throw LedgerError.duplicateTransactionIdentifier
        }
        return existing
      }

      guard
        let profile = try Self.fetchProfile(
          database: database,
          ownerID: request.ownerID
        )
      else {
        throw LedgerError.localProfileNotFound
      }
      let accounts = try request.details.accountIDs.map { accountID in
        guard
          let account = try Self.fetchAccount(
            database: database,
            ownerID: request.ownerID,
            accountID: accountID
          )
        else {
          throw LedgerError.accountNotFound(accountID)
        }
        return account
      }
      let plan = try LedgerPostingPlan.make(
        request: request,
        profile: profile,
        accounts: accounts
      )

      let transactionID = request.transactionID.uuidString.lowercased()
      let ownerID = request.ownerID.uuidString.lowercased()
      let timestamp = request.submittedAt.timeIntervalSince1970
      try database.execute(
        sql: """
          INSERT INTO ledger_transactions (
            id,
            owner_id,
            status,
            kind,
            canonical_root_id,
            local_root_revision,
            occurred_at,
            original_timezone_id,
            local_date,
            payee,
            note,
            source_type,
            posted_at,
            created_at,
            updated_at
          ) VALUES (?, ?, 'posted', ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          transactionID,
          ownerID,
          plan.kind.rawValue,
          transactionID,
          request.occurredAt.timeIntervalSince1970,
          request.originalTimeZoneIdentifier,
          request.localDate,
          request.payee,
          request.note,
          request.source.rawValue,
          timestamp,
          timestamp,
          timestamp,
        ]
      )

      for blueprint in plan.postings {
        try database.execute(
          sql: """
            INSERT INTO postings (
              id,
              owner_id,
              transaction_id,
              ledger_account_id,
              side,
              amount_minor,
              currency_code,
              memo,
              sequence,
              created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            """,
          arguments: [
            UUID().uuidString.lowercased(),
            ownerID,
            transactionID,
            blueprint.accountID.uuidString.lowercased(),
            blueprint.side.rawValue,
            blueprint.money.minorUnits,
            blueprint.money.currencyCode.rawValue,
            blueprint.sequence,
            timestamp,
          ]
        )
      }

      return try Self.fetchPostedTransaction(
        database: database,
        transactionID: request.transactionID
      )
    }
  }

  func refundTransaction(
    _ request: RefundLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction {
    try await database.pool.write { database in
      if try Self.transactionExists(database: database, transactionID: request.transactionID) {
        let existing = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.transactionID
        )
        let target = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.currentTransactionID
        )
        guard Self.matches(existing, refundRequest: request, target: target) else {
          throw LedgerError.duplicateTransactionIdentifier
        }
        return existing
      }

      let context = try Self.fetchCanonicalRootContext(
        database: database,
        ownerID: request.ownerID,
        rootID: request.rootID
      )
      try Self.validate(
        context: context,
        rootID: request.rootID,
        currentTransactionID: request.currentTransactionID,
        expectedRootRevision: request.expectedRootRevision
      )
      let current = context.currentTransaction
      guard current.kind == .expense else {
        throw LedgerError.transactionNotRefundable(current.id)
      }
      guard !context.isCurrentReversed else {
        throw LedgerError.transactionAlreadyReversed(current.id)
      }
      guard let currentMoney = current.postings.first?.money,
        current.postings.allSatisfy({ $0.money == currentMoney })
      else {
        throw LedgerError.corruptedStoredLedger
      }
      guard currentMoney.currencyCode == request.money.currencyCode else {
        throw LedgerError.accountCurrencyMismatch(request.destinationAccountID)
      }
      let (availableMinorUnits, subtractionOverflow) =
        currentMoney.minorUnits.subtractingReportingOverflow(
          context.activeRefundMinorUnits
        )
      guard !subtractionOverflow, availableMinorUnits >= 0 else {
        throw LedgerError.corruptedStoredLedger
      }
      guard request.money.minorUnits <= availableMinorUnits else {
        throw LedgerError.refundAmountExceedsAvailable
      }

      guard
        let destinationAccount = try Self.fetchAccount(
          database: database,
          ownerID: request.ownerID,
          accountID: request.destinationAccountID
        )
      else {
        throw LedgerError.accountNotFound(request.destinationAccountID)
      }
      try Self.validateFundingAccount(
        destinationAccount,
        currencyCode: request.money.currencyCode
      )
      let categoryPosting = try Self.expenseCategoryPosting(
        database: database,
        transaction: current
      )
      let nextRevision = try Self.advanceRootRevision(
        database: database,
        ownerID: request.ownerID,
        rootID: request.rootID,
        expectedRevision: request.expectedRootRevision,
        updatedAt: request.submittedAt
      )
      try Self.insertPostedTransaction(
        database: database,
        id: request.transactionID,
        ownerID: request.ownerID,
        kind: .refund,
        rootID: request.rootID,
        rootRevision: nextRevision,
        occurredAt: request.occurredAt,
        originalTimeZoneIdentifier: request.originalTimeZoneIdentifier,
        localDate: request.localDate,
        payee: current.payee,
        note: request.note,
        postedAt: request.submittedAt,
        refundOfID: current.id
      )
      try Self.insertPostings(
        database: database,
        ownerID: request.ownerID,
        transactionID: request.transactionID,
        blueprints: [
          LedgerPostingBlueprint(
            accountID: destinationAccount.id,
            side: .debit,
            money: request.money,
            sequence: 0
          ),
          LedgerPostingBlueprint(
            accountID: categoryPosting.accountID,
            side: .credit,
            money: request.money,
            sequence: 1
          ),
        ],
        createdAt: request.submittedAt
      )
      return try Self.fetchPostedTransaction(
        database: database,
        transactionID: request.transactionID
      )
    }
  }

  func reverseTransaction(
    _ request: ReverseLedgerTransactionRequest
  ) async throws -> PostedLedgerTransaction {
    try await database.pool.write { database in
      if try Self.transactionExists(database: database, transactionID: request.transactionID) {
        let existing = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.transactionID
        )
        let target = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.targetTransactionID
        )
        guard Self.matches(existing, reverseRequest: request, target: target) else {
          throw LedgerError.duplicateTransactionIdentifier
        }
        return existing
      }

      let context = try Self.fetchCanonicalRootContext(
        database: database,
        ownerID: request.ownerID,
        rootID: request.rootID
      )
      guard context.rootRevision == request.expectedRootRevision else {
        throw LedgerError.rootRevisionConflict(
          expected: request.expectedRootRevision,
          actual: context.rootRevision
        )
      }
      guard
        let target = context.transactions.first(where: {
          $0.id == request.targetTransactionID
        })
      else {
        throw LedgerError.transactionNotFound(request.targetTransactionID)
      }
      guard target.kind != .reversal else {
        throw LedgerError.reversalCannotBeReversed
      }
      let alreadyReversed = context.transactions.contains {
        $0.reversalOfID == target.id
      }
      guard !alreadyReversed else {
        throw LedgerError.transactionAlreadyReversed(target.id)
      }

      if target.kind == .refund {
        guard context.activeRefunds.contains(where: { $0.id == target.id }) else {
          throw LedgerError.transactionAlreadyReversed(target.id)
        }
      } else {
        guard target.id == context.currentTransaction.id else {
          throw LedgerError.transactionNotCurrent(target.id)
        }
        if target.kind == .expense, context.activeRefundMinorUnits > 0 {
          throw LedgerError.activeRefundsPreventReversal
        }
      }

      let nextRevision = try Self.advanceRootRevision(
        database: database,
        ownerID: request.ownerID,
        rootID: request.rootID,
        expectedRevision: request.expectedRootRevision,
        updatedAt: request.submittedAt
      )
      try Self.insertPostedTransaction(
        database: database,
        id: request.transactionID,
        ownerID: request.ownerID,
        kind: .reversal,
        rootID: request.rootID,
        rootRevision: nextRevision,
        occurredAt: request.occurredAt,
        originalTimeZoneIdentifier: request.originalTimeZoneIdentifier,
        localDate: request.localDate,
        payee: target.payee,
        note: request.reason,
        postedAt: request.submittedAt,
        reversalOfID: target.id
      )
      try Self.insertPostings(
        database: database,
        ownerID: request.ownerID,
        transactionID: request.transactionID,
        blueprints: Self.oppositePostings(of: target),
        createdAt: request.submittedAt
      )
      return try Self.fetchPostedTransaction(
        database: database,
        transactionID: request.transactionID
      )
    }
  }

  func correctTransaction(
    _ request: CorrectLedgerTransactionRequest
  ) async throws -> CorrectedLedgerTransaction {
    try await database.pool.write { database in
      if try Self.correctionCommandExists(database: database, request: request) {
        let reversal = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.reversalTransactionID
        )
        let replacement = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.replacementTransactionID
        )
        let target = try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.currentTransactionID
        )
        guard
          try Self.matches(
            reversal: reversal,
            replacement: replacement,
            correctionRequest: request,
            target: target
          )
        else {
          throw LedgerError.duplicateCorrectionIdentifier
        }
        return CorrectedLedgerTransaction(
          reversal: reversal,
          replacement: replacement,
          rootRevision: replacement.localRootRevision
        )
      }

      let context = try Self.fetchCanonicalRootContext(
        database: database,
        ownerID: request.ownerID,
        rootID: request.rootID
      )
      try Self.validate(
        context: context,
        rootID: request.rootID,
        currentTransactionID: request.currentTransactionID,
        expectedRootRevision: request.expectedRootRevision
      )
      let current = context.currentTransaction
      guard !context.isCurrentReversed else {
        throw LedgerError.transactionAlreadyReversed(current.id)
      }
      guard [.expense, .income, .transfer].contains(current.kind) else {
        throw LedgerError.transactionNotCurrent(current.id)
      }
      guard request.replacementDetails.kind == current.kind else {
        throw LedgerError.correctionKindCannotChange
      }
      if current.kind == .expense,
        request.replacementMoney.minorUnits < context.activeRefundMinorUnits
      {
        throw LedgerError.correctionAmountBelowActiveRefunds
      }

      guard
        let profile = try Self.fetchProfile(
          database: database,
          ownerID: request.ownerID
        )
      else {
        throw LedgerError.localProfileNotFound
      }
      let accounts = try request.replacementDetails.accountIDs.map { accountID in
        guard
          let account = try Self.fetchAccount(
            database: database,
            ownerID: request.ownerID,
            accountID: accountID
          )
        else {
          throw LedgerError.accountNotFound(accountID)
        }
        return account
      }
      let replacementRequest = try CreateLedgerTransactionRequest(
        transactionID: request.replacementTransactionID,
        ownerID: request.ownerID,
        details: request.replacementDetails,
        money: request.replacementMoney,
        occurredAt: request.replacementOccurredAt,
        originalTimeZoneIdentifier: request.originalTimeZoneIdentifier,
        payee: request.payee,
        note: request.note,
        submittedAt: request.submittedAt
      )
      let replacementPlan = try LedgerPostingPlan.make(
        request: replacementRequest,
        profile: profile,
        accounts: accounts
      )
      let nextRevision = try Self.advanceRootRevision(
        database: database,
        ownerID: request.ownerID,
        rootID: request.rootID,
        expectedRevision: request.expectedRootRevision,
        updatedAt: request.submittedAt
      )

      try Self.insertPostedTransaction(
        database: database,
        id: request.reversalTransactionID,
        ownerID: request.ownerID,
        kind: .reversal,
        rootID: request.rootID,
        rootRevision: nextRevision,
        occurredAt: current.occurredAt,
        originalTimeZoneIdentifier: current.originalTimeZoneIdentifier,
        localDate: current.localDate,
        payee: current.payee,
        note: current.note,
        postedAt: request.submittedAt,
        reversalOfID: current.id,
        correctionGroupID: request.correctionGroupID
      )
      try Self.insertPostings(
        database: database,
        ownerID: request.ownerID,
        transactionID: request.reversalTransactionID,
        blueprints: Self.oppositePostings(of: current),
        createdAt: request.submittedAt
      )
      try Self.insertPostedTransaction(
        database: database,
        id: request.replacementTransactionID,
        ownerID: request.ownerID,
        kind: replacementPlan.kind,
        rootID: request.rootID,
        rootRevision: nextRevision,
        occurredAt: request.replacementOccurredAt,
        originalTimeZoneIdentifier: request.originalTimeZoneIdentifier,
        localDate: request.replacementLocalDate,
        payee: request.payee,
        note: request.note,
        postedAt: request.submittedAt,
        replacementForID: current.id,
        correctionGroupID: request.correctionGroupID
      )
      try Self.insertPostings(
        database: database,
        ownerID: request.ownerID,
        transactionID: request.replacementTransactionID,
        blueprints: replacementPlan.postings,
        createdAt: request.submittedAt
      )

      return CorrectedLedgerTransaction(
        reversal: try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.reversalTransactionID
        ),
        replacement: try Self.fetchPostedTransaction(
          database: database,
          transactionID: request.replacementTransactionID
        ),
        rootRevision: nextRevision
      )
    }
  }

  func recentTransactions(
    ownerID: UUID,
    limit: Int
  ) async throws -> [LedgerTransactionSummary] {
    try await database.pool.read { database in
      try Self.fetchTransactionSummaries(
        database: database,
        ownerID: ownerID,
        filter: LedgerTransactionFilter(),
        limit: limit
      )
    }
  }

  func searchTransactions(
    ownerID: UUID,
    searchText: String,
    amountMinorUnits: Int64?,
    limit: Int
  ) async throws -> [LedgerTransactionSummary] {
    try await database.pool.read { database in
      try Self.fetchTransactionSummaries(
        database: database,
        ownerID: ownerID,
        filter: LedgerTransactionFilter(
          searchText: searchText,
          amountMinorUnits: amountMinorUnits
        ),
        limit: limit
      )
    }
  }

  func filteredTransactions(
    ownerID: UUID,
    filter: LedgerTransactionFilter,
    limit: Int
  ) async throws -> [LedgerTransactionSummary] {
    try await database.pool.read { database in
      try Self.fetchTransactionSummaries(
        database: database,
        ownerID: ownerID,
        filter: filter,
        limit: limit
      )
    }
  }

  func monthlyReport(
    ownerID: UUID,
    month: LedgerMonth,
    filter: LedgerTransactionFilter
  ) async throws -> LedgerMonthlyReport {
    try await database.pool.read { database in
      guard let profile = try Self.fetchProfile(database: database, ownerID: ownerID) else {
        throw LedgerError.localProfileNotFound
      }
      guard profile.baseCurrencyState == .confirmed else {
        throw LedgerError.baseCurrencyNotConfirmed
      }
      let trendMonths = try (0..<6).reversed().map { offset in
        try month.addingMonths(-offset)
      }
      guard let trendStart = trendMonths.first else {
        throw LedgerError.corruptedStoredLedger
      }
      var reportArguments = Self.filterArguments(ownerID: ownerID, filter: filter)
      reportArguments += [
        ownerID.uuidString.lowercased(),
        month.startLocalDate,
        month.endExclusiveLocalDate,
        filter.categoryAccountID?.uuidString.lowercased(),
        filter.categoryAccountID?.uuidString.lowercased(),
      ]
      let rows = try Row.fetchAll(
        database,
        sql: """
          WITH \(Self.filteredRootCommonTableExpression)
          SELECT
            account.id,
            account.name,
            account.kind,
            posting.currency_code,
            SUM(
              CASE
                WHEN account.kind = 'expense' AND posting.side = 'debit'
                  THEN posting.amount_minor
                WHEN account.kind = 'expense' AND posting.side = 'credit'
                  THEN -posting.amount_minor
                WHEN account.kind = 'income' AND posting.side = 'credit'
                  THEN posting.amount_minor
                WHEN account.kind = 'income' AND posting.side = 'debit'
                  THEN -posting.amount_minor
                ELSE 0
              END
            ) AS total_minor
          FROM postings AS posting
          JOIN ledger_transactions AS transaction_record
            ON transaction_record.owner_id = posting.owner_id
            AND transaction_record.id = posting.transaction_id
          JOIN ledger_accounts AS account
            ON account.owner_id = posting.owner_id
            AND account.id = posting.ledger_account_id
          JOIN filtered_roots AS filtered_root
            ON filtered_root.canonical_root_id = transaction_record.canonical_root_id
          WHERE transaction_record.owner_id = ?
            AND transaction_record.status = 'posted'
            AND transaction_record.local_date >= ?
            AND transaction_record.local_date < ?
            AND account.kind IN ('income', 'expense')
            AND (? IS NULL OR account.id = ?)
          GROUP BY account.id, account.name, account.kind, posting.currency_code
          ORDER BY account.kind, account.name, account.id
          """,
        arguments: reportArguments
      )

      var incomeMinorUnits: Int64 = 0
      var expenseMinorUnits: Int64 = 0
      var expenseCategories: [LedgerCategoryTotal] = []
      for row in rows {
        let idRawValue: String = row["id"]
        let kindRawValue: String = row["kind"]
        let currencyRawValue: String = row["currency_code"]
        let totalMinorUnits: Int64 = row["total_minor"]
        guard let accountID = UUID(uuidString: idRawValue),
          let kind = LedgerAccountKind(rawValue: kindRawValue),
          let currencyCode = CurrencyCode(rawValue: currencyRawValue),
          currencyCode == profile.baseCurrencyCode
        else {
          throw LedgerError.corruptedStoredLedger
        }
        switch kind {
        case .income:
          let (total, overflow) = incomeMinorUnits.addingReportingOverflow(totalMinorUnits)
          guard !overflow else { throw LedgerError.corruptedStoredLedger }
          incomeMinorUnits = total
        case .expense:
          let (total, overflow) = expenseMinorUnits.addingReportingOverflow(totalMinorUnits)
          guard !overflow else { throw LedgerError.corruptedStoredLedger }
          expenseMinorUnits = total
          expenseCategories.append(
            LedgerCategoryTotal(
              accountID: accountID,
              name: row["name"],
              total: SignedMoney(
                minorUnits: totalMinorUnits,
                currencyCode: currencyCode
              )
            )
          )
        case .asset, .liability, .equity:
          throw LedgerError.corruptedStoredLedger
        }
      }
      expenseCategories.sort {
        if $0.total.minorUnits == $1.total.minorUnits {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return $0.total.minorUnits > $1.total.minorUnits
      }
      let (netChangeMinorUnits, netOverflow) = incomeMinorUnits.subtractingReportingOverflow(
        expenseMinorUnits
      )
      guard !netOverflow else { throw LedgerError.corruptedStoredLedger }

      var trendArguments = Self.filterArguments(ownerID: ownerID, filter: filter)
      trendArguments += [
        ownerID.uuidString.lowercased(),
        trendStart.startLocalDate,
        month.endExclusiveLocalDate,
        filter.categoryAccountID?.uuidString.lowercased(),
        filter.categoryAccountID?.uuidString.lowercased(),
      ]
      let trendRows = try Row.fetchAll(
        database,
        sql: """
          WITH \(Self.filteredRootCommonTableExpression)
          SELECT
            substr(transaction_record.local_date, 1, 7) AS month_key,
            posting.currency_code,
            SUM(
              CASE
                WHEN posting.side = 'debit' THEN posting.amount_minor
                WHEN posting.side = 'credit' THEN -posting.amount_minor
                ELSE 0
              END
            ) AS total_minor
          FROM postings AS posting
          JOIN ledger_transactions AS transaction_record
            ON transaction_record.owner_id = posting.owner_id
            AND transaction_record.id = posting.transaction_id
          JOIN ledger_accounts AS account
            ON account.owner_id = posting.owner_id
            AND account.id = posting.ledger_account_id
          JOIN filtered_roots AS filtered_root
            ON filtered_root.canonical_root_id = transaction_record.canonical_root_id
          WHERE transaction_record.owner_id = ?
            AND transaction_record.status = 'posted'
            AND transaction_record.local_date >= ?
            AND transaction_record.local_date < ?
            AND account.kind = 'expense'
            AND (? IS NULL OR account.id = ?)
          GROUP BY month_key, posting.currency_code
          ORDER BY month_key
          """,
        arguments: trendArguments
      )
      var trendTotals: [String: Int64] = [:]
      for row in trendRows {
        let currencyRawValue: String = row["currency_code"]
        let monthKey: String = row["month_key"]
        guard CurrencyCode(rawValue: currencyRawValue) == profile.baseCurrencyCode,
          trendMonths.contains(where: { $0.key == monthKey })
        else {
          throw LedgerError.corruptedStoredLedger
        }
        trendTotals[monthKey] = row["total_minor"]
      }
      let expenseTrend = trendMonths.map { trendMonth in
        LedgerMonthlyExpenseTotal(
          month: trendMonth,
          expense: SignedMoney(
            minorUnits: trendTotals[trendMonth.key] ?? 0,
            currencyCode: profile.baseCurrencyCode
          )
        )
      }
      return LedgerMonthlyReport(
        month: month,
        income: SignedMoney(
          minorUnits: incomeMinorUnits,
          currencyCode: profile.baseCurrencyCode
        ),
        expense: SignedMoney(
          minorUnits: expenseMinorUnits,
          currencyCode: profile.baseCurrencyCode
        ),
        netChange: SignedMoney(
          minorUnits: netChangeMinorUnits,
          currencyCode: profile.baseCurrencyCode
        ),
        expenseCategories: expenseCategories,
        expenseTrend: expenseTrend
      )
    }
  }

  func accountSummaries(ownerID: UUID) async throws -> [LedgerAccountSummary] {
    try await database.pool.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT
            account.id,
            account.owner_id,
            account.parent_id,
            account.kind,
            account.subtype,
            account.name,
            account.native_currency_code,
            account.configuration_state,
            account.system_key,
            account.status,
            account.display_order,
            COALESCE(
              SUM(
                CASE
                  WHEN transaction_record.status <> 'posted' THEN 0
                  WHEN account.kind IN ('asset', 'expense') AND posting.side = 'debit'
                    THEN posting.amount_minor
                  WHEN account.kind IN ('asset', 'expense') AND posting.side = 'credit'
                    THEN -posting.amount_minor
                  WHEN account.kind IN ('liability', 'income', 'equity') AND posting.side = 'credit'
                    THEN posting.amount_minor
                  WHEN account.kind IN ('liability', 'income', 'equity') AND posting.side = 'debit'
                    THEN -posting.amount_minor
                  ELSE 0
                END
              ),
              0
            ) AS balance_minor
          FROM ledger_accounts AS account
          LEFT JOIN postings AS posting
            ON posting.owner_id = account.owner_id
            AND posting.ledger_account_id = account.id
          LEFT JOIN ledger_transactions AS transaction_record
            ON transaction_record.owner_id = posting.owner_id
            AND transaction_record.id = posting.transaction_id
          WHERE account.owner_id = ?
          GROUP BY
            account.id,
            account.owner_id,
            account.parent_id,
            account.kind,
            account.subtype,
            account.name,
            account.native_currency_code,
            account.configuration_state,
            account.system_key,
            account.status,
            account.display_order
          ORDER BY account.kind, account.display_order, account.name, account.id
          """,
        arguments: [ownerID.uuidString.lowercased()]
      )
      return try rows.map { row in
        let account = try Self.account(from: row)
        return LedgerAccountSummary(
          account: account,
          balance: SignedMoney(
            minorUnits: row["balance_minor"],
            currencyCode: account.nativeCurrencyCode
          )
        )
      }
    }
  }

  func transactionRoot(
    ownerID: UUID,
    rootID: UUID
  ) async throws -> LedgerTransactionRootSnapshot {
    try await database.pool.read { database in
      let context = try Self.fetchCanonicalRootContext(
        database: database,
        ownerID: ownerID,
        rootID: rootID
      )
      let availableRefundMinorUnits: Int64?
      if context.currentTransaction.kind == .expense,
        let amount = context.currentTransaction.postings.first?.money.minorUnits
      {
        let (available, overflow) = amount.subtractingReportingOverflow(
          context.activeRefundMinorUnits
        )
        guard !overflow, available >= 0 else {
          throw LedgerError.corruptedStoredLedger
        }
        availableRefundMinorUnits = available
      } else {
        availableRefundMinorUnits = nil
      }
      return LedgerTransactionRootSnapshot(
        rootID: rootID,
        rootRevision: context.rootRevision,
        currentTransaction: context.currentTransaction,
        activeRefundMinorUnits: context.activeRefundMinorUnits,
        availableRefundMinorUnits: availableRefundMinorUnits,
        isCurrentReversed: context.isCurrentReversed,
        transactions: context.transactions
      )
    }
  }

  private static let filteredRootCommonTableExpression = """
    current_transactions AS (
      SELECT candidate.*
      FROM ledger_transactions AS candidate
      WHERE candidate.owner_id = ?
        AND candidate.status = 'posted'
        AND candidate.kind NOT IN ('refund', 'reversal')
        AND NOT EXISTS (
          SELECT 1
          FROM ledger_transactions AS replacement
          WHERE replacement.owner_id = candidate.owner_id
            AND replacement.status = 'posted'
            AND replacement.replacement_for_id = candidate.id
        )
    ),
    filtered_roots AS (
      SELECT current_transaction.canonical_root_id
      FROM current_transactions AS current_transaction
      JOIN postings AS first_posting
        ON first_posting.owner_id = current_transaction.owner_id
        AND first_posting.transaction_id = current_transaction.id
        AND first_posting.sequence = 0
      WHERE (
          ? = 0
          OR current_transaction.payee LIKE ? ESCAPE '!'
          OR current_transaction.note LIKE ? ESCAPE '!'
          OR (? IS NOT NULL AND first_posting.amount_minor = ?)
        )
        AND (
          ? IS NULL
          OR EXISTS (
            SELECT 1
            FROM postings AS funding_posting
            JOIN ledger_accounts AS funding_account
              ON funding_account.owner_id = funding_posting.owner_id
              AND funding_account.id = funding_posting.ledger_account_id
            WHERE funding_posting.owner_id = current_transaction.owner_id
              AND funding_posting.transaction_id = current_transaction.id
              AND funding_posting.ledger_account_id = ?
              AND funding_account.kind IN ('asset', 'liability')
          )
        )
        AND (
          ? IS NULL
          OR EXISTS (
            SELECT 1
            FROM postings AS category_posting
            JOIN ledger_accounts AS category_account
              ON category_account.owner_id = category_posting.owner_id
              AND category_account.id = category_posting.ledger_account_id
            WHERE category_posting.owner_id = current_transaction.owner_id
              AND category_posting.transaction_id = current_transaction.id
              AND category_posting.ledger_account_id = ?
              AND category_account.kind IN ('income', 'expense')
          )
        )
        AND (
          ? = 'any'
          OR (
            ? = 'linked'
            AND EXISTS (
              SELECT 1
              FROM transaction_journey_links AS journey_link
              WHERE journey_link.owner_id = current_transaction.owner_id
                AND journey_link.transaction_root_id = current_transaction.canonical_root_id
            )
          )
          OR (
            ? = 'unlinked'
            AND NOT EXISTS (
              SELECT 1
              FROM transaction_journey_links AS journey_link
              WHERE journey_link.owner_id = current_transaction.owner_id
                AND journey_link.transaction_root_id = current_transaction.canonical_root_id
            )
          )
        )
    )
    """

  private static func filterArguments(
    ownerID: UUID,
    filter: LedgerTransactionFilter
  ) -> StatementArguments {
    let escapedSearchText = filter.searchText
      .replacingOccurrences(of: "!", with: "!!")
      .replacingOccurrences(of: "%", with: "!%")
      .replacingOccurrences(of: "_", with: "!_")
    let searchPattern = "%\(escapedSearchText)%"
    let fundingAccountID = filter.fundingAccountID?.uuidString.lowercased()
    let categoryAccountID = filter.categoryAccountID?.uuidString.lowercased()
    return [
      ownerID.uuidString.lowercased(),
      filter.searchText.isEmpty ? 0 : 1,
      searchPattern,
      searchPattern,
      filter.amountMinorUnits,
      filter.amountMinorUnits,
      fundingAccountID,
      fundingAccountID,
      categoryAccountID,
      categoryAccountID,
      filter.journeyLink.rawValue,
      filter.journeyLink.rawValue,
      filter.journeyLink.rawValue,
    ]
  }

  private static func fetchTransactionSummaries(
    database: Database,
    ownerID: UUID,
    filter: LedgerTransactionFilter,
    limit: Int
  ) throws -> [LedgerTransactionSummary] {
    var arguments = filterArguments(ownerID: ownerID, filter: filter)
    arguments += [limit]
    let rows = try Row.fetchAll(
      database,
      sql: """
        WITH \(filteredRootCommonTableExpression)
        SELECT
          current_transaction.canonical_root_id,
          current_transaction.id AS current_transaction_id,
          root_transaction.local_root_revision AS root_revision,
          current_transaction.kind,
          current_transaction.occurred_at,
          current_transaction.local_date,
          current_transaction.payee,
          first_posting.amount_minor,
          first_posting.currency_code,
          EXISTS(
            SELECT 1
            FROM ledger_transactions AS current_reversal
            WHERE current_reversal.owner_id = current_transaction.owner_id
              AND current_reversal.status = 'posted'
              AND current_reversal.kind = 'reversal'
              AND current_reversal.reversal_of_id = current_transaction.id
          ) AS is_reversed,
          COALESCE(
            (
              SELECT SUM(refund_posting.amount_minor)
              FROM ledger_transactions AS refund
              JOIN postings AS refund_posting
                ON refund_posting.transaction_id = refund.id
                AND refund_posting.sequence = 0
              WHERE refund.owner_id = current_transaction.owner_id
                AND refund.canonical_root_id = current_transaction.canonical_root_id
                AND refund.status = 'posted'
                AND refund.kind = 'refund'
                AND NOT EXISTS (
                  SELECT 1
                  FROM ledger_transactions AS refund_reversal
                  WHERE refund_reversal.owner_id = refund.owner_id
                    AND refund_reversal.status = 'posted'
                    AND refund_reversal.kind = 'reversal'
                    AND refund_reversal.reversal_of_id = refund.id
                )
            ),
            0
          ) AS active_refund_minor
        FROM current_transactions AS current_transaction
        JOIN filtered_roots AS filtered_root
          ON filtered_root.canonical_root_id = current_transaction.canonical_root_id
        JOIN ledger_transactions AS root_transaction
          ON root_transaction.owner_id = current_transaction.owner_id
          AND root_transaction.id = current_transaction.canonical_root_id
        JOIN postings AS first_posting
          ON first_posting.transaction_id = current_transaction.id
          AND first_posting.sequence = 0
        ORDER BY current_transaction.occurred_at DESC,
          current_transaction.canonical_root_id DESC
        LIMIT ?
        """,
      arguments: arguments
    )
    return try rows.map { row in
      let rootIDRawValue: String = row["canonical_root_id"]
      let currentTransactionIDRawValue: String = row["current_transaction_id"]
      let kindRawValue: String = row["kind"]
      let currencyRawValue: String = row["currency_code"]
      guard let rootID = UUID(uuidString: rootIDRawValue),
        let currentTransactionID = UUID(uuidString: currentTransactionIDRawValue),
        let kind = LedgerTransactionKind(rawValue: kindRawValue),
        let currencyCode = CurrencyCode(rawValue: currencyRawValue)
      else {
        throw LedgerError.corruptedStoredLedger
      }
      return LedgerTransactionSummary(
        rootID: rootID,
        currentTransactionID: currentTransactionID,
        rootRevision: row["root_revision"],
        kind: kind,
        occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
        localDate: row["local_date"],
        payee: row["payee"],
        money: try PositiveMoney(
          minorUnits: row["amount_minor"],
          currencyCode: currencyCode
        ),
        isReversed: (row["is_reversed"] as Int) == 1,
        activeRefundMinorUnits: row["active_refund_minor"]
      )
    }
  }

  private static func fetchCanonicalRootContext(
    database: Database,
    ownerID: UUID,
    rootID: UUID
  ) throws -> CanonicalRootContext {
    guard
      let rootRow = try Row.fetchOne(
        database,
        sql: """
          SELECT canonical_root_id, local_root_revision
          FROM ledger_transactions
          WHERE id = ? AND owner_id = ? AND status = 'posted'
          """,
        arguments: [
          rootID.uuidString.lowercased(),
          ownerID.uuidString.lowercased(),
        ]
      )
    else {
      throw LedgerError.canonicalRootNotFound(rootID)
    }
    let storedRootID: String = rootRow["canonical_root_id"]
    let rootRevision: Int = rootRow["local_root_revision"]
    guard storedRootID == rootID.uuidString.lowercased(), rootRevision >= 1 else {
      throw LedgerError.inconsistentCanonicalRoot
    }

    let transactionIDs = try String.fetchAll(
      database,
      sql: """
        SELECT id
        FROM ledger_transactions
        WHERE owner_id = ? AND canonical_root_id = ? AND status = 'posted'
        ORDER BY created_at, id
        """,
      arguments: [
        ownerID.uuidString.lowercased(),
        rootID.uuidString.lowercased(),
      ]
    )
    let transactions = try transactionIDs.map { rawValue -> PostedLedgerTransaction in
      guard let transactionID = UUID(uuidString: rawValue) else {
        throw LedgerError.corruptedStoredLedger
      }
      let transaction = try fetchPostedTransaction(
        database: database,
        transactionID: transactionID
      )
      guard transaction.ownerID == ownerID, transaction.canonicalRootID == rootID else {
        throw LedgerError.inconsistentCanonicalRoot
      }
      return transaction
    }
    let replacedTransactionIDs = Set(transactions.compactMap(\.replacementForID))
    let currentCandidates = transactions.filter {
      $0.kind != .refund
        && $0.kind != .reversal
        && !replacedTransactionIDs.contains($0.id)
    }
    guard currentCandidates.count == 1, let current = currentCandidates.first else {
      throw LedgerError.inconsistentCanonicalRoot
    }
    let reversedTransactionIDs = Set(transactions.compactMap(\.reversalOfID))
    let activeRefunds = transactions.filter {
      $0.kind == .refund && !reversedTransactionIDs.contains($0.id)
    }
    var activeRefundMinorUnits: Int64 = 0
    for refund in activeRefunds {
      guard let money = refund.postings.first?.money,
        refund.postings.allSatisfy({ $0.money == money })
      else {
        throw LedgerError.corruptedStoredLedger
      }
      let (sum, overflow) = activeRefundMinorUnits.addingReportingOverflow(
        money.minorUnits
      )
      guard !overflow else {
        throw LedgerError.corruptedStoredLedger
      }
      activeRefundMinorUnits = sum
    }

    return CanonicalRootContext(
      rootRevision: rootRevision,
      currentTransaction: current,
      activeRefunds: activeRefunds,
      activeRefundMinorUnits: activeRefundMinorUnits,
      isCurrentReversed: reversedTransactionIDs.contains(current.id),
      transactions: transactions
    )
  }

  private static func validate(
    context: CanonicalRootContext,
    rootID: UUID,
    currentTransactionID: UUID,
    expectedRootRevision: Int
  ) throws {
    guard context.currentTransaction.canonicalRootID == rootID else {
      throw LedgerError.inconsistentCanonicalRoot
    }
    guard context.rootRevision == expectedRootRevision else {
      throw LedgerError.rootRevisionConflict(
        expected: expectedRootRevision,
        actual: context.rootRevision
      )
    }
    guard context.currentTransaction.id == currentTransactionID else {
      throw LedgerError.transactionNotCurrent(currentTransactionID)
    }
  }

  private static func advanceRootRevision(
    database: Database,
    ownerID: UUID,
    rootID: UUID,
    expectedRevision: Int,
    updatedAt: Date
  ) throws -> Int {
    let (nextRevision, overflow) = expectedRevision.addingReportingOverflow(1)
    guard !overflow else {
      throw LedgerError.inconsistentCanonicalRoot
    }
    try database.execute(
      sql: """
        UPDATE ledger_transactions
        SET local_root_revision = ?, updated_at = ?
        WHERE id = ? AND owner_id = ? AND local_root_revision = ?
        """,
      arguments: [
        nextRevision,
        updatedAt.timeIntervalSince1970,
        rootID.uuidString.lowercased(),
        ownerID.uuidString.lowercased(),
        expectedRevision,
      ]
    )
    guard database.changesCount == 1 else {
      let actual = try Int.fetchOne(
        database,
        sql: "SELECT local_root_revision FROM ledger_transactions WHERE id = ? AND owner_id = ?",
        arguments: [
          rootID.uuidString.lowercased(),
          ownerID.uuidString.lowercased(),
        ]
      )
      if let actual {
        throw LedgerError.rootRevisionConflict(
          expected: expectedRevision,
          actual: actual
        )
      }
      throw LedgerError.canonicalRootNotFound(rootID)
    }
    return nextRevision
  }

  private static func validateFundingAccount(
    _ account: LedgerAccount,
    currencyCode: CurrencyCode
  ) throws {
    guard account.status == .active else {
      throw LedgerError.accountArchived(account.id)
    }
    guard account.configurationState == .ready else {
      throw LedgerError.accountNotReady(account.id)
    }
    guard account.kind == .asset || account.kind == .liability else {
      throw LedgerError.invalidAccountKind(account.id)
    }
    guard account.nativeCurrencyCode == currencyCode else {
      throw LedgerError.accountCurrencyMismatch(account.id)
    }
  }

  private static func expenseCategoryPosting(
    database: Database,
    transaction: PostedLedgerTransaction
  ) throws -> LedgerPosting {
    let matches = try transaction.postings.filter { posting in
      guard posting.side == .debit,
        let account = try fetchAccount(
          database: database,
          ownerID: transaction.ownerID,
          accountID: posting.accountID
        )
      else {
        return false
      }
      return account.kind == .expense
    }
    guard matches.count == 1, let posting = matches.first else {
      throw LedgerError.corruptedStoredLedger
    }
    return posting
  }

  private static func insertPostedTransaction(
    database: Database,
    id: UUID,
    ownerID: UUID,
    kind: LedgerTransactionKind,
    rootID: UUID,
    rootRevision: Int,
    occurredAt: Date,
    originalTimeZoneIdentifier: String,
    localDate: String,
    payee: String?,
    note: String?,
    source: LedgerTransactionSource = .manual,
    postedAt: Date,
    refundOfID: UUID? = nil,
    reversalOfID: UUID? = nil,
    replacementForID: UUID? = nil,
    correctionGroupID: UUID? = nil
  ) throws {
    let timestamp = postedAt.timeIntervalSince1970
    try database.execute(
      sql: """
        INSERT INTO ledger_transactions (
          id,
          owner_id,
          status,
          kind,
          canonical_root_id,
          local_root_revision,
          occurred_at,
          original_timezone_id,
          local_date,
          payee,
          note,
          source_type,
          posted_at,
          refund_of_id,
          reversal_of_id,
          replacement_for_id,
          correction_group_id,
          created_at,
          updated_at
        ) VALUES (?, ?, 'posted', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        id.uuidString.lowercased(),
        ownerID.uuidString.lowercased(),
        kind.rawValue,
        rootID.uuidString.lowercased(),
        rootRevision,
        occurredAt.timeIntervalSince1970,
        originalTimeZoneIdentifier,
        localDate,
        payee,
        note,
        source.rawValue,
        timestamp,
        refundOfID?.uuidString.lowercased(),
        reversalOfID?.uuidString.lowercased(),
        replacementForID?.uuidString.lowercased(),
        correctionGroupID?.uuidString.lowercased(),
        timestamp,
        timestamp,
      ]
    )
  }

  private static func insertPostings(
    database: Database,
    ownerID: UUID,
    transactionID: UUID,
    blueprints: [LedgerPostingBlueprint],
    createdAt: Date
  ) throws {
    guard LedgerPostingPlan.isBalanced(blueprints) else {
      throw LedgerError.unbalancedPostings
    }
    for blueprint in blueprints {
      try database.execute(
        sql: """
          INSERT INTO postings (
            id,
            owner_id,
            transaction_id,
            ledger_account_id,
            side,
            amount_minor,
            currency_code,
            memo,
            sequence,
            created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
          """,
        arguments: [
          UUID().uuidString.lowercased(),
          ownerID.uuidString.lowercased(),
          transactionID.uuidString.lowercased(),
          blueprint.accountID.uuidString.lowercased(),
          blueprint.side.rawValue,
          blueprint.money.minorUnits,
          blueprint.money.currencyCode.rawValue,
          blueprint.sequence,
          createdAt.timeIntervalSince1970,
        ]
      )
    }
  }

  private static func oppositePostings(
    of transaction: PostedLedgerTransaction
  ) -> [LedgerPostingBlueprint] {
    transaction.postings.map { posting in
      LedgerPostingBlueprint(
        accountID: posting.accountID,
        side: posting.side == .debit ? .credit : .debit,
        money: posting.money,
        sequence: posting.sequence
      )
    }
  }

  private static func correctionCommandExists(
    database: Database,
    request: CorrectLedgerTransactionRequest
  ) throws -> Bool {
    try Bool.fetchOne(
      database,
      sql: """
        SELECT EXISTS(
          SELECT 1
          FROM ledger_transactions
          WHERE id IN (?, ?) OR correction_group_id = ?
        )
        """,
      arguments: [
        request.reversalTransactionID.uuidString.lowercased(),
        request.replacementTransactionID.uuidString.lowercased(),
        request.correctionGroupID.uuidString.lowercased(),
      ]
    ) ?? false
  }

  private static func fetchProfile(
    database: Database,
    ownerID: UUID
  ) throws -> LocalLedgerProfile? {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT id, base_currency_code, base_currency_state
          FROM local_profiles
          WHERE id = ?
          """,
        arguments: [ownerID.uuidString.lowercased()]
      )
    else {
      return nil
    }

    let identifier: String = row["id"]
    let currencyRawValue: String = row["base_currency_code"]
    let stateRawValue: String = row["base_currency_state"]
    guard let id = UUID(uuidString: identifier),
      let currencyCode = CurrencyCode(rawValue: currencyRawValue),
      let state = BaseCurrencyState(rawValue: stateRawValue)
    else {
      throw LedgerError.inconsistentLocalProfile
    }
    return LocalLedgerProfile(
      id: id,
      baseCurrencyCode: currencyCode,
      baseCurrencyState: state
    )
  }

  private static func fetchAccount(
    database: Database,
    ownerID: UUID,
    accountID: UUID
  ) throws -> LedgerAccount? {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT
            id,
            owner_id,
            parent_id,
            kind,
            subtype,
            name,
            native_currency_code,
            configuration_state,
            system_key,
            status,
            display_order
          FROM ledger_accounts
          WHERE id = ? AND owner_id = ?
          """,
        arguments: [
          accountID.uuidString.lowercased(),
          ownerID.uuidString.lowercased(),
        ]
      )
    else {
      return nil
    }

    return try account(from: row)
  }

  private static func account(from row: Row) throws -> LedgerAccount {
    let idRawValue: String = row["id"]
    let ownerIDRawValue: String = row["owner_id"]
    let parentIDRawValue: String? = row["parent_id"]
    let kindRawValue: String = row["kind"]
    let subtypeRawValue: String = row["subtype"]
    let currencyRawValue: String = row["native_currency_code"]
    let configurationRawValue: String = row["configuration_state"]
    let statusRawValue: String = row["status"]
    guard let id = UUID(uuidString: idRawValue),
      let storedOwnerID = UUID(uuidString: ownerIDRawValue),
      let kind = LedgerAccountKind(rawValue: kindRawValue),
      let subtype = LedgerAccountSubtype(rawValue: subtypeRawValue),
      let currencyCode = CurrencyCode(rawValue: currencyRawValue),
      let configurationState = LedgerAccountConfigurationState(
        rawValue: configurationRawValue
      ),
      let status = LedgerAccountStatus(rawValue: statusRawValue)
    else {
      throw LedgerError.corruptedStoredLedger
    }
    let parentID: UUID?
    if let parentIDRawValue {
      guard let parsedParentID = UUID(uuidString: parentIDRawValue) else {
        throw LedgerError.corruptedStoredLedger
      }
      parentID = parsedParentID
    } else {
      parentID = nil
    }
    return LedgerAccount(
      id: id,
      ownerID: storedOwnerID,
      parentID: parentID,
      kind: kind,
      subtype: subtype,
      name: row["name"],
      nativeCurrencyCode: currencyCode,
      configurationState: configurationState,
      systemKey: row["system_key"],
      status: status,
      displayOrder: row["display_order"]
    )
  }

  private static func accountIdentifierExists(
    database: Database,
    accountID: UUID
  ) throws -> Bool {
    try Bool.fetchOne(
      database,
      sql: "SELECT EXISTS(SELECT 1 FROM ledger_accounts WHERE id = ?)",
      arguments: [accountID.uuidString.lowercased()]
    ) ?? false
  }

  private static func transactionExists(
    database: Database,
    transactionID: UUID
  ) throws -> Bool {
    try Bool.fetchOne(
      database,
      sql: "SELECT EXISTS(SELECT 1 FROM ledger_transactions WHERE id = ?)",
      arguments: [transactionID.uuidString.lowercased()]
    ) ?? false
  }

  private static func fetchPostedTransaction(
    database: Database,
    transactionID: UUID
  ) throws -> PostedLedgerTransaction {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT
            id,
            owner_id,
            status,
            kind,
            canonical_root_id,
            local_root_revision,
            occurred_at,
            original_timezone_id,
            local_date,
            payee,
            note,
            source_type,
            posted_at,
            refund_of_id,
            reversal_of_id,
            replacement_for_id,
            correction_group_id
          FROM ledger_transactions
          WHERE id = ?
          """,
        arguments: [transactionID.uuidString.lowercased()]
      )
    else {
      throw LedgerError.corruptedStoredLedger
    }

    let idRawValue: String = row["id"]
    let ownerIDRawValue: String = row["owner_id"]
    let status: String = row["status"]
    let kindRawValue: String = row["kind"]
    let rootIDRawValue: String = row["canonical_root_id"]
    let sourceType: String = row["source_type"]
    let postedAtInterval: Double? = row["posted_at"]
    let refundOfID = try Self.optionalUUID(row["refund_of_id"] as String?)
    let reversalOfID = try Self.optionalUUID(row["reversal_of_id"] as String?)
    let replacementForID = try Self.optionalUUID(row["replacement_for_id"] as String?)
    let correctionGroupID = try Self.optionalUUID(row["correction_group_id"] as String?)
    guard status == "posted",
      let id = UUID(uuidString: idRawValue),
      let ownerID = UUID(uuidString: ownerIDRawValue),
      let kind = LedgerTransactionKind(rawValue: kindRawValue),
      let source = LedgerTransactionSource(rawValue: sourceType),
      let rootID = UUID(uuidString: rootIDRawValue),
      let postedAtInterval
    else {
      throw LedgerError.corruptedStoredLedger
    }

    let postingRows = try Row.fetchAll(
      database,
      sql: """
        SELECT id, ledger_account_id, side, amount_minor, currency_code, sequence
        FROM postings
        WHERE transaction_id = ?
        ORDER BY sequence, id
        """,
      arguments: [transactionID.uuidString.lowercased()]
    )
    let postings = try postingRows.map { postingRow in
      let postingIDRawValue: String = postingRow["id"]
      let accountIDRawValue: String = postingRow["ledger_account_id"]
      let sideRawValue: String = postingRow["side"]
      let amountMinor: Int64 = postingRow["amount_minor"]
      let currencyRawValue: String = postingRow["currency_code"]
      guard let postingID = UUID(uuidString: postingIDRawValue),
        let accountID = UUID(uuidString: accountIDRawValue),
        let side = LedgerPostingSide(rawValue: sideRawValue),
        let currencyCode = CurrencyCode(rawValue: currencyRawValue)
      else {
        throw LedgerError.corruptedStoredLedger
      }
      return LedgerPosting(
        id: postingID,
        transactionID: id,
        accountID: accountID,
        side: side,
        money: try PositiveMoney(
          minorUnits: amountMinor,
          currencyCode: currencyCode
        ),
        sequence: postingRow["sequence"]
      )
    }
    let blueprints = postings.map {
      LedgerPostingBlueprint(
        accountID: $0.accountID,
        side: $0.side,
        money: $0.money,
        sequence: $0.sequence
      )
    }
    guard LedgerPostingPlan.isBalanced(blueprints) else {
      throw LedgerError.corruptedStoredLedger
    }

    return PostedLedgerTransaction(
      id: id,
      ownerID: ownerID,
      kind: kind,
      canonicalRootID: rootID,
      localRootRevision: row["local_root_revision"],
      occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
      originalTimeZoneIdentifier: row["original_timezone_id"],
      localDate: row["local_date"],
      payee: row["payee"],
      note: row["note"],
      source: source,
      postedAt: Date(timeIntervalSince1970: postedAtInterval),
      refundOfID: refundOfID,
      reversalOfID: reversalOfID,
      replacementForID: replacementForID,
      correctionGroupID: correctionGroupID,
      postings: postings
    )
  }

  private static func optionalUUID(_ rawValue: String?) throws -> UUID? {
    guard let rawValue else { return nil }
    guard let identifier = UUID(uuidString: rawValue) else {
      throw LedgerError.corruptedStoredLedger
    }
    return identifier
  }

  private static func matches(
    _ transaction: PostedLedgerTransaction,
    request: CreateLedgerTransactionRequest
  ) -> Bool {
    let expectedPostings: [(UUID, LedgerPostingSide)]
    switch request.details {
    case .expense(let paymentAccountID, let categoryAccountID):
      expectedPostings = [(categoryAccountID, .debit), (paymentAccountID, .credit)]
    case .income(let receivingAccountID, let categoryAccountID):
      expectedPostings = [(receivingAccountID, .debit), (categoryAccountID, .credit)]
    case .transfer(let sourceAccountID, let destinationAccountID):
      expectedPostings = [(destinationAccountID, .debit), (sourceAccountID, .credit)]
    }

    return transaction.id == request.transactionID
      && transaction.ownerID == request.ownerID
      && transaction.kind == request.details.kind
      && transaction.canonicalRootID == request.transactionID
      && transaction.occurredAt == request.occurredAt
      && transaction.originalTimeZoneIdentifier == request.originalTimeZoneIdentifier
      && transaction.localDate == request.localDate
      && transaction.payee == request.payee
      && transaction.note == request.note
      && transaction.source == request.source
      && transaction.postedAt == request.submittedAt
      && transaction.postings.count == expectedPostings.count
      && zip(transaction.postings, expectedPostings).allSatisfy { posting, expected in
        posting.accountID == expected.0
          && posting.side == expected.1
          && posting.money == request.money
      }
  }

  private static func matches(
    _ transaction: PostedLedgerTransaction,
    refundRequest request: RefundLedgerTransactionRequest,
    target: PostedLedgerTransaction
  ) -> Bool {
    guard target.kind == .expense,
      target.id == request.currentTransactionID,
      target.canonicalRootID == request.rootID,
      target.postings.count == 2,
      transaction.postings.count == 2
    else {
      return false
    }
    let categoryPosting = target.postings[0]
    let destinationPosting = transaction.postings[0]
    let refundCategoryPosting = transaction.postings[1]
    return transaction.id == request.transactionID
      && transaction.ownerID == request.ownerID
      && transaction.kind == .refund
      && transaction.canonicalRootID == request.rootID
      && transaction.localRootRevision == request.expectedRootRevision + 1
      && transaction.occurredAt == request.occurredAt
      && transaction.originalTimeZoneIdentifier == request.originalTimeZoneIdentifier
      && transaction.localDate == request.localDate
      && transaction.payee == target.payee
      && transaction.note == request.note
      && transaction.postedAt == request.submittedAt
      && transaction.refundOfID == target.id
      && transaction.reversalOfID == nil
      && transaction.replacementForID == nil
      && transaction.correctionGroupID == nil
      && destinationPosting.accountID == request.destinationAccountID
      && destinationPosting.side == .debit
      && destinationPosting.money == request.money
      && refundCategoryPosting.accountID == categoryPosting.accountID
      && refundCategoryPosting.side == .credit
      && refundCategoryPosting.money == request.money
  }

  private static func matches(
    _ transaction: PostedLedgerTransaction,
    reverseRequest request: ReverseLedgerTransactionRequest,
    target: PostedLedgerTransaction
  ) -> Bool {
    let expectedPostings = oppositePostings(of: target)
    return transaction.id == request.transactionID
      && transaction.ownerID == request.ownerID
      && transaction.kind == .reversal
      && transaction.canonicalRootID == request.rootID
      && transaction.localRootRevision == request.expectedRootRevision + 1
      && transaction.occurredAt == request.occurredAt
      && transaction.originalTimeZoneIdentifier == request.originalTimeZoneIdentifier
      && transaction.localDate == request.localDate
      && transaction.payee == target.payee
      && transaction.note == request.reason
      && transaction.postedAt == request.submittedAt
      && transaction.refundOfID == nil
      && transaction.reversalOfID == target.id
      && transaction.replacementForID == nil
      && transaction.correctionGroupID == nil
      && postingsMatch(transaction.postings, expected: expectedPostings)
  }

  private static func matches(
    reversal: PostedLedgerTransaction,
    replacement: PostedLedgerTransaction,
    correctionRequest request: CorrectLedgerTransactionRequest,
    target: PostedLedgerTransaction
  ) throws -> Bool {
    let expectedReplacementPostings: [LedgerPostingBlueprint]
    switch request.replacementDetails {
    case .expense(let paymentAccountID, let categoryAccountID):
      expectedReplacementPostings = [
        LedgerPostingBlueprint(
          accountID: categoryAccountID,
          side: .debit,
          money: request.replacementMoney,
          sequence: 0
        ),
        LedgerPostingBlueprint(
          accountID: paymentAccountID,
          side: .credit,
          money: request.replacementMoney,
          sequence: 1
        ),
      ]
    case .income(let receivingAccountID, let categoryAccountID):
      expectedReplacementPostings = [
        LedgerPostingBlueprint(
          accountID: receivingAccountID,
          side: .debit,
          money: request.replacementMoney,
          sequence: 0
        ),
        LedgerPostingBlueprint(
          accountID: categoryAccountID,
          side: .credit,
          money: request.replacementMoney,
          sequence: 1
        ),
      ]
    case .transfer(let sourceAccountID, let destinationAccountID):
      expectedReplacementPostings = [
        LedgerPostingBlueprint(
          accountID: destinationAccountID,
          side: .debit,
          money: request.replacementMoney,
          sequence: 0
        ),
        LedgerPostingBlueprint(
          accountID: sourceAccountID,
          side: .credit,
          money: request.replacementMoney,
          sequence: 1
        ),
      ]
    }
    let nextRevision = request.expectedRootRevision + 1
    return target.id == request.currentTransactionID
      && target.canonicalRootID == request.rootID
      && reversal.id == request.reversalTransactionID
      && reversal.ownerID == request.ownerID
      && reversal.kind == .reversal
      && reversal.canonicalRootID == request.rootID
      && reversal.localRootRevision == nextRevision
      && reversal.occurredAt == target.occurredAt
      && reversal.originalTimeZoneIdentifier == target.originalTimeZoneIdentifier
      && reversal.localDate == target.localDate
      && reversal.payee == target.payee
      && reversal.note == target.note
      && reversal.postedAt == request.submittedAt
      && reversal.refundOfID == nil
      && reversal.reversalOfID == target.id
      && reversal.replacementForID == nil
      && reversal.correctionGroupID == request.correctionGroupID
      && postingsMatch(reversal.postings, expected: oppositePostings(of: target))
      && replacement.id == request.replacementTransactionID
      && replacement.ownerID == request.ownerID
      && replacement.kind == request.replacementDetails.kind
      && replacement.canonicalRootID == request.rootID
      && replacement.localRootRevision == nextRevision
      && replacement.occurredAt == request.replacementOccurredAt
      && replacement.originalTimeZoneIdentifier == request.originalTimeZoneIdentifier
      && replacement.localDate == request.replacementLocalDate
      && replacement.payee == request.payee
      && replacement.note == request.note
      && replacement.postedAt == request.submittedAt
      && replacement.refundOfID == nil
      && replacement.reversalOfID == nil
      && replacement.replacementForID == target.id
      && replacement.correctionGroupID == request.correctionGroupID
      && postingsMatch(replacement.postings, expected: expectedReplacementPostings)
  }

  private static func postingsMatch(
    _ postings: [LedgerPosting],
    expected: [LedgerPostingBlueprint]
  ) -> Bool {
    postings.count == expected.count
      && zip(postings, expected).allSatisfy { posting, blueprint in
        posting.accountID == blueprint.accountID
          && posting.side == blueprint.side
          && posting.money == blueprint.money
          && posting.sequence == blueprint.sequence
      }
  }
}
