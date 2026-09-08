import Charts
import SwiftUI

struct LedgerView: View {
  @State private var model: LedgerViewModel
  @State private var isPresentingFilters = false
  private let environment: AppEnvironment

  init(environment: AppEnvironment) {
    self.environment = environment
    _model = State(
      initialValue: LedgerViewModel(
        identity: environment.localLedgerIdentity,
        ledgerQuery: environment.ledgerQuery
      )
    )
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.isLoading, model.accountSummaries.isEmpty,
          model.recentTransactions.isEmpty
        {
          ProgressView("正在读取账本")
        } else if model.accountSummaries.isEmpty, model.recentTransactions.isEmpty {
          ContentUnavailableView(
            "账本暂时不可用",
            systemImage: "books.vertical",
            description: Text("请稍后重试读取本地账本。")
          )
        } else {
          ledgerContent
        }
      }
      .navigationTitle("账本")
      .searchable(
        text: $model.searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "搜索账目"
      )
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            isPresentingFilters = true
          } label: {
            Image(
              systemName: model.hasStructuredFilters
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
            )
          }
          .accessibilityLabel(model.hasStructuredFilters ? "筛选已启用" : "筛选")
          .accessibilityIdentifier("ledger.filter.button")

          NavigationLink {
            AccountManagementView(environment: environment)
          } label: {
            Label("管理账户", systemImage: "slider.horizontal.3")
          }
        }
      }
      .sheet(isPresented: $isPresentingFilters) {
        LedgerFilterView(
          fundingAccounts: model.fundingAccounts,
          categories: model.categoryAccounts,
          selectedFundingAccountID: model.selectedFundingAccountID,
          selectedCategoryAccountID: model.selectedCategoryAccountID,
          journeyLinkFilter: model.journeyLinkFilter
        ) { fundingAccountID, categoryAccountID, journeyLinkFilter in
          Task {
            await model.applyStructuredFilters(
              fundingAccountID: fundingAccountID,
              categoryAccountID: categoryAccountID,
              journeyLink: journeyLinkFilter
            )
          }
        }
      }
      .overlay(alignment: .bottom) {
        if let errorMessage = model.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding()
        }
      }
      .task {
        await model.load()
      }
      .task(id: model.searchText) {
        guard model.isSearchActive else {
          await model.search()
          return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        await model.search()
      }
      .refreshable {
        await model.load()
      }
    }
  }

  private var ledgerContent: some View {
    List {
      if model.hasActiveFilters {
        Section {
          Text(model.filterSummary)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("ledger.filter.summary")
          Button("清除全部筛选", systemImage: "xmark.circle") {
            Task { await model.clearFilters() }
          }
          .accessibilityIdentifier("ledger.filter.clear")
        } header: {
          Text("当前筛选").foregroundStyle(.primary)
        }
      }

      monthlyReportSection

      Section {
        if model.isSearching, model.displayedTransactions.isEmpty {
          HStack {
            ProgressView()
            Text("正在读取筛选结果")
              .foregroundStyle(.primary)
          }
        } else if model.displayedTransactions.isEmpty, model.hasActiveFilters {
          Label("没有符合条件的账目", systemImage: "line.3.horizontal.decrease.circle")
            .foregroundStyle(.primary)
          Button("清除全部筛选") {
            Task { await model.clearFilters() }
          }
        } else if model.displayedTransactions.isEmpty {
          Text("还没有正式交易。可从“今天”点击“记一笔”开始。")
            .foregroundStyle(.primary)
        } else {
          ForEach(model.displayedTransactions) { transaction in
            transactionLink(transaction)
          }
        }
      } header: {
        Text(model.hasActiveFilters ? "筛选结果" : "交易流水")
          .foregroundStyle(.primary)
      }

      accountSection("资金账户", summaries: model.fundingAccounts)
      accountSection("支出分类", summaries: model.expenseCategories)
      accountSection("收入分类", summaries: model.incomeCategories)
    }
    .headerProminence(.increased)
    .modifier(AdaptiveHardScrollEdgeEffectModifier())
  }

  private var monthlyReportSection: some View {
    Section {
      HStack {
        Button("上一个月", systemImage: "chevron.left") {
          Task { await model.moveSelectedMonth(by: -1) }
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
        Spacer()
        Text(model.monthTitle)
          .font(.headline)
        Spacer()
        Button("下一个月", systemImage: "chevron.right") {
          Task { await model.moveSelectedMonth(by: 1) }
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
      }

      if model.baseCurrencyState != .confirmed {
        Text("记下首笔正式账目并确认本位币后显示月度概览。")
          .foregroundStyle(.primary)
      } else if model.isLoadingReport, model.monthlyReport == nil {
        HStack {
          ProgressView()
          Text("正在读取月度概览")
            .foregroundStyle(.primary)
        }
      } else if let report = model.monthlyReport {
        LabeledContent("收入", value: LedgerAmountText.formatted(report.income))
          .accessibilityLabel(
            Text("收入 \(LedgerAmountText.accessibilityFormatted(report.income))")
          )
        LabeledContent("支出", value: LedgerAmountText.formatted(report.expense))
          .accessibilityLabel(
            Text("支出 \(LedgerAmountText.accessibilityFormatted(report.expense))")
          )
        LabeledContent("净变化", value: LedgerAmountText.formatted(report.netChange))
          .accessibilityLabel(
            Text("净变化 \(LedgerAmountText.accessibilityFormatted(report.netChange))")
          )
        if !report.expenseCategories.isEmpty {
          Text("支出分类排行")
            .font(.headline)
        }
        ForEach(report.expenseCategories) { category in
          LabeledContent(
            category.name,
            value: LedgerAmountText.formatted(category.total)
          )
          .accessibilityLabel(
            Text("\(category.name) \(LedgerAmountText.accessibilityFormatted(category.total))")
          )
        }
        if !report.expenseTrend.isEmpty {
          Text("最近六个月支出趋势")
            .font(.headline)
          Chart(report.expenseTrend) { point in
            BarMark(
              x: .value("月份", "\(point.month.month)月"),
              y: .value("支出净额", point.expense.minorUnits)
            )
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("\(point.month.year) 年 \(point.month.month) 月")
            .accessibilityValue(LedgerAmountText.accessibilityFormatted(point.expense))
          }
          .chartYAxis(.hidden)
          .frame(height: 160)
          .accessibilityIdentifier("ledger.expense.trend")
        }
      } else if let reportErrorMessage = model.reportErrorMessage {
        Label {
          Text(reportErrorMessage)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.primary)
      }

      Group {
        Text("期间 \(model.monthTitle)")
        Text("本位币 \(model.baseCurrencyCode.rawValue)")
        Text("退款、更正、冲销计入净额")
        Text("转账不计入收支")
      }
      .font(.footnote)
      .foregroundStyle(.primary)

    } header: {
      Text("月度概览")
        .foregroundStyle(.primary)
    }
  }

  private func transactionLink(_ transaction: LedgerTransactionSummary) -> some View {
    NavigationLink {
      LedgerTransactionDetailView(
        rootID: transaction.rootID,
        environment: environment
      )
    } label: {
      LedgerTransactionSummaryRow(transaction: transaction)
    }
  }

  @ViewBuilder
  private func accountSection(
    _ title: LocalizedStringKey,
    summaries: [LedgerAccountSummary]
  ) -> some View {
    if !summaries.isEmpty {
      Section {
        ForEach(summaries) { summary in
          LedgerAccountSummaryRow(summary: summary)
        }
      } header: {
        Text(title).foregroundStyle(.primary)
      }
    }
  }
}

private struct LedgerFilterView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedFundingAccountID: UUID?
  @State private var selectedCategoryAccountID: UUID?
  @State private var journeyLinkFilter: LedgerJourneyLinkFilter

  let fundingAccounts: [LedgerAccountSummary]
  let categories: [LedgerAccountSummary]
  let onApply: (UUID?, UUID?, LedgerJourneyLinkFilter) -> Void

  init(
    fundingAccounts: [LedgerAccountSummary],
    categories: [LedgerAccountSummary],
    selectedFundingAccountID: UUID?,
    selectedCategoryAccountID: UUID?,
    journeyLinkFilter: LedgerJourneyLinkFilter,
    onApply: @escaping (UUID?, UUID?, LedgerJourneyLinkFilter) -> Void
  ) {
    self.fundingAccounts = fundingAccounts
    self.categories = categories
    self.onApply = onApply
    _selectedFundingAccountID = State(initialValue: selectedFundingAccountID)
    _selectedCategoryAccountID = State(initialValue: selectedCategoryAccountID)
    _journeyLinkFilter = State(initialValue: journeyLinkFilter)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("资金账户") {
          Picker("资金账户", selection: $selectedFundingAccountID) {
            Text("全部账户").tag(nil as UUID?)
            ForEach(fundingAccounts) { summary in
              Text(optionTitle(summary)).tag(Optional(summary.id))
            }
          }
          .accessibilityIdentifier("ledger.filter.funding-account")
        }

        Section("收入或支出分类") {
          Picker("分类", selection: $selectedCategoryAccountID) {
            Text("全部分类").tag(nil as UUID?)
            ForEach(categories) { summary in
              Text(optionTitle(summary)).tag(Optional(summary.id))
            }
          }
          .accessibilityIdentifier("ledger.filter.category")
        }

        Section("行程关联") {
          Picker("行程关联", selection: $journeyLinkFilter) {
            Text("全部").tag(LedgerJourneyLinkFilter.any)
            Text("已关联").tag(LedgerJourneyLinkFilter.linked)
            Text("未关联").tag(LedgerJourneyLinkFilter.unlinked)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("ledger.filter.journey-link")
        }

        Section {
          Button("重置条件", systemImage: "arrow.counterclockwise") {
            selectedFundingAccountID = nil
            selectedCategoryAccountID = nil
            journeyLinkFilter = .any
          }
        } footer: {
          Text("归档账户和分类仍可用于筛选历史；搜索框会与这里的条件共同生效。")
        }
      }
      .navigationTitle("筛选账目")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("应用") {
            onApply(
              selectedFundingAccountID,
              selectedCategoryAccountID,
              journeyLinkFilter
            )
            dismiss()
          }
          .accessibilityIdentifier("ledger.filter.apply")
        }
      }
    }
  }

  private func optionTitle(_ summary: LedgerAccountSummary) -> String {
    summary.account.status == .archived
      ? "\(summary.account.name)（已归档）"
      : summary.account.name
  }
}

struct LedgerAccountSummaryRow: View {
  let summary: LedgerAccountSummary
  let parentName: String?

  init(summary: LedgerAccountSummary, parentName: String? = nil) {
    self.summary = summary
    self.parentName = parentName
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: accountSymbol)
        .foregroundStyle(
          summary.account.status == .active ? Color.accentColor : Color.secondary
        )
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(summary.account.name)
        if summary.account.status == .archived {
          Text("已归档")
            .font(.caption)
            .foregroundStyle(.primary)
        }
        if let parentName {
          Text("父分类：\(parentName)")
            .font(.caption)
            .foregroundStyle(.primary)
        }
      }
      Spacer()
      Text("余额 \(LedgerAmountText.formatted(summary.balance))")
        .font(.body)
        .foregroundStyle(.primary)
        .accessibilityLabel(
          Text("余额 \(LedgerAmountText.accessibilityFormatted(summary.balance))")
        )
    }
  }

  private var accountSymbol: String {
    switch summary.account.subtype {
    case .cash:
      "banknote"
    case .bank:
      "building.columns"
    case .electronicWallet:
      "wallet.bifold"
    case .creditCard:
      "creditcard"
    case .food:
      "fork.knife"
    case .transport:
      "car"
    case .shopping:
      "bag"
    case .housing:
      "house"
    case .salary:
      "briefcase"
    default:
      "tag"
    }
  }
}
