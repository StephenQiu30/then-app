import SwiftUI

struct TodayView: View {
  @State private var model: TodayViewModel
  @State private var isPresentingQuickTransaction = false
  @State private var isPresentingJourney = false
  @State private var revisionOccurrence: CalendarOccurrenceSummary?
  private let environment: AppEnvironment

  init(environment: AppEnvironment) {
    self.environment = environment
    _model = State(
      initialValue: TodayViewModel(
        ledgerIdentity: environment.localLedgerIdentity,
        launchMode: environment.launchMode,
        ledgerQuery: environment.ledgerQuery,
        snapshotService: environment.todaySnapshot
      )
    )
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.isSearchActive {
          searchContent
        } else {
          dashboardContent
        }
      }
      .navigationTitle("今天")
      .searchable(
        text: $model.searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "搜索账目"
      )
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("记一笔", systemImage: "plus") {
            isPresentingQuickTransaction = true
          }
        }
        ToolbarItem(placement: .secondaryAction) {
          Button("实际行程", systemImage: "location.circle") {
            isPresentingJourney = true
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
      .onAppear {
        Task { await model.loadRecentTransactions() }
      }
      .refreshable {
        await model.loadRecentTransactions()
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
      .sheet(
        isPresented: $isPresentingQuickTransaction,
        onDismiss: {
          Task { await model.loadRecentTransactions() }
        }
      ) {
        QuickTransactionView(
          identity: model.ledgerIdentity,
          confirmBaseCurrency: environment.confirmBaseCurrency,
          createTransaction: environment.createTransaction,
          ledgerQuery: environment.ledgerQuery,
          receiptOCR: environment.receiptOCR,
          receiptCameraAccess: environment.receiptCameraAccess
        ) { _ in
          Task { await model.loadRecentTransactions() }
        }
      }
      .sheet(isPresented: $isPresentingJourney) {
        JourneyRecordingView(environment: environment, initialPlan: nil)
      }
      .sheet(item: $revisionOccurrence) { occurrence in
        CalendarRevisionReviewView(environment: environment, occurrence: occurrence) {
          Task { await model.loadRecentTransactions() }
        }
      }
    }
  }

  @ViewBuilder
  private var searchContent: some View {
    if model.isSearching, model.searchResults.isEmpty {
      ProgressView("正在搜索本地账目")
    } else if model.searchResults.isEmpty {
      ContentUnavailableView.search(text: model.searchText)
    } else {
      List {
        Section("搜索结果") {
          ForEach(model.searchResults) { transaction in
            transactionLink(transaction)
          }
        }
      }
      .headerProminence(.increased)
      .modifier(AdaptiveHardScrollEdgeEffectModifier())
    }
  }

  private var dashboardContent: some View {
    List {
      Section {
        if model.snapshotIssues.contains(.calendar) {
          Label("日程暂时无法读取，其他本地内容仍可使用。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.primary)
        } else if model.todayOccurrences.isEmpty {
          Text("今天没有已缓存的日程")
            .foregroundStyle(.primary)
        } else {
          ForEach(model.todayOccurrences) { occurrence in
            VStack(alignment: .leading, spacing: 4) {
              Text(occurrence.title ?? "未命名事件")
              Text(occurrenceTime(occurrence))
                .font(.caption)
                .foregroundStyle(.primary)
              if let location = occurrence.locationText {
                Label(location, systemImage: "mappin.and.ellipse")
                  .font(.caption)
                  .foregroundStyle(.primary)
              }
            }
            .accessibilityElement(children: .combine)
          }
        }
      } header: {
        Text("今日安排").foregroundStyle(.primary)
      }

      Section {
        if model.snapshotIssues.contains(.tripPlans) {
          Label("出行计划暂时无法读取。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.primary)
        } else if let plan = model.nextTripPlan {
          VStack(alignment: .leading, spacing: 5) {
            Text(plan.displayName ?? plan.destination.name)
              .font(.headline)
            if let departure = plan.plannedDepartureAt {
              LabeledContent(
                "出发",
                value: departure.formatted(date: .abbreviated, time: .shortened)
              )
            }
            LabeledContent(
              "到达",
              value: plan.targetArrivalAt.formatted(date: .abbreviated, time: .shortened)
            )
            Text(plan.routeEstimate == nil ? "手动确认时间" : "MapKit 路线快照")
              .font(.caption)
              .foregroundStyle(.primary)
          }
        } else {
          Text("没有待出发计划，可在“行程”中创建。")
            .foregroundStyle(.primary)
        }
      } header: {
        Text("下一次出发").foregroundStyle(.primary)
      }

      if let journey = model.currentJourney {
        Section {
          Button {
            isPresentingJourney = true
          } label: {
            LabeledContent(journeyStatusTitle(journey.status)) {
              Text(journey.startedAt.formatted(date: .abbreviated, time: .shortened))
            }
          }
        } header: {
          Text("未收口行程").foregroundStyle(.primary)
        }
      } else if model.snapshotIssues.contains(.journeys) {
        Section {
          Label("行程暂时无法读取。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.primary)
        } header: {
          Text("实际行程").foregroundStyle(.primary)
        }
      }

      if let report = model.monthlyReport {
        monthlyReportSection(report)
      } else if model.snapshotIssues.contains(.ledger) {
        Section {
          Label("账本暂时无法读取。", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.primary)
        } header: {
          Text("本月收支").foregroundStyle(.primary)
        }
      } else if model.ledgerIdentity.baseCurrencyState != .confirmed {
        Section {
          Text("记下首笔正式账目并确认本位币后显示月度摘要。")
            .foregroundStyle(.primary)
        } header: {
          Text("本月收支").foregroundStyle(.primary)
        }
      }

      if model.pending.total > 0 {
        Section {
          if let count = model.pending.calendarRevisionCount, count > 0 {
            Button {
              Task {
                revisionOccurrence = try? await environment.calendarImport
                  .visibleOccurrences()
                  .first { $0.hasPendingRevision }
              }
            } label: {
              LabeledContent("日历来源变化", value: count.formatted())
            }
            .accessibilityHint("打开第一项待处理来源变化")
          }
          if let count = model.pending.journeyReviewCount, count > 0 {
            LabeledContent("待确认行程摘要", value: count.formatted())
          }
        } header: {
          Text("待处理").foregroundStyle(.primary)
        }
      }

      Section {
        if model.recentTransactions.isEmpty {
          Button("记一笔") {
            isPresentingQuickTransaction = true
          }
          Text("本地模式，无需登录或网络。")
            .font(.footnote)
            .foregroundStyle(.primary)
        } else {
          ForEach(model.recentTransactions) { transaction in
            transactionLink(transaction)
          }
        }
      } header: {
        Text("最近记账").foregroundStyle(.primary)
      }
    }
    .headerProminence(.increased)
    .modifier(AdaptiveHardScrollEdgeEffectModifier())
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

  private func monthlyReportSection(_ report: LedgerMonthlyReport) -> some View {
    Section {
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
      ForEach(report.expenseCategories.prefix(3)) { category in
        LabeledContent(
          category.name,
          value: LedgerAmountText.formatted(category.total)
        )
        .accessibilityLabel(
          Text("\(category.name) \(LedgerAmountText.accessibilityFormatted(category.total))")
        )
      }
      Text("退款已抵减支出，转账不计入收支。")
        .font(.footnote)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text(verbatim: "\(report.month.year) 年 \(report.month.month) 月")
        .foregroundStyle(.primary)
    }
  }

  private func occurrenceTime(_ occurrence: CalendarOccurrenceSummary) -> String {
    if occurrence.isAllDay { return "全天" }
    return occurrence.startsAt.formatted(date: .omitted, time: .shortened)
      + "–"
      + occurrence.endsAt.formatted(date: .omitted, time: .shortened)
  }

  private func journeyStatusTitle(_ status: JourneyStatus) -> String {
    switch status {
    case .recording: "正在记录"
    case .paused: "已暂停，可继续"
    case .finalizing: "正在生成摘要"
    case .reviewing: "摘要待确认"
    case .completed: "已完成"
    case .discarded: "已丢弃"
    }
  }
}

struct LedgerTransactionSummaryRow: View {
  let transaction: LedgerTransactionSummary

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        if let payee = transaction.payee {
          Text(payee)
        } else {
          Text(fallbackTitle)
        }
        Text(transaction.localDate)
          .font(.caption)
          .foregroundStyle(.primary)
        if transaction.isReversed {
          Text("已撤销")
            .font(.caption)
            .foregroundStyle(.primary)
        } else if transaction.activeRefundMinorUnits > 0 {
          Text("含退款")
            .font(.caption)
            .foregroundStyle(.primary)
        }
      }
      Spacer()
      Text("\(amountPrefix)\(LedgerAmountText.formatted(transaction.money))")
        .font(.body.monospacedDigit())
        .accessibilityLabel(
          "\(kindTitle) \(LedgerAmountText.accessibilityFormatted(transaction.money))"
        )
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint("打开交易详情")
  }

  private var amountPrefix: String {
    switch transaction.kind {
    case .expense:
      "−"
    case .income:
      "+"
    case .transfer, .refund, .reversal, .opening, .adjustment:
      ""
    }
  }

  private var kindTitle: LocalizedStringResource {
    switch transaction.kind {
    case .expense:
      "支出"
    case .income:
      "收入"
    case .transfer:
      "转账"
    case .refund:
      "退款"
    case .reversal:
      "冲销"
    case .opening:
      "期初余额"
    case .adjustment:
      "调整"
    }
  }

  private var fallbackTitle: LocalizedStringResource {
    switch transaction.kind {
    case .expense:
      "未填写商户"
    default:
      kindTitle
    }
  }
}
