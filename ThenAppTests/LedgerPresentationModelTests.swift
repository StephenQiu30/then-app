import Foundation
import Testing

@testable import ThenApp

@Suite("账本交互模型")
struct LedgerPresentationModelTests {
  @Test("收入和转账选择器使用可用账户并保存正式交易")
  @MainActor
  func quickTransactionSupportsIncomeAndTransfer() async throws {
    try await withAsyncTestDatabase { database in
      let timestamp = Date(timeIntervalSince1970: 1_786_287_100)
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      let confirmCurrency = ConfirmBaseCurrencyUseCase(repository: repository)
      let createTransaction = CreateTransactionUseCase(repository: repository)
      let query = LedgerQueryService(repository: repository)
      let incomeModel = QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: confirmCurrency,
        createTransaction: createTransaction,
        ledgerQuery: query,
        now: { timestamp },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )

      await incomeModel.loadAccounts()
      incomeModel.selectTransactionType(.income)
      #expect(incomeModel.selectedSourceAccountID == identity.defaultCashAccountID)
      #expect(incomeModel.selectedCategoryID == identity.defaultIncomeCategoryID)
      incomeModel.amountText = "100.00"
      incomeModel.payee = "工资"
      await incomeModel.save()
      #expect(incomeModel.savedTransaction?.kind == .income)
      #expect(incomeModel.isCurrencyConfirmed)

      let bank = try await CreateLedgerAccountUseCase(repository: repository).execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "工资卡",
          submittedAt: timestamp
        )
      )
      let transferModel = QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: confirmCurrency,
        createTransaction: createTransaction,
        ledgerQuery: query,
        now: { timestamp.addingTimeInterval(10) },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )
      await transferModel.loadAccounts()
      transferModel.selectTransactionType(.transfer)
      #expect(transferModel.selectedSourceAccountID == identity.defaultCashAccountID)
      #expect(transferModel.selectedDestinationAccountID == bank.id)
      transferModel.amountText = "30"
      await transferModel.save()
      #expect(transferModel.savedTransaction?.kind == .transfer)
      #expect(transferModel.errorMessage == nil)

      let recent = try await query.recentTransactions(ownerID: identity.profileID)
      #expect(recent.map(\.kind) == [.transfer, .income])
    }
  }

  @Test("信用卡还款只允许资产到信用卡负债且不进入月报收支")
  @MainActor
  func creditCardRepaymentUsesRestrictedTransferPresentation() async throws {
    try await withAsyncTestDatabase { database in
      let timestamp = Date(timeIntervalSince1970: 1_786_287_100)
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: Date(timeIntervalSince1970: 1_786_287_000)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: timestamp
      )
      let createAccount = CreateLedgerAccountUseCase(repository: repository)
      let bank = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "还款银行卡",
          submittedAt: timestamp.addingTimeInterval(10)
        )
      )
      let creditCard = try await createAccount.execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .creditCard,
          name: "测试信用卡",
          submittedAt: timestamp.addingTimeInterval(20)
        )
      )
      let createTransaction = CreateTransactionUseCase(repository: repository)
      _ = try await createTransaction.execute(
        CreateLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: creditCard.id,
            categoryAccountID: identity.defaultExpenseCategoryID
          ),
          money: PositiveMoney(minorUnits: 5_000, currencyCode: .cny),
          occurredAt: timestamp.addingTimeInterval(30),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: timestamp.addingTimeInterval(31)
        )
      )

      let query = LedgerQueryService(repository: repository)
      let model = QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: ConfirmBaseCurrencyUseCase(repository: repository),
        createTransaction: createTransaction,
        ledgerQuery: query,
        now: { timestamp.addingTimeInterval(40) },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )
      await model.loadAccounts()
      model.selectTransactionType(.creditCardRepayment)

      #expect(model.sourceAccountOptions.allSatisfy { $0.account.kind == .asset })
      #expect(
        model.destinationAccountOptions.allSatisfy {
          $0.account.kind == .liability && $0.account.subtype == .creditCard
        }
      )
      #expect(model.selectedSourceAccountID == identity.defaultCashAccountID)
      #expect(model.selectedDestinationAccountID == creditCard.id)
      #expect(!model.destinationAccountOptions.contains(where: { $0.id == bank.id }))

      model.selectedSourceAccountID = bank.id
      model.amountText = "30.00"
      model.note = "合成还款"
      await model.save()

      #expect(model.savedTransaction?.kind == .transfer)
      #expect(model.savedTransaction?.postings.map(\.accountID) == [creditCard.id, bank.id])
      #expect(model.errorMessage == nil)

      let summaries = try await query.accountSummaries(ownerID: identity.profileID)
      #expect(summaries.first(where: { $0.id == bank.id })?.balance.minorUnits == -3_000)
      #expect(summaries.first(where: { $0.id == creditCard.id })?.balance.minorUnits == 2_000)
      let report = try await query.monthlyReport(
        ownerID: identity.profileID,
        containing: timestamp,
        timeZoneIdentifier: "Asia/Shanghai"
      )
      #expect(report.income.minorUnits == 0)
      #expect(report.expense.minorUnits == 5_000)
    }
  }

  @Test("账户管理保留余额并可归档和恢复")
  @MainActor
  func accountManagementChangesOnlyStatus() async throws {
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
      let bank = try await CreateLedgerAccountUseCase(repository: repository).execute(
        CreateLedgerAccountRequest(
          accountID: UUID(),
          ownerID: identity.profileID,
          creationType: .bank,
          name: "生活卡",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_100)
        )
      )
      let model = AccountManagementViewModel(
        ownerID: identity.profileID,
        ledgerQuery: LedgerQueryService(repository: repository),
        setLedgerAccountStatus: SetLedgerAccountStatusUseCase(repository: repository),
        now: { Date(timeIntervalSince1970: 1_786_287_200) }
      )

      await model.load()
      #expect(model.isCurrencyConfirmed)
      guard let activeBank = model.accountSummaries.first(where: { $0.id == bank.id }) else {
        Issue.record("新建账户应出现在管理列表")
        return
      }
      await model.setStatus(for: activeBank)
      guard let archivedBank = model.accountSummaries.first(where: { $0.id == bank.id }) else {
        Issue.record("归档账户仍应保留在管理列表")
        return
      }
      #expect(archivedBank.account.status == .archived)
      #expect(archivedBank.balance == activeBank.balance)

      await model.setStatus(for: archivedBank)
      #expect(
        model.accountSummaries.first(where: { $0.id == bank.id })?.account.status == .active
      )
      #expect(model.errorMessage == nil)
    }
  }

  @Test("没有可用资金账户时编辑器阻止保存并保留输入")
  @MainActor
  func quickTransactionBlocksSaveWithoutFundingAccount() async throws {
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
      _ = try await SetLedgerAccountStatusUseCase(repository: repository).execute(
        SetLedgerAccountStatusRequest(
          ownerID: identity.profileID,
          accountID: identity.defaultCashAccountID,
          status: .archived,
          changedAt: Date(timeIntervalSince1970: 1_786_287_100)
        )
      )
      let model = QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: ConfirmBaseCurrencyUseCase(repository: repository),
        createTransaction: CreateTransactionUseCase(repository: repository),
        ledgerQuery: LedgerQueryService(repository: repository),
        now: { Date(timeIntervalSince1970: 1_786_287_200) },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )

      await model.loadAccounts()
      #expect(model.selectedSourceAccountID == nil)
      #expect(model.hasRequiredOptions == false)
      model.amountText = "18.00"
      await model.save()
      #expect(model.savedTransaction == nil)
      #expect(model.amountText == "18.00")
      #expect(model.errorMessage != nil)
    }
  }

  @Test("交易详情模型完成退款更正并按根历史刷新状态")
  @MainActor
  func transactionDetailRefundAndCorrectionRefreshRootState() async throws {
    try await withAsyncTestDatabase { database in
      let timestamp = Date(timeIntervalSince1970: 1_786_287_500)
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
      let rootID = UUID()
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: rootID,
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultExpenseCategoryID
          ),
          money: PositiveMoney(minorUnits: 10_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      let model = LedgerTransactionDetailViewModel(
        rootID: rootID,
        ownerID: identity.profileID,
        ledgerQuery: LedgerQueryService(repository: repository),
        refundTransaction: RefundTransactionUseCase(repository: repository),
        reverseTransaction: ReverseTransactionUseCase(repository: repository),
        correctTransaction: CorrectTransactionUseCase(repository: repository),
        now: { timestamp },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )

      await model.load()
      #expect(model.canRefund)
      #expect(model.canCorrect)
      #expect(model.canReverse)
      #expect(model.correctionSourceAccountID == identity.defaultCashAccountID)
      #expect(model.correctionSecondaryAccountID == identity.defaultExpenseCategoryID)

      model.refundAmountText = "20。00"
      #expect(await model.saveRefund())
      #expect(model.snapshot?.activeRefundMinorUnits == 2_000)
      #expect(model.snapshot?.availableRefundMinorUnits == 8_000)
      #expect(!model.canReverse)

      model.correctionAmountText = "80.00"
      model.correctionPayee = "更正商户"
      #expect(await model.saveCorrection())
      #expect(model.snapshot?.rootRevision == 3)
      #expect(model.snapshot?.currentTransaction.payee == "更正商户")
      #expect(model.snapshot?.currentTransaction.postings.first?.money.minorUnits == 8_000)
      #expect(model.snapshot?.activeRefundMinorUnits == 2_000)
      #expect(model.snapshot?.availableRefundMinorUnits == 6_000)
      #expect(model.sortedHistory.count == 4)
    }
  }

  @Test("交易详情模型完整撤销后关闭全部操作入口")
  @MainActor
  func transactionDetailReversalClosesActions() async throws {
    try await withAsyncTestDatabase { database in
      let timestamp = Date(timeIntervalSince1970: 1_786_287_500)
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
      let rootID = UUID()
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: rootID,
          ownerID: identity.profileID,
          details: .income(
            receivingAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultIncomeCategoryID
          ),
          money: PositiveMoney(minorUnits: 5_000, currencyCode: .cny),
          occurredAt: Date(timeIntervalSince1970: 1_786_287_100),
          originalTimeZoneIdentifier: "Asia/Shanghai",
          submittedAt: Date(timeIntervalSince1970: 1_786_287_110)
        )
      )
      let model = LedgerTransactionDetailViewModel(
        rootID: rootID,
        ownerID: identity.profileID,
        ledgerQuery: LedgerQueryService(repository: repository),
        refundTransaction: RefundTransactionUseCase(repository: repository),
        reverseTransaction: ReverseTransactionUseCase(repository: repository),
        correctTransaction: CorrectTransactionUseCase(repository: repository),
        now: { timestamp },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )

      await model.load()
      model.reversalReason = "误记"
      #expect(await model.saveReversal())
      #expect(model.snapshot?.isCurrentReversed == true)
      #expect(!model.canRefund)
      #expect(!model.canCorrect)
      #expect(!model.canReverse)
      #expect(model.sortedHistory.count == 2)
    }
  }

  @Test("今天模型展示本月净额并按当前商户和金额搜索")
  @MainActor
  func todayModelLoadsMonthlyReportAndSearchesCurrentRoots() async throws {
    try await withAsyncTestDatabase { database in
      let timestamp = Date(timeIntervalSince1970: 1_786_287_500)
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
      for (details, amount, payee, offset) in [
        (
          ManualLedgerTransactionDetails.income(
            receivingAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultIncomeCategoryID
          ),
          Int64(10_000),
          "工资",
          100.0
        ),
        (
          ManualLedgerTransactionDetails.expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultExpenseCategoryID
          ),
          Int64(3_000),
          "晚餐",
          200.0
        ),
      ] {
        _ = try await repository.createTransaction(
          CreateLedgerTransactionRequest(
            transactionID: UUID(),
            ownerID: identity.profileID,
            details: details,
            money: PositiveMoney(minorUnits: amount, currencyCode: .cny),
            occurredAt: Date(timeIntervalSince1970: 1_786_287_000 + offset),
            originalTimeZoneIdentifier: "Asia/Shanghai",
            payee: payee,
            submittedAt: Date(timeIntervalSince1970: 1_786_287_010 + offset)
          )
        )
      }
      let model = TodayViewModel(
        ledgerIdentity: identity,
        launchMode: .local,
        ledgerQuery: LedgerQueryService(repository: repository),
        snapshotService: TodaySnapshotService(
          occurrences: { _ in [] },
          plans: { [] },
          journeys: { [] },
          ledger: { referenceDate, timeZoneIdentifier in
            let query = LedgerQueryService(repository: repository)
            let profile = try await query.localProfile(ownerID: identity.profileID)
            return try await TodayLedgerSnapshot(
              profile: profile,
              recentTransactions: query.recentTransactions(ownerID: identity.profileID),
              monthlyReport: query.monthlyReport(
                ownerID: identity.profileID,
                containing: referenceDate,
                timeZoneIdentifier: timeZoneIdentifier
              )
            )
          }
        ),
        now: { timestamp },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )

      await model.loadRecentTransactions()
      #expect(model.recentTransactions.count == 2)
      #expect(model.monthlyReport?.income.minorUnits == 10_000)
      #expect(model.monthlyReport?.expense.minorUnits == 3_000)
      #expect(model.monthlyReport?.netChange.minorUnits == 7_000)

      model.searchText = "晚餐"
      await model.search()
      #expect(model.searchResults.count == 1)
      #expect(model.searchResults[0].payee == "晚餐")

      model.searchText = "30。00"
      await model.search()
      #expect(model.searchResults.count == 1)
      #expect(model.searchResults[0].kind == .expense)

      model.searchText = "不存在"
      await model.search()
      #expect(model.searchResults.isEmpty)

      model.searchText = ""
      await model.search()
      #expect(model.searchResults.isEmpty)
      #expect(!model.isSearchActive)
    }
  }

  @Test("账本模型组合月度概览流水和本地搜索并可切换月份")
  @MainActor
  func ledgerModelLoadsReportTransactionsSearchAndMonthSelection() async throws {
    try await withAsyncTestDatabase { database in
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
      let august = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12))
      )
      let july = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 12))
      )
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: july.addingTimeInterval(-100)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await ConfirmBaseCurrencyUseCase(repository: repository).execute(
        ownerID: identity.profileID,
        currencyCode: .cny,
        confirmedAt: july.addingTimeInterval(-50)
      )
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          details: .income(
            receivingAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultIncomeCategoryID
          ),
          money: PositiveMoney(minorUnits: 10_000, currencyCode: .cny),
          occurredAt: july,
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "七月工资",
          submittedAt: july.addingTimeInterval(10)
        )
      )
      _ = try await repository.createTransaction(
        CreateLedgerTransactionRequest(
          transactionID: UUID(),
          ownerID: identity.profileID,
          details: .expense(
            paymentAccountID: identity.defaultCashAccountID,
            categoryAccountID: identity.defaultExpenseCategoryID
          ),
          money: PositiveMoney(minorUnits: 1_234, currencyCode: .cny),
          occurredAt: august,
          originalTimeZoneIdentifier: "Asia/Shanghai",
          payee: "账本可视化咖啡",
          note: "本地搜索备注",
          submittedAt: august.addingTimeInterval(10)
        )
      )
      let model = LedgerViewModel(
        identity: identity,
        ledgerQuery: LedgerQueryService(repository: repository),
        now: { august },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )

      await model.load()
      #expect(model.baseCurrencyState == .confirmed)
      #expect(model.monthTitle == "2026 年 8 月")
      #expect(model.monthlyReport?.income.minorUnits == 0)
      #expect(model.monthlyReport?.expense.minorUnits == 1_234)
      #expect(model.monthlyReport?.netChange.minorUnits == -1_234)
      #expect(model.recentTransactions.map(\.payee) == ["账本可视化咖啡", "七月工资"])
      #expect(!model.accountSummaries.isEmpty)

      model.searchText = "本地搜索备注"
      await model.search()
      #expect(model.searchResults.map(\.payee) == ["账本可视化咖啡"])

      model.searchText = "12。34"
      await model.search()
      #expect(model.searchResults.map(\.payee) == ["账本可视化咖啡"])

      await model.moveSelectedMonth(by: -1)
      #expect(model.monthTitle == "2026 年 7 月")
      #expect(model.monthlyReport?.income.minorUnits == 0)
      #expect(model.monthlyReport?.expense.minorUnits == 0)
      #expect(model.monthlyReport?.netChange.minorUnits == 0)

      model.searchText = ""
      await model.search()
      #expect(!model.isSearchActive)
      #expect(model.searchResults.isEmpty)
      #expect(model.monthlyReport?.income.minorUnits == 10_000)
      #expect(model.monthlyReport?.netChange.minorUnits == 10_000)
      #expect(model.errorMessage == nil)
      #expect(model.reportErrorMessage == nil)
    }
  }

  @Test("快速修改筛选时陈旧查询不会覆盖当前流水和月报")
  @MainActor
  func staleFilterResultsCannotReplaceCurrentSelection() async throws {
    try await withAsyncTestDatabase { database in
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
      let august = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 12))
      )
      let identity = try LocalLedgerBootstrap(database: database).initializeIfNeeded(
        suggestedCurrencyCode: .cny,
        now: august.addingTimeInterval(-100)
      )
      let repository = GRDBLedgerRepository(database: database)
      _ = try await repository.confirmBaseCurrency(
        BaseCurrencyConfirmation(
          ownerID: identity.profileID,
          currencyCode: .cny,
          confirmedAt: august.addingTimeInterval(-90)
        )
      )
      for (payee, amount, offset) in [("慢条件", 1_000, 0.0), ("快条件", 2_000, 10.0)] {
        _ = try await repository.createTransaction(
          CreateLedgerTransactionRequest(
            transactionID: UUID(),
            ownerID: identity.profileID,
            details: .expense(
              paymentAccountID: identity.defaultCashAccountID,
              categoryAccountID: identity.defaultExpenseCategoryID
            ),
            money: PositiveMoney(minorUnits: Int64(amount), currencyCode: .cny),
            occurredAt: august.addingTimeInterval(offset),
            originalTimeZoneIdentifier: "Asia/Shanghai",
            payee: payee,
            submittedAt: august.addingTimeInterval(20 + offset)
          )
        )
      }
      let delayedQuery = DelayedLedgerQuery(
        base: LedgerQueryService(repository: repository)
      )
      let model = LedgerViewModel(
        identity: identity,
        ledgerQuery: delayedQuery,
        now: { august },
        timeZoneIdentifier: { "Asia/Shanghai" }
      )
      await model.load()

      model.searchText = "慢条件"
      let slowTask = Task { await model.search() }
      try await Task.sleep(for: .milliseconds(20))
      model.searchText = "快条件"
      let fastTask = Task { await model.search() }
      await fastTask.value
      await slowTask.value

      #expect(model.filterSummary == "关键词：快条件")
      #expect(model.searchResults.map(\.payee) == ["快条件"])
      #expect(model.monthlyReport?.expense.minorUnits == 2_000)
      #expect(!model.isSearching)
      #expect(!model.isLoadingReport)
    }
  }
}

private actor DelayedLedgerQuery: LedgerQuerying {
  let base: LedgerQueryService

  init(base: LedgerQueryService) {
    self.base = base
  }

  func localProfile(ownerID: UUID) async throws -> LocalLedgerProfile {
    try await base.localProfile(ownerID: ownerID)
  }

  func recentTransactions(
    ownerID: UUID,
    limit: Int
  ) async throws -> [LedgerTransactionSummary] {
    try await base.recentTransactions(ownerID: ownerID, limit: limit)
  }

  func filteredTransactions(
    ownerID: UUID,
    filter: LedgerTransactionFilter,
    limit: Int
  ) async throws -> [LedgerTransactionSummary] {
    try await delay(for: filter)
    return try await base.filteredTransactions(
      ownerID: ownerID,
      filter: filter,
      limit: limit
    )
  }

  func monthlyReport(
    ownerID: UUID,
    containing date: Date,
    timeZoneIdentifier: String,
    filter: LedgerTransactionFilter
  ) async throws -> LedgerMonthlyReport {
    try await delay(for: filter)
    return try await base.monthlyReport(
      ownerID: ownerID,
      containing: date,
      timeZoneIdentifier: timeZoneIdentifier,
      filter: filter
    )
  }

  func accountSummaries(ownerID: UUID) async throws -> [LedgerAccountSummary] {
    try await base.accountSummaries(ownerID: ownerID)
  }

  private func delay(for filter: LedgerTransactionFilter) async throws {
    if filter.searchText == "慢条件" {
      try await Task.sleep(for: .milliseconds(180))
    } else if filter.searchText == "快条件" {
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
