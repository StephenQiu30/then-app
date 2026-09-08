import Foundation
import GRDB
import Testing

@testable import ThenApp

@Suite("本地账务仓储")
struct GRDBLedgerRepositoryTests {
  @Test("本位币确认原子更新资料和账户且不可静默改币")
  func baseCurrencyConfirmationIsAtomicAndIdempotent() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      let useCase = ConfirmBaseCurrencyUseCase(repository: repository)
      let usd = try CurrencyCode(validating: "USD")
      let confirmedAt = Date(timeIntervalSince1970: 1_786_287_100)

      let first = try await useCase.execute(
        ownerID: identity.profileID,
        currencyCode: usd,
        confirmedAt: confirmedAt
      )
      let repeated = try await useCase.execute(
        ownerID: identity.profileID,
        currencyCode: usd,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_200)
      )

      #expect(first.baseCurrencyState == .confirmed)
      #expect(first.baseCurrencyCode == usd)
      #expect(repeated == first)

      let accountStates = try await database.pool.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT native_currency_code, configuration_state
            FROM ledger_accounts
            ORDER BY system_key
            """
        ).map { row in
          (row["native_currency_code"] as String, row["configuration_state"] as String)
        }
      }
      #expect(accountStates.count == 11)
      #expect(accountStates.allSatisfy { $0 == ("USD", "ready") })

      let relaunchedIdentity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_250)
      )
      #expect(relaunchedIdentity.profileID == identity.profileID)
      #expect(relaunchedIdentity.baseCurrencyCode == usd)
      #expect(relaunchedIdentity.baseCurrencyState == .confirmed)

      do {
        _ = try await useCase.execute(
          ownerID: identity.profileID,
          currencyCode: .cny,
          confirmedAt: Date(timeIntervalSince1970: 1_786_287_300)
        )
        Issue.record("已经确认的本位币不应被静默修改")
      } catch let error as LedgerError {
        #expect(error == .baseCurrencyAlreadyConfirmed)
      }
    }
  }

  @Test("首笔支出必须先确认本币并以两条分录原子发布")
  func expenseRequiresConfirmedCurrencyAndPostsAtomically() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let expenseCategoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.uncategorized"
      )
      let repository = GRDBLedgerRepository(database: database)
      let useCase = CreateTransactionUseCase(repository: repository)
      let transactionID = UUID()
      let occurredAt = Date(timeIntervalSince1970: 1_786_377_000)
      let submittedAt = Date(timeIntervalSince1970: 1_786_377_100)
      let request = try CreateLedgerTransactionRequest(
        transactionID: transactionID,
        ownerID: identity.profileID,
        details: .expense(
          paymentAccountID: identity.defaultCashAccountID,
          categoryAccountID: expenseCategoryID
        ),
        money: PositiveMoney(minorUnits: 1_250, currencyCode: .cny),
        occurredAt: occurredAt,
        originalTimeZoneIdentifier: "Asia/Shanghai",
        payee: "  合成测试商户  ",
        note: "  ",
        submittedAt: submittedAt
      )

      do {
        _ = try await useCase.execute(request)
        Issue.record("未确认本币不应发布正式交易")
      } catch let error as LedgerError {
        #expect(error == .baseCurrencyNotConfirmed)
      }
      let failedCounts = try ledgerRowCounts(database: database)
      #expect(failedCounts == (0, 0))

      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_050)
      )
      let transaction = try await useCase.execute(request)
      let repeated = try await useCase.execute(request)

      #expect(transaction == repeated)
      #expect(transaction.id == transactionID)
      #expect(transaction.kind == .expense)
      #expect(transaction.canonicalRootID == transactionID)
      #expect(transaction.localRootRevision == 1)
      #expect(transaction.localDate == "2026-08-10")
      #expect(transaction.payee == "合成测试商户")
      #expect(transaction.note == nil)
      #expect(transaction.postings.map(\.side) == [.debit, .credit])
      #expect(transaction.postings.map(\.money.minorUnits) == [1_250, 1_250])

      let successfulCounts = try ledgerRowCounts(database: database)
      #expect(successfulCounts == (1, 2))
      let totals = try await database.pool.read { database in
        try Row.fetchAll(
          database,
          sql: """
            SELECT side, SUM(amount_minor) AS total
            FROM postings
            WHERE transaction_id = ?
            GROUP BY side
            ORDER BY side
            """,
          arguments: [transactionID.uuidString.lowercased()]
        ).reduce(into: [String: Int64]()) { result, row in
          result[row["side"]] = row["total"]
        }
      }
      #expect(totals["debit"] == 1_250)
      #expect(totals["credit"] == 1_250)

      let recentTransactions = try await LedgerQueryService(repository: repository)
        .recentTransactions(ownerID: identity.profileID)
      #expect(recentTransactions.count == 1)
      #expect(recentTransactions[0].id == transactionID)
      #expect(recentTransactions[0].money.minorUnits == 1_250)
      #expect(recentTransactions[0].payee == "合成测试商户")

      let conflictingRequest = try CreateLedgerTransactionRequest(
        transactionID: transactionID,
        ownerID: identity.profileID,
        details: request.details,
        money: PositiveMoney(minorUnits: 2_500, currencyCode: .cny),
        occurredAt: occurredAt,
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: submittedAt
      )
      do {
        _ = try await useCase.execute(conflictingRequest)
        Issue.record("同一交易 ID 不同内容不应复用首次结果")
      } catch let error as LedgerError {
        #expect(error == .duplicateTransactionIdentifier)
      }
      #expect(try ledgerRowCounts(database: database) == (1, 2))
    }
  }

  @Test("归档账户和跨币种账户不能参与新交易")
  func invalidAccountsRollbackEntireWrite() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_050)
      )
      let expenseCategoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.uncategorized"
      )
      try await database.pool.write { database in
        try database.execute(
          sql: "UPDATE ledger_accounts SET status = 'archived' WHERE id = ?",
          arguments: [identity.defaultCashAccountID.uuidString.lowercased()]
        )
      }

      let request = try CreateLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        details: .expense(
          paymentAccountID: identity.defaultCashAccountID,
          categoryAccountID: expenseCategoryID
        ),
        money: PositiveMoney(minorUnits: 500, currencyCode: .cny),
        occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_200)
      )

      do {
        _ = try await CreateTransactionUseCase(repository: repository).execute(request)
        Issue.record("归档账户不应参与新交易")
      } catch let error as LedgerError {
        #expect(error == .accountArchived(identity.defaultCashAccountID))
      }
      #expect(try ledgerRowCounts(database: database) == (0, 0))
    }
  }

  @Test("账户与分类可创建归档恢复且分类层级受保护")
  func accountLifecycleIsValidatedAndIdempotent() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_050)
      )
      let createAccount = CreateLedgerAccountUseCase(repository: repository)
      let setStatus = SetLedgerAccountStatusUseCase(repository: repository)
      #expect(throws: LedgerError.invalidAccountName) {
        try CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "   ",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_090)
        )
      }
      #expect(throws: LedgerError.invalidAccountName) {
        try CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: String(repeating: "名", count: 41),
          submittedAt: Date(timeIntervalSince1970: 1_786_287_091)
        )
      }
      #expect(throws: LedgerError.financialAccountCannotHaveParent) {
        try CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "非法层级",
          parentID: UUID(),
          submittedAt: Date(timeIntervalSince1970: 1_786_287_092)
        )
      }
      let bankID = UUID()
      let bankRequest = try CreateLedgerAccountRequest(
        accountID: bankID,
        ownerID: identity.profileID,
        creationType: .bank,
        name: "  工资卡  ",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_100)
      )

      let bank = try await createAccount.execute(bankRequest)
      let repeatedBank = try await createAccount.execute(bankRequest)
      #expect(bank == repeatedBank)
      #expect(bank.name == "工资卡")
      #expect(bank.kind == .asset)
      #expect(bank.subtype == .bank)
      let wallet = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .electronicWallet,
          name: "电子钱包",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_105)
        )
      )
      #expect(wallet.kind == .asset)
      #expect(wallet.subtype == .electronicWallet)

      let parentID = UUID()
      let parent = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: parentID,
          ownerID: identity.profileID,
          creationType: .expenseCategory,
          name: "宠物",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      let childID = UUID()
      let child = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: childID,
          ownerID: identity.profileID,
          creationType: .expenseCategory,
          name: "猫粮",
          parentID: parent.id,
          submittedAt: Date(timeIntervalSince1970: 1_786_287_120)
        )
      )
      #expect(child.parentID == parent.id)

      do {
        _ = try await createAccount.execute(
          CreateLedgerAccountRequest(
            accountID: UUID(),
            ownerID: identity.profileID,
            creationType: .incomeCategory,
            name: "错误父分类",
            parentID: parent.id,
            submittedAt: Date(timeIntervalSince1970: 1_786_287_125)
          )
        )
        Issue.record("收入分类不应挂到支出父分类")
      } catch let error as LedgerError {
        #expect(error == .categoryParentKindMismatch)
      }

      do {
        _ = try await createAccount.execute(
          CreateLedgerAccountRequest(
            accountID: UUID(),
            ownerID: identity.profileID,
            creationType: .expenseCategory,
            name: "进口猫粮",
            parentID: child.id,
            submittedAt: Date(timeIntervalSince1970: 1_786_287_130)
          )
        )
        Issue.record("分类不应超过一层父子关系")
      } catch let error as LedgerError {
        #expect(error == .categoryHierarchyTooDeep)
      }

      do {
        _ = try await setStatus.execute(
          SetLedgerAccountStatusRequest(
            ownerID: identity.profileID,
            accountID: parent.id,
            status: .archived,
            changedAt: Date(timeIntervalSince1970: 1_786_287_140)
          )
        )
        Issue.record("仍有启用子分类时不应归档父分类")
      } catch let error as LedgerError {
        #expect(error == .accountHasActiveChildren)
      }

      let archivedChild = try await setStatus.execute(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: child.id,
          status: .archived,
          changedAt: Date(timeIntervalSince1970: 1_786_287_150)
        )
      )
      #expect(archivedChild.status == .archived)
      let archivedParent = try await setStatus.execute(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: parent.id,
          status: .archived,
          changedAt: Date(timeIntervalSince1970: 1_786_287_155)
        )
      )
      #expect(archivedParent.status == .archived)
      do {
        _ = try await setStatus.execute(
          SetLedgerAccountStatusRequest(
            ownerID: identity.profileID,
            accountID: child.id,
            status: .active,
            changedAt: Date(timeIntervalSince1970: 1_786_287_156)
          )
        )
        Issue.record("父分类归档时不应先恢复子分类")
      } catch let error as LedgerError {
        #expect(error == .accountArchived(parent.id))
      }
      _ = try await setStatus.execute(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: parent.id,
          status: .active,
          changedAt: Date(timeIntervalSince1970: 1_786_287_157)
        )
      )
      let restoredChild = try await setStatus.execute(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: child.id,
          status: .active,
          changedAt: Date(timeIntervalSince1970: 1_786_287_160)
        )
      )
      #expect(restoredChild.status == .active)

      let openingEquityID = try requiredAccountID(
        database: database,
        systemKey: "equity.opening"
      )
      do {
        _ = try await setStatus.execute(
          SetLedgerAccountStatusRequest(
            ownerID: identity.profileID,
            accountID: openingEquityID,
            status: .archived,
            changedAt: Date(timeIntervalSince1970: 1_786_287_170)
          )
        )
        Issue.record("内部权益账户不应允许归档")
      } catch let error as LedgerError {
        #expect(error == .internalAccountProtected)
      }
    }
  }

  @Test("支出收入转账从正式分录重建资产负债与分类余额")
  func postedBalancesAreRebuiltFromPostings() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_050)
      )
      let createAccount = CreateLedgerAccountUseCase(repository: repository)
      let bank = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "工资卡",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_060)
        )
      )
      let creditCard = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .creditCard,
          name: "信用卡",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_070)
        )
      )
      let expenseCategoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.food"
      )
      let incomeCategoryID = try requiredAccountID(
        database: database,
        systemKey: "income.salary"
      )
      let createTransaction = CreateTransactionUseCase(repository: repository)

      for (offset, details, amount) in [
        (
          100.0,
          ManualLedgerTransactionDetails.income(
            receivingAccountID: bank.id,
            categoryAccountID: incomeCategoryID
          ), Int64(10_000)
        ),
        (
          200.0,
          .expense(
            paymentAccountID: creditCard.id,
            categoryAccountID: expenseCategoryID
          ), Int64(2_000)
        ),
        (
          300.0,
          .transfer(
            sourceAccountID: bank.id,
            destinationAccountID: identity.defaultCashAccountID
          ), Int64(3_000)
        ),
        (
          400.0,
          .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: expenseCategoryID
          ), Int64(5_000)
        ),
      ] {
        _ = try await createTransaction.execute(
          CreateLedgerTransactionRequest(
            transactionID: UUID(),
            ownerID: identity.profileID,
            details: details,
            money: PositiveMoney(minorUnits: amount, currencyCode: .cny),
            occurredAt: Date(timeIntervalSince1970: 1_786_287_000 + offset),
            originalTimeZoneIdentifier: "Asia/Shanghai",
            submittedAt: Date(timeIntervalSince1970: 1_786_287_010 + offset)
          )
        )
      }

      let summaries = try await LedgerQueryService(repository: repository)
        .accountSummaries(ownerID: identity.profileID)
      let balances = Dictionary(
        uniqueKeysWithValues: summaries.map {
          ($0.account.id, $0.balance.minorUnits)
        })
      #expect(balances[bank.id] == 7_000)
      #expect(balances[identity.defaultCashAccountID] == -2_000)
      #expect(balances[creditCard.id] == 2_000)
      #expect(balances[expenseCategoryID] == 7_000)
      #expect(balances[incomeCategoryID] == 10_000)

      _ = try await SetLedgerAccountStatusUseCase(repository: repository).execute(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: bank.id,
          status: .archived,
          changedAt: Date(timeIntervalSince1970: 1_786_287_500)
        )
      )
      let afterArchive = try await repository.accountSummaries(ownerID: identity.profileID)
      #expect(afterArchive.first(where: { $0.id == bank.id })?.balance.minorUnits == 7_000)
      #expect(afterArchive.first(where: { $0.id == bank.id })?.account.status == .archived)
    }
  }

  @Test("余额聚合溢出时查询失败而不截断")
  func balanceOverflowFailsQuery() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_050)
      )
      let incomeCategoryID = try requiredAccountID(
        database: database,
        systemKey: "income.salary"
      )
      let createTransaction = CreateTransactionUseCase(repository: repository)

      for offset in [100.0, 200.0] {
        _ = try await createTransaction.execute(
          CreateLedgerTransactionRequest(
            transactionID: UUID(),
            ownerID: identity.profileID,
            details: .income(
              receivingAccountID: identity.defaultCashAccountID,
              categoryAccountID: incomeCategoryID
            ),
            money: PositiveMoney(minorUnits: .max, currencyCode: .cny),
            occurredAt: Date(timeIntervalSince1970: 1_786_287_000 + offset),
            originalTimeZoneIdentifier: "Asia/Shanghai",
            submittedAt: Date(timeIntervalSince1970: 1_786_287_010 + offset)
          )
        )
      }

      await #expect(throws: (any Error).self) {
        _ = try await repository.accountSummaries(ownerID: identity.profileID)
      }
    }
  }

  @Test("月报按用户时区自然月聚合并排除转账")
  func monthlyReportUsesLocalDateAndExcludesTransfers() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_010)
      )
      let bank = try await repository.createAccount(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "月报测试卡",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_020)
        )
      )
      var utcCalendar = Calendar(identifier: .gregorian)
      utcCalendar.timeZone = .gmt
      guard
        let occurredAt = utcCalendar.date(
          from: DateComponents(
            year: 2026,
            month: 7,
            day: 31,
            hour: 16,
            minute: 30
          )
        ),
        let julyReference = utcCalendar.date(
          from: DateComponents(year: 2026, month: 7, day: 15)
        ),
        let augustReference = utcCalendar.date(
          from: DateComponents(year: 2026, month: 8, day: 15)
        )
      else {
        Issue.record("测试日期应可构造")
        return
      }
      let income = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          details: .income(
            receivingAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultIncomeCategoryID
          ),
          money: PositiveMoney(minorUnits: 10_000, currencyCode: .cny),
          occurredAt: occurredAt,
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_100)
        )
      )
      #expect(income.localDate == "2026-08-01")
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          details: .transfer(
            sourceAccountID: identity.defaultCashAccountID,
            destinationAccountID: bank.id
          ),
          money: PositiveMoney(minorUnits: 4_000, currencyCode: .cny),
          occurredAt: occurredAt.addingTimeInterval(60),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )

      let julyReport = try await repository.monthlyReport(
        ownerID: identity.profileID,
        month: LedgerMonth(
          containing: julyReference,
          timeZoneIdentifier: "Asia/Shanghai"
        )
      )
      let augustReport = try await repository.monthlyReport(
        ownerID: identity.profileID,
        month: LedgerMonth(
          containing: augustReference,
          timeZoneIdentifier: "Asia/Shanghai"
        )
      )
      #expect(julyReport.month.startLocalDate == "2026-07-01")
      #expect(julyReport.month.endExclusiveLocalDate == "2026-08-01")
      #expect(julyReport.income.minorUnits == 0)
      #expect(augustReport.month.startLocalDate == "2026-08-01")
      #expect(augustReport.month.endExclusiveLocalDate == "2026-09-01")
      #expect(augustReport.income.minorUnits == 10_000)
      #expect(augustReport.expense.minorUnits == 0)
      #expect(augustReport.netChange.minorUnits == 10_000)
    }
  }

  @Test("支出退款按根版本串行提交且退款撤销恢复可退金额")
  func refundLifecycleUsesRootRevisionAndIsIdempotent() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_010)
      )
      let categoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.food"
      )
      let rootID = UUID()
      let original = try await CreateTransactionUseCase(repository: repository).execute(
        CreateLedgerTransactionRequest(
          transactionID: rootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: categoryID
          ),
          money: PositiveMoney(minorUnits: 10_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "午餐",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      let initial = try await repository.transactionRoot(
        ownerID: identity.profileID,
        rootID: rootID
      )
      #expect(initial.rootRevision == 1)
      #expect(initial.availableRefundMinorUnits == 10_000)

      let firstRefundRequest = try RefundLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        currentTransactionID: original.id,
        expectedRootRevision: 1,
        destinationAccountID: identity.defaultCashAccountID,
        money: PositiveMoney(minorUnits: 3_000, currencyCode: .cny),
        occurredAt: Date(timeIntervalSince1970: 1_786_287_200),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        note: "部分退款",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_210)
      )
      let firstRefund = try await RefundTransactionUseCase(repository: repository)
        .execute(firstRefundRequest)
      let repeatedRefund = try await RefundTransactionUseCase(repository: repository)
        .execute(firstRefundRequest)
      #expect(firstRefund == repeatedRefund)
      #expect(firstRefund.refundOfID == original.id)
      #expect(firstRefund.localRootRevision == 2)

      let afterFirstRefund = try await repository.transactionRoot(
        ownerID: identity.profileID,
        rootID: rootID
      )
      #expect(afterFirstRefund.activeRefundMinorUnits == 3_000)
      #expect(afterFirstRefund.availableRefundMinorUnits == 7_000)

      let staleRequest = try RefundLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        currentTransactionID: original.id,
        expectedRootRevision: 1,
        destinationAccountID: identity.defaultCashAccountID,
        money: PositiveMoney(minorUnits: 1_000, currencyCode: .cny),
        occurredAt: Date(timeIntervalSince1970: 1_786_287_220),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_230)
      )
      do {
        _ = try await repository.refundTransaction(staleRequest)
        Issue.record("过期根版本不应提交退款")
      } catch let error as LedgerError {
        #expect(error == .rootRevisionConflict(expected: 1, actual: 2))
      }

      let excessiveRequest = try RefundLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        currentTransactionID: original.id,
        expectedRootRevision: 2,
        destinationAccountID: identity.defaultCashAccountID,
        money: PositiveMoney(minorUnits: 8_000, currencyCode: .cny),
        occurredAt: Date(timeIntervalSince1970: 1_786_287_240),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_250)
      )
      await #expect(throws: LedgerError.refundAmountExceedsAvailable) {
        _ = try await repository.refundTransaction(excessiveRequest)
      }

      let secondRefund = try await repository.refundTransaction(
        RefundLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          rootID: rootID,
          currentTransactionID: original.id,
          expectedRootRevision: 2,
          destinationAccountID: identity.defaultCashAccountID,
          money: PositiveMoney(minorUnits: 2_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_260),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_270)
        )
      )
      #expect(secondRefund.localRootRevision == 3)

      let reversalRequest = try ReverseLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        targetTransactionID: firstRefund.id,
        expectedRootRevision: 3,
        reason: "退款记录有误",
        occurredAt: Date(timeIntervalSince1970: 1_786_287_300),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_310)
      )
      let refundReversal = try await ReverseTransactionUseCase(repository: repository)
        .execute(reversalRequest)
      let repeatedReversal = try await ReverseTransactionUseCase(repository: repository)
        .execute(reversalRequest)
      #expect(refundReversal == repeatedReversal)
      #expect(refundReversal.reversalOfID == firstRefund.id)

      let final = try await repository.transactionRoot(
        ownerID: identity.profileID,
        rootID: rootID
      )
      #expect(final.rootRevision == 4)
      #expect(final.activeRefundMinorUnits == 2_000)
      #expect(final.availableRefundMinorUnits == 8_000)
      #expect(final.transactions.count == 4)

      let summaries = try await repository.accountSummaries(ownerID: identity.profileID)
      let balances = Dictionary(
        uniqueKeysWithValues: summaries.map { ($0.id, $0.balance.minorUnits) })
      #expect(balances[identity.defaultCashAccountID] == -8_000)
      #expect(balances[categoryID] == 8_000)
    }
  }

  @Test("更正以同一事务完成冲销替代且保留有效退款")
  func correctionIsAtomicAndKeepsActiveRefunds() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_010)
      )
      let categoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.transport"
      )
      let rootID = UUID()
      let original = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: rootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: categoryID
          ),
          money: PositiveMoney(minorUnits: 10_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "打车",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      _ = try await repository.refundTransaction(
        RefundLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          rootID: rootID,
          currentTransactionID: original.id,
          expectedRootRevision: 1,
          destinationAccountID: identity.defaultCashAccountID,
          money: PositiveMoney(minorUnits: 2_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_200),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_210)
        )
      )

      let tooSmallCorrection = try CorrectLedgerTransactionRequest(
        correctionGroupID: UUID(),
        reversalTransactionID: UUID(),
        replacementTransactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        currentTransactionID: original.id,
        expectedRootRevision: 2,
        replacementDetails: .expense(
          paymentAccountID: identity.defaultCashAccountID,
          categoryAccountID: categoryID
        ),
        replacementMoney: PositiveMoney(minorUnits: 1_500, currencyCode: .cny),
        replacementOccurredAt: Date(timeIntervalSince1970: 1_786_287_120),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_220)
      )
      await #expect(throws: LedgerError.correctionAmountBelowActiveRefunds) {
        _ = try await repository.correctTransaction(tooSmallCorrection)
      }
      #expect(try ledgerRowCounts(database: database) == (2, 4))

      let correctionRequest = try CorrectLedgerTransactionRequest(
        correctionGroupID: UUID(),
        reversalTransactionID: UUID(),
        replacementTransactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        currentTransactionID: original.id,
        expectedRootRevision: 2,
        replacementDetails: .expense(
          paymentAccountID: identity.defaultCashAccountID,
          categoryAccountID: categoryID
        ),
        replacementMoney: PositiveMoney(minorUnits: 8_000, currencyCode: .cny),
        replacementOccurredAt: Date(timeIntervalSince1970: 1_786_287_130),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        payee: "地铁",
        note: "修正商户和金额",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_230)
      )
      let correction = try await CorrectTransactionUseCase(repository: repository)
        .execute(correctionRequest)
      let repeated = try await CorrectTransactionUseCase(repository: repository)
        .execute(correctionRequest)
      #expect(correction == repeated)
      #expect(correction.rootRevision == 3)
      #expect(correction.reversal.reversalOfID == original.id)
      #expect(correction.reversal.correctionGroupID == correctionRequest.correctionGroupID)
      #expect(correction.replacement.replacementForID == original.id)
      #expect(correction.replacement.correctionGroupID == correctionRequest.correctionGroupID)

      let snapshot = try await repository.transactionRoot(
        ownerID: identity.profileID,
        rootID: rootID
      )
      #expect(snapshot.rootRevision == 3)
      #expect(snapshot.currentTransaction.id == correction.replacement.id)
      #expect(snapshot.activeRefundMinorUnits == 2_000)
      #expect(snapshot.availableRefundMinorUnits == 6_000)
      #expect(snapshot.transactions.count == 4)
      let recent = try await repository.recentTransactions(
        ownerID: identity.profileID,
        limit: 20
      )
      #expect(recent.count == 1)
      #expect(recent[0].rootID == rootID)
      #expect(recent[0].currentTransactionID == correction.replacement.id)
      #expect(recent[0].rootRevision == 3)
      #expect(recent[0].money.minorUnits == 8_000)
      #expect(recent[0].activeRefundMinorUnits == 2_000)
      #expect(!recent[0].isReversed)
      let searchCurrentPayee = try await repository.searchTransactions(
        ownerID: identity.profileID,
        searchText: "地铁",
        amountMinorUnits: nil,
        limit: 20
      )
      #expect(searchCurrentPayee.map(\.rootID) == [rootID])
      let searchReplacedPayee = try await repository.searchTransactions(
        ownerID: identity.profileID,
        searchText: "打车",
        amountMinorUnits: nil,
        limit: 20
      )
      #expect(searchReplacedPayee.isEmpty)
      let searchAmount = try await repository.searchTransactions(
        ownerID: identity.profileID,
        searchText: "80.00",
        amountMinorUnits: 8_000,
        limit: 20
      )
      #expect(searchAmount.map(\.rootID) == [rootID])
      let report = try await repository.monthlyReport(
        ownerID: identity.profileID,
        month: LedgerMonth(
          containing: Date(timeIntervalSince1970: 1_786_287_500),
          timeZoneIdentifier: "Asia/Shanghai"
        )
      )
      #expect(report.month.key == "2026-08")
      #expect(report.income.minorUnits == 0)
      #expect(report.expense.minorUnits == 6_000)
      #expect(report.netChange.minorUnits == -6_000)
      #expect(report.expenseCategories.count == 1)
      #expect(report.expenseCategories[0].accountID == categoryID)
      #expect(report.expenseCategories[0].total.minorUnits == 6_000)

      let reverseCurrentRequest = try ReverseLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        targetTransactionID: correction.replacement.id,
        expectedRootRevision: 3,
        reason: "整笔撤销",
        occurredAt: Date(timeIntervalSince1970: 1_786_287_300),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_310)
      )
      await #expect(throws: LedgerError.activeRefundsPreventReversal) {
        _ = try await repository.reverseTransaction(reverseCurrentRequest)
      }

      let summaries = try await repository.accountSummaries(ownerID: identity.profileID)
      let balances = Dictionary(
        uniqueKeysWithValues: summaries.map { ($0.id, $0.balance.minorUnits) })
      #expect(balances[identity.defaultCashAccountID] == -6_000)
      #expect(balances[categoryID] == 6_000)
    }
  }

  @Test("普通撤销归零且不能撤销撤销记录")
  func fullReversalNetsToZeroAndCannotBeReversedAgain() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_010)
      )
      let incomeCategoryID = try requiredAccountID(
        database: database,
        systemKey: "income.salary"
      )
      let rootID = UUID()
      let income = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: rootID,
          ownerID: identity.profileID,
          details: .income(
            receivingAccountID: identity.defaultCashAccountID,
            categoryAccountID: incomeCategoryID
          ),
          money: PositiveMoney(minorUnits: 5_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      let reversalRequest = try ReverseLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        targetTransactionID: income.id,
        expectedRootRevision: 1,
        reason: "重复记账",
        occurredAt: Date(timeIntervalSince1970: 1_786_287_200),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_210)
      )
      let reversal = try await repository.reverseTransaction(reversalRequest)
      #expect(try await repository.reverseTransaction(reversalRequest) == reversal)

      let snapshot = try await repository.transactionRoot(
        ownerID: identity.profileID,
        rootID: rootID
      )
      #expect(snapshot.rootRevision == 2)
      #expect(snapshot.isCurrentReversed)
      let recent = try await repository.recentTransactions(
        ownerID: identity.profileID,
        limit: 20
      )
      #expect(recent.count == 1)
      #expect(recent[0].rootID == rootID)
      #expect(recent[0].isReversed)
      let report = try await repository.monthlyReport(
        ownerID: identity.profileID,
        month: LedgerMonth(
          containing: Date(timeIntervalSince1970: 1_786_287_500),
          timeZoneIdentifier: "Asia/Shanghai"
        )
      )
      #expect(report.income.minorUnits == 0)
      #expect(report.expense.minorUnits == 0)
      #expect(report.netChange.minorUnits == 0)

      let reverseReversalRequest = try ReverseLedgerTransactionRequest(
        transactionID: UUID(),
        ownerID: identity.profileID,
        rootID: rootID,
        targetTransactionID: reversal.id,
        expectedRootRevision: 2,
        reason: "再次撤销",
        occurredAt: Date(timeIntervalSince1970: 1_786_287_220),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_230)
      )
      await #expect(throws: LedgerError.reversalCannotBeReversed) {
        _ = try await repository.reverseTransaction(reverseReversalRequest)
      }

      let summaries = try await repository.accountSummaries(ownerID: identity.profileID)
      let balances = Dictionary(
        uniqueKeysWithValues: summaries.map { ($0.id, $0.balance.minorUnits) })
      #expect(balances[identity.defaultCashAccountID] == 0)
      #expect(balances[incomeCategoryID] == 0)
    }
  }

  @Test("更正中途失败时根版本交易和分录全部回滚")
  func failedCorrectionRollsBackEveryWrite() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: Date(timeIntervalSince1970: 1_786_287_010)
      )
      let categoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.shopping"
      )
      let rootID = UUID()
      let original = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: rootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: categoryID
          ),
          money: PositiveMoney(minorUnits: 9_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      let replacementID = UUID()
      let request = try CorrectLedgerTransactionRequest(
        correctionGroupID: UUID(),
        reversalTransactionID: UUID(),
        replacementTransactionID: replacementID,
        ownerID: identity.profileID,
        rootID: rootID,
        currentTransactionID: original.id,
        expectedRootRevision: 1,
        replacementDetails: .expense(
          paymentAccountID: identity.defaultCashAccountID,
          categoryAccountID: categoryID
        ),
        replacementMoney: PositiveMoney(minorUnits: 7_000, currencyCode: .cny),
        replacementOccurredAt: Date(timeIntervalSince1970: 1_786_287_120),
        originalTimeZoneIdentifier: "Asia/Shanghai",
        submittedAt: Date(timeIntervalSince1970: 1_786_287_130)
      )
      try await database.pool.write { database in
        try database.execute(
          sql: """
            CREATE TRIGGER reject_test_replacement_posting
            BEFORE INSERT ON postings
            WHEN NEW.transaction_id = '\(replacementID.uuidString.lowercased())'
            BEGIN
              SELECT RAISE(ABORT, 'forced correction failure');
            END
            """
        )
      }

      await #expect(throws: (any Error).self) {
        _ = try await repository.correctTransaction(request)
      }
      let snapshot = try await repository.transactionRoot(
        ownerID: identity.profileID,
        rootID: rootID
      )
      #expect(snapshot.rootRevision == 1)
      #expect(snapshot.currentTransaction.id == original.id)
      #expect(snapshot.transactions == [original])
      #expect(try ledgerRowCounts(database: database) == (1, 2))
    }
  }

  @Test("组合筛选匹配当前根并让六个月趋势按全部正式分录净额重建")
  func filtersCurrentRootsAndBuildsSixMonthNetExpenseTrend() async throws {
    try await withAsyncTestDatabase { database in
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_767_225_600)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await repository.confirmBaseCurrency(
        BaseCurrencyConfirmation(
          ownerID: identity.profileID,
          currencyCode: .cny,
          confirmedAt: Date(timeIntervalSince1970: 1_767_225_610)
        )
      )
      let foodCategoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.food"
      )
      let transportCategoryID = try requiredAccountID(
        database: database,
        systemKey: "expense.transport"
      )
      let bank = try await repository.createAccount(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "历史筛选银行卡",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_620)
        )
      )
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
      func localDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
      }

      let marchRootID = UUID()
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: marchRootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: foodCategoryID
          ),
          money: PositiveMoney(minorUnits: 1_000, currencyCode: .cny),
          occurredAt: localDate(2026, 3, 8),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "春季咖啡",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_700)
        )
      )

      let mayRootID = UUID()
      let mayOriginal = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: mayRootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: bank.id,
            categoryAccountID: transportCategoryID
          ),
          money: PositiveMoney(minorUnits: 2_000, currencyCode: .cny),
          occurredAt: localDate(2026, 5, 9),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "城际巴士",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_710)
        )
      )
      let mayCorrection = try await repository.correctTransaction(
        CorrectLedgerTransactionRequest(
          correctionGroupID: UUID(),
          reversalTransactionID: UUID(),
          replacementTransactionID: UUID(),
          ownerID: identity.profileID,
          rootID: mayRootID,
          currentTransactionID: mayOriginal.id,
          expectedRootRevision: 1,
          replacementDetails: .expense(
            paymentAccountID: bank.id,
            categoryAccountID: transportCategoryID
          ),
          replacementMoney: PositiveMoney(minorUnits: 1_800, currencyCode: .cny),
          replacementOccurredAt: localDate(2026, 5, 9),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "城市地铁",
          note: "通勤",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_720)
        )
      )

      let juneRootID = UUID()
      let juneExpense = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: juneRootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: foodCategoryID
          ),
          money: PositiveMoney(minorUnits: 3_000, currencyCode: .cny),
          occurredAt: localDate(2026, 6, 10),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "旅行咖啡",
          note: "行程餐饮",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_730)
        )
      )
      _ = try await repository.refundTransaction(
        RefundLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          rootID: juneRootID,
          currentTransactionID: juneExpense.id,
          expectedRootRevision: 1,
          destinationAccountID: identity.defaultCashAccountID,
          money: PositiveMoney(minorUnits: 500, currencyCode: .cny),
          occurredAt: localDate(2026, 7, 2),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_740)
        )
      )

      let augustRootID = UUID()
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: augustRootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: foodCategoryID
          ),
          money: PositiveMoney(minorUnits: 4_000, currencyCode: .cny),
          occurredAt: localDate(2026, 8, 11),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "夏日餐厅",
          submittedAt: Date(timeIntervalSince1970: 1_767_225_750)
        )
      )

      let journeyID = UUID()
      let journeyStartedAt = try localDate(2026, 6, 10)
      let journeyEndedAt = journeyStartedAt.addingTimeInterval(900)
      try await database.pool.write { database in
        try database.execute(
          sql: """
            INSERT INTO journeys (
              id, owner_id, recording_device_id, status, transport_mode,
              started_at, ended_at, distance_meters, duration_seconds,
              capture_completeness, raw_track_state, final_sequence, point_count,
              manifest_hash, termination_reason, tracking_consent_version,
              created_at, updated_at
            ) VALUES (?, ?, 'report-filter-device', 'completed', 'transit',
              ?, ?, 1200, 900, 'complete', 'purged', 0, 0, ?, 'user_ended', 1, ?, ?)
            """,
          arguments: [
            journeyID.uuidString.lowercased(),
            identity.profileID.uuidString.lowercased(),
            journeyStartedAt.timeIntervalSince1970,
            journeyEndedAt.timeIntervalSince1970,
            Data(repeating: 7, count: 32),
            Date(timeIntervalSince1970: 1_767_225_760).timeIntervalSince1970,
            Date(timeIntervalSince1970: 1_767_225_760).timeIntervalSince1970,
          ]
        )
      }
      _ = try await GRDBLifeLinkRepository(database: database).linkTransactionToJourney(
        LinkTransactionToJourneyRequest(
          linkID: UUID(),
          ownerID: identity.profileID,
          transactionRootID: juneRootID,
          journeyID: journeyID,
          role: .meal,
          confirmedAt: Date(timeIntervalSince1970: 1_767_225_770)
        )
      )
      _ = try await repository.setAccountStatus(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: bank.id,
          status: .archived,
          changedAt: Date(timeIntervalSince1970: 1_767_225_780)
        )
      )
      _ = try await repository.setAccountStatus(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: transportCategoryID,
          status: .archived,
          changedAt: Date(timeIntervalSince1970: 1_767_225_790)
        )
      )

      let august = try LedgerMonth(year: 2026, month: 8)
      let unfilteredReport = try await repository.monthlyReport(
        ownerID: identity.profileID,
        month: august
      )
      #expect(unfilteredReport.expense.minorUnits == 4_000)
      #expect(
        unfilteredReport.expenseTrend.map(\.month.key) == [
          "2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08",
        ])
      #expect(
        unfilteredReport.expenseTrend.map(\.expense.minorUnits) == [
          1_000, 0, 1_800, 3_000, -500, 4_000,
        ])

      let linkedTravelFilter = LedgerTransactionFilter(
        searchText: "旅行",
        fundingAccountID: identity.defaultCashAccountID,
        categoryAccountID: foodCategoryID,
        journeyLink: .linked
      )
      let linkedTransactions = try await repository.filteredTransactions(
        ownerID: identity.profileID,
        filter: linkedTravelFilter,
        limit: 20
      )
      #expect(linkedTransactions.map(\.rootID) == [juneRootID])
      let linkedReport = try await repository.monthlyReport(
        ownerID: identity.profileID,
        month: august,
        filter: linkedTravelFilter
      )
      #expect(linkedReport.expense.minorUnits == 0)
      #expect(linkedReport.expenseTrend.map(\.expense.minorUnits) == [0, 0, 0, 3_000, -500, 0])

      let archivedFilter = LedgerTransactionFilter(
        searchText: "城市地铁",
        fundingAccountID: bank.id,
        categoryAccountID: transportCategoryID,
        journeyLink: .unlinked
      )
      let archivedMatches = try await repository.filteredTransactions(
        ownerID: identity.profileID,
        filter: archivedFilter,
        limit: 20
      )
      #expect(archivedMatches.map(\.currentTransactionID) == [mayCorrection.replacement.id])
      let replacedMatches = try await repository.filteredTransactions(
        ownerID: identity.profileID,
        filter: LedgerTransactionFilter(searchText: "城际巴士"),
        limit: 20
      )
      #expect(replacedMatches.isEmpty)

      let unlinkedMatches = try await repository.filteredTransactions(
        ownerID: identity.profileID,
        filter: LedgerTransactionFilter(journeyLink: .unlinked),
        limit: 20
      )
      #expect(Set(unlinkedMatches.map(\.rootID)) == Set([marchRootID, mayRootID, augustRootID]))
      let otherOwnerMatches = try await repository.filteredTransactions(
        ownerID: UUID(),
        filter: LedgerTransactionFilter(journeyLink: .linked),
        limit: 20
      )
      #expect(otherOwnerMatches.isEmpty)
      let categoryUsedAsFundingAccount = try await repository.filteredTransactions(
        ownerID: identity.profileID,
        filter: LedgerTransactionFilter(fundingAccountID: foodCategoryID),
        limit: 20
      )
      #expect(categoryUsedAsFundingAccount.isEmpty)
      let fundingAccountUsedAsCategory = try await repository.filteredTransactions(
        ownerID: identity.profileID,
        filter: LedgerTransactionFilter(
          categoryAccountID: identity.defaultCashAccountID
        ),
        limit: 20
      )
      #expect(fundingAccountUsedAsCategory.isEmpty)
    }
  }

  private func requiredAccountID(
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

  private func ledgerRowCounts(database: AppDatabase) throws -> (Int, Int) {
    try database.pool.read { database in
      let transactions =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM ledger_transactions"
        ) ?? 0
      let postings = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM postings") ?? 0
      return (transactions, postings)
    }
  }
}
