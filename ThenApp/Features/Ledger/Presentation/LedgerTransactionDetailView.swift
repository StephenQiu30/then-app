import SwiftUI

struct LedgerTransactionDetailView: View {
  @State private var model: LedgerTransactionDetailViewModel

  init(rootID: UUID, environment: AppEnvironment) {
    _model = State(
      initialValue: LedgerTransactionDetailViewModel(
        rootID: rootID,
        environment: environment
      )
    )
  }

  var body: some View {
    Group {
      if model.isLoading, model.snapshot == nil {
        ProgressView("正在读取交易")
      } else if let snapshot = model.snapshot {
        List {
          summarySection(snapshot)
          flowSection(snapshot.currentTransaction)
          linkedJourneySection
          actionSection
          historySection(snapshot)
        }
      } else {
        ContentUnavailableView(
          "无法显示交易",
          systemImage: "exclamationmark.triangle",
          description: Text("请返回后重试。")
        )
      }
    }
    .navigationTitle("交易详情")
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) {
      if let successMessage = model.successMessage {
        Label(successMessage, systemImage: "checkmark.circle.fill")
          .font(.footnote)
          .foregroundStyle(.green)
          .padding()
          .background(.regularMaterial, in: .capsule)
          .padding()
      } else if let errorMessage = model.errorMessage, model.snapshot != nil {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
          .padding()
          .background(.regularMaterial, in: .rect(cornerRadius: 12))
          .padding()
      }
    }
    .task {
      await model.load()
    }
    .refreshable {
      await model.load()
    }
    .sheet(item: $model.presentedAction) { action in
      switch action {
      case .refund:
        LedgerRefundView(model: model)
      case .reverse:
        LedgerReversalView(model: model)
      case .correct:
        LedgerCorrectionView(model: model)
      }
    }
  }

  @ViewBuilder
  private var linkedJourneySection: some View {
    if !model.linkedJourneys.isEmpty {
      Section("关联行程") {
        ForEach(model.linkedJourneys) { journey in
          VStack(alignment: .leading, spacing: 4) {
            Text(journey.startedAt.formatted(date: .abbreviated, time: .shortened))
            Text("\(journey.transportMode.title) · \(journey.link.role.title)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func summarySection(
    _ snapshot: LedgerTransactionRootSnapshot
  ) -> some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        if let money = model.currentMoney {
          Text(LedgerAmountText.formatted(money))
            .font(.largeTitle.bold().monospacedDigit())
            .accessibilityIdentifier("ledger-transaction-detail-amount")
            .accessibilityLabel(
              Text(LedgerAmountText.accessibilityFormatted(money))
            )
        }
        HStack(spacing: 8) {
          Label(
            snapshot.currentTransaction.kind.title,
            systemImage: snapshot.currentTransaction.kind.symbol)
          if snapshot.isCurrentReversed {
            Label("已撤销", systemImage: "arrow.uturn.backward.circle.fill")
              .foregroundStyle(.secondary)
          }
        }
        .font(.subheadline)
      }
      .padding(.vertical, 6)

      if let payee = snapshot.currentTransaction.payee {
        HStack {
          Text("说明")
          Spacer()
          Text(payee)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("说明")
        .accessibilityValue(payee)
        .accessibilityIdentifier("ledger-transaction-detail-payee")
      }
      LabeledContent("发生日期", value: snapshot.currentTransaction.localDate)
      LabeledContent {
        Text(snapshot.currentTransaction.source.title)
      } label: {
        Text("来源")
      }
      if let note = snapshot.currentTransaction.note {
        LabeledContent("备注", value: note)
      }
      if snapshot.currentTransaction.kind == .expense {
        LabeledContent(
          "有效退款",
          value: formattedMinorUnits(snapshot.activeRefundMinorUnits)
        )
        .accessibilityLabel(
          Text(
            "有效退款 \(accessibilityFormattedMinorUnits(snapshot.activeRefundMinorUnits))"
          )
        )
        if let available = snapshot.availableRefundMinorUnits {
          LabeledContent("仍可退款", value: formattedMinorUnits(available))
            .accessibilityLabel(
              Text("仍可退款 \(accessibilityFormattedMinorUnits(available))")
            )
        }
      }
    }
  }

  private func flowSection(_ transaction: PostedLedgerTransaction) -> some View {
    Section("账户与分类") {
      ForEach(transaction.postings, id: \.id) { posting in
        LabeledContent {
          Text(model.accountName(for: posting.accountID))
        } label: {
          Text(model.postingRole(posting))
        }
      }
    }
  }

  @ViewBuilder
  private var actionSection: some View {
    if model.canRefund || model.canCorrect || model.canReverse {
      Section("操作") {
        if model.canRefund {
          Button("记录退款", systemImage: "arrow.down.left.circle") {
            model.selectAction(.refund)
          }
        }
        if model.canCorrect {
          Button("更正交易", systemImage: "pencil.circle") {
            model.selectAction(.correct)
          }
        }
        if model.canReverse {
          Button("撤销交易", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
            model.selectAction(.reverse)
          }
        }
      }
    }
  }

  private func historySection(
    _ snapshot: LedgerTransactionRootSnapshot
  ) -> some View {
    Section {
      ForEach(model.sortedHistory, id: \.id) { transaction in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Label(transaction.historyTitle, systemImage: transaction.kind.symbol)
            Spacer()
            if let money = transaction.postings.first?.money {
              Text(LedgerAmountText.formatted(money))
                .monospacedDigit()
                .accessibilityLabel(
                  Text(LedgerAmountText.accessibilityFormatted(money))
                )
            }
          }
          Text(transaction.localDate)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(transaction.source.title)
            .font(.caption)
            .foregroundStyle(.secondary)
          if transaction.id == snapshot.currentTransaction.id {
            Text(snapshot.isCurrentReversed ? "当前版本，已撤销" : "当前有效版本")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
    } header: {
      Text("完整历史")
    } footer: {
      Text("历史记录用于审计和重建余额，不能单独删除。")
    }
  }

  private func formattedMinorUnits(_ minorUnits: Int64) -> String {
    guard let currencyCode = model.currentMoney?.currencyCode,
      let money = try? PositiveMoney(
        minorUnits: max(1, minorUnits),
        currencyCode: currencyCode
      )
    else {
      return "0"
    }
    if minorUnits == 0 {
      return LedgerAmountText.formatted(
        SignedMoney(minorUnits: 0, currencyCode: currencyCode)
      )
    }
    return LedgerAmountText.formatted(money)
  }

  private func accessibilityFormattedMinorUnits(_ minorUnits: Int64) -> String {
    guard let currencyCode = model.currentMoney?.currencyCode else {
      return minorUnits.formatted()
    }
    return LedgerAmountText.accessibilityFormatted(
      SignedMoney(minorUnits: minorUnits, currencyCode: currencyCode)
    )
  }
}

extension LedgerTransactionSource {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .manual:
      "手动记账"
    case .ocr:
      "票据识别"
    case .systemSuggestion:
      "系统建议"
    }
  }
}

extension TripTransportMode {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .walking: "步行"
    case .driving: "驾车"
    case .transit: "公交"
    }
  }
}

extension JourneyExpenseRole {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .transport: "交通"
    case .parking: "停车"
    case .toll: "通行费"
    case .meal: "餐饮"
    case .other: "其他"
    }
  }
}

private struct LedgerRefundView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: LedgerTransactionDetailViewModel

  var body: some View {
    NavigationStack {
      Form {
        Section("退款") {
          HStack {
            Text(model.currentMoney?.currencyCode.rawValue ?? "")
              .foregroundStyle(.secondary)
            TextField("金额", text: $model.refundAmountText)
              .keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing)
          }
          Picker("到账账户", selection: $model.refundDestinationAccountID) {
            ForEach(model.refundDestinationOptions) { summary in
              Text(summary.account.name).tag(Optional(summary.id))
            }
          }
          DatePicker(
            "到账时间",
            selection: $model.refundOccurredAt,
            displayedComponents: [.date, .hourAndMinute]
          )
          TextField("备注（可选）", text: $model.refundNote, axis: .vertical)
        }
        if let available = model.snapshot?.availableRefundMinorUnits,
          let currencyCode = model.currentMoney?.currencyCode
        {
          Section {
            LabeledContent(
              "当前可退",
              value: LedgerAmountText.formatted(
                SignedMoney(minorUnits: available, currencyCode: currencyCode)
              )
            )
            .accessibilityLabel(
              Text(
                "当前可退 \(LedgerAmountText.accessibilityFormatted(SignedMoney(minorUnits: available, currencyCode: currencyCode)))"
              )
            )
          }
        }
        actionErrorSection
      }
      .navigationTitle("记录退款")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(model.isSaving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
            .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              if await model.saveRefund() { dismiss() }
            }
          }
          .disabled(model.isSaving || model.refundDestinationAccountID == nil)
        }
      }
    }
  }

  @ViewBuilder
  private var actionErrorSection: some View {
    if let errorMessage = model.errorMessage {
      Section {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
  }
}

private struct LedgerReversalView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: LedgerTransactionDetailViewModel

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("撤销原因", text: $model.reversalReason, axis: .vertical)
            .lineLimit(2...4)
          DatePicker(
            "撤销时间",
            selection: $model.reversalOccurredAt,
            displayedComponents: [.date, .hourAndMinute]
          )
        } footer: {
          Text("撤销会创建完全相反的正式分录。原交易和撤销记录都会保留。")
        }
        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("撤销交易")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(model.isSaving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
            .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("确认撤销", role: .destructive) {
            Task {
              if await model.saveReversal() { dismiss() }
            }
          }
          .disabled(model.isSaving)
        }
      }
    }
  }
}

private struct LedgerCorrectionView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: LedgerTransactionDetailViewModel

  var body: some View {
    NavigationStack {
      Form {
        Section("更正内容") {
          HStack {
            Text(model.currentMoney?.currencyCode.rawValue ?? "")
              .foregroundStyle(.secondary)
            TextField("金额", text: $model.correctionAmountText)
              .keyboardType(.decimalPad)
              .multilineTextAlignment(.trailing)
          }
          Picker(sourceTitle, selection: $model.correctionSourceAccountID) {
            ForEach(model.correctionSourceOptions) { summary in
              Text(summary.account.name).tag(Optional(summary.id))
            }
          }
          .onChange(of: model.correctionSourceAccountID) {
            model.reconcileCorrectionSelections()
          }
          Picker(secondaryTitle, selection: $model.correctionSecondaryAccountID) {
            ForEach(model.correctionSecondaryOptions) { summary in
              Text(summary.account.name).tag(Optional(summary.id))
            }
          }
          DatePicker(
            "发生时间",
            selection: $model.correctionOccurredAt,
            displayedComponents: [.date, .hourAndMinute]
          )
          TextField("说明（可选）", text: $model.correctionPayee)
          TextField("备注（可选）", text: $model.correctionNote, axis: .vertical)
            .lineLimit(2...4)
        }
        if let activeRefund = model.snapshot?.activeRefundMinorUnits,
          activeRefund > 0,
          let currencyCode = model.currentMoney?.currencyCode
        {
          Section {
            LabeledContent(
              "有效退款下限",
              value: LedgerAmountText.formatted(
                SignedMoney(minorUnits: activeRefund, currencyCode: currencyCode)
              )
            )
            .accessibilityLabel(
              Text(
                "有效退款下限 \(LedgerAmountText.accessibilityFormatted(SignedMoney(minorUnits: activeRefund, currencyCode: currencyCode)))"
              )
            )
          } footer: {
            Text("更正后的支出金额不能低于有效退款合计。")
          }
        }
        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("更正交易")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(model.isSaving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
            .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存更正") {
            Task {
              if await model.saveCorrection() { dismiss() }
            }
          }
          .disabled(
            model.isSaving
              || model.correctionSourceAccountID == nil
              || model.correctionSecondaryAccountID == nil
          )
        }
      }
    }
  }

  private var sourceTitle: LocalizedStringResource {
    switch model.currentTransaction?.kind {
    case .expense:
      "付款账户"
    case .income:
      "收款账户"
    case .transfer:
      "转出账户"
    default:
      "账户"
    }
  }

  private var secondaryTitle: LocalizedStringResource {
    switch model.currentTransaction?.kind {
    case .expense, .income:
      "分类"
    case .transfer:
      "转入账户"
    default:
      "账户"
    }
  }
}

extension LedgerTransactionKind {
  fileprivate var title: LocalizedStringResource {
    switch self {
    case .expense: "支出"
    case .income: "收入"
    case .transfer: "转账"
    case .refund: "退款"
    case .reversal: "冲销"
    case .opening: "期初余额"
    case .adjustment: "调整"
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .expense: "arrow.up.right.circle"
    case .income: "arrow.down.left.circle"
    case .transfer: "arrow.left.arrow.right.circle"
    case .refund: "arrow.down.backward.circle"
    case .reversal: "arrow.uturn.backward.circle"
    case .opening: "flag.circle"
    case .adjustment: "slider.horizontal.3"
    }
  }
}

extension PostedLedgerTransaction {
  fileprivate var historyTitle: LocalizedStringResource {
    if replacementForID != nil {
      return "更正后的版本"
    }
    if kind == .reversal, correctionGroupID != nil {
      return "更正冲销"
    }
    return kind.title
  }
}
