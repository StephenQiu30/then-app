import PhotosUI
import SwiftUI

struct QuickTransactionView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: QuickTransactionViewModel
  @State private var selectedReceiptPhoto: PhotosPickerItem?
  @State private var isPresentingReceiptCamera = false
  private let allowsTransactionTypeSelection: Bool
  let onSaved: (PostedLedgerTransaction) -> Void

  init(
    identity: LocalLedgerIdentity,
    confirmBaseCurrency: ConfirmBaseCurrencyUseCase,
    createTransaction: CreateTransactionUseCase,
    ledgerQuery: LedgerQueryService,
    receiptOCR: any ReceiptOCRService,
    receiptCameraAccess: any ReceiptCameraAccessService,
    initialTransactionType: ManualTransactionType = .expense,
    allowsTransactionTypeSelection: Bool = true,
    onSaved: @escaping (PostedLedgerTransaction) -> Void
  ) {
    _model = State(
      initialValue: QuickTransactionViewModel(
        identity: identity,
        confirmBaseCurrency: confirmBaseCurrency,
        createTransaction: createTransaction,
        ledgerQuery: ledgerQuery,
        receiptOCR: receiptOCR,
        receiptCameraAccess: receiptCameraAccess,
        initialTransactionType: initialTransactionType
      )
    )
    self.allowsTransactionTypeSelection = allowsTransactionTypeSelection
    self.onSaved = onSaved
  }

  var body: some View {
    NavigationStack {
      Form {
        if allowsTransactionTypeSelection {
          Section {
            Picker(
              "类型",
              selection: Binding(
                get: { model.transactionType },
                set: { model.selectTransactionType($0) }
              )
            ) {
              ForEach(ManualTransactionType.allCases) { type in
                Text(type.title).tag(type)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("记账类型")
          }
        } else {
          Section {
            LabeledContent {
              Text(model.transactionType.title)
            } label: {
              Text("类型")
            }
          }
        }

        Section {
          HStack(alignment: .firstTextBaseline) {
            Text(model.selectedCurrencyCode.rawValue)
              .foregroundStyle(.primary)
              .accessibilityHidden(true)
            TextField("金额", text: $model.amountText)
              .keyboardType(.decimalPad)
              .font(.title2.monospacedDigit())
              .multilineTextAlignment(.trailing)
              .accessibilityLabel("金额")
          }

          if model.isLoadingAccounts {
            HStack {
              ProgressView()
              Text("正在读取账户")
                .foregroundStyle(.primary)
            }
          } else {
            accountSelectors
          }

          DatePicker(
            "发生时间",
            selection: $model.occurredAt,
            displayedComponents: [.date, .hourAndMinute]
          )
        } header: {
          Text(model.transactionType.title)
            .foregroundStyle(.primary)
        }

        Section {
          TextField(text: $model.payee) {
            Text(descriptionFieldTitle)
          }
          .textInputAutocapitalization(.never)
          TextField("备注（可选）", text: $model.note, axis: .vertical)
            .lineLimit(2...4)
        } header: {
          Text("补充信息")
            .foregroundStyle(.primary)
        }

        if model.transactionType == .expense {
          receiptRecognitionSection
          if let candidate = model.receiptCandidate {
            receiptCandidateSection(candidate)
          }
        }

        Section {
          if model.isCurrencyConfirmed {
            LabeledContent("本位币", value: model.selectedCurrencyCode.rawValue)
          } else {
            Picker("确认本位币", selection: $model.selectedCurrencyCode) {
              ForEach(model.currencyOptions, id: \.self) { currencyCode in
                Text(currencyCode.rawValue).tag(currencyCode)
              }
            }
          }
        } footer: {
          if model.isCurrencyConfirmed {
            Text("本位币已确认。后续变更需要独立的数据迁移流程。")
              .foregroundStyle(.primary)
          } else {
            Text("系统地区只提供建议。保存首笔账目前，请确认用于账户和报表的本位币。")
              .foregroundStyle(.primary)
          }
        }

        if !model.isLoadingAccounts, !model.hasRequiredOptions {
          Section {
            if model.transactionType == .creditCardRepayment,
              model.activeCreditCardAccounts.isEmpty
            {
              ContentUnavailableView {
                Label("没有可用信用卡", systemImage: "creditcard")
              } description: {
                Text("请关闭当前页面，前往“账本”的账户管理创建或恢复信用卡。")
              }
            } else {
              ContentUnavailableView {
                Label("缺少可用账户或分类", systemImage: "tray")
              } description: {
                Text("请关闭当前页面，前往“账本”管理账户和分类。")
              }
            }
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label {
              Text(errorMessage)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
          }
        }

        if let savedTransaction = model.savedTransaction,
          let money = savedTransaction.postings.first?.money
        {
          Section {
            Label {
              Text("已保存 \(LedgerAmountText.formatted(money))")
                .accessibilityLabel(
                  Text("已保存 \(LedgerAmountText.accessibilityFormatted(money))")
                )
            } icon: {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
      .headerProminence(.increased)
      .modifier(AdaptiveHardScrollEdgeEffectModifier())
      .navigationTitle("记一笔")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(model.isSaving)
      .onDisappear {
        model.clearReceiptSession()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            dismiss()
          }
          .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if let savedTransaction = model.savedTransaction {
            Button("完成") {
              onSaved(savedTransaction)
              dismiss()
            }
          } else {
            Button("保存") {
              Task { await model.save() }
            }
            .disabled(model.isSaving || model.isLoadingAccounts || !model.hasRequiredOptions)
          }
        }
      }
      .overlay {
        if model.isSaving {
          ProgressView("正在保存")
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
      }
      .task {
        await model.loadAccounts()
      }
      .task(id: selectedReceiptPhoto) {
        guard let selectedReceiptPhoto else { return }
        defer { self.selectedReceiptPhoto = nil }
        do {
          guard let data = try await selectedReceiptPhoto.loadTransferable(type: Data.self) else {
            model.receiptImageLoadingFailed()
            return
          }
          await model.recognizeReceiptImage(data)
        } catch is CancellationError {
          return
        } catch {
          model.receiptImageLoadingFailed()
        }
      }
      .sheet(isPresented: $isPresentingReceiptCamera) {
        ReceiptCameraPicker(
          onImageData: { data in
            isPresentingReceiptCamera = false
            Task { await model.recognizeReceiptImage(data) }
          },
          onFailure: {
            isPresentingReceiptCamera = false
            model.receiptImageLoadingFailed()
          },
          onCancel: {
            isPresentingReceiptCamera = false
          }
        )
        .ignoresSafeArea()
      }
    }
  }

  private var receiptRecognitionSection: some View {
    Section {
      PhotosPicker(
        selection: $selectedReceiptPhoto,
        matching: .images,
        photoLibrary: .shared()
      ) {
        Label("选择票据照片", systemImage: "photo.on.rectangle")
      }
      .disabled(model.isRecognizingReceipt || model.isSaving)

      Button {
        guard ReceiptCameraPicker.isAvailable else {
          model.cameraUnavailable()
          return
        }
        Task {
          if await model.requestReceiptCameraAccess() {
            isPresentingReceiptCamera = true
          }
        }
      } label: {
        Label("拍摄票据", systemImage: "camera")
      }
      .disabled(model.isRecognizingReceipt || model.isSaving)

      if model.isRecognizingReceipt {
        HStack {
          ProgressView()
          Text("正在设备内识别")
            .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
      }
      if let receiptMessage = model.receiptMessage {
        Text(receiptMessage)
          .font(.footnote)
          .foregroundStyle(.primary)
      }
    } header: {
      VStack(alignment: .leading, spacing: 4) {
        Text("票据识别")
        Text("票据图片仅用于本机本次识别，不保存或上传。")
          .font(.footnote)
      }
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func receiptCandidateSection(_ candidate: ReceiptOCRCandidate) -> some View {
    Section {
      if let amount = candidate.amount {
        candidateRow("金额", value: amount.value, lowConfidence: amount.isLowConfidence)
      } else {
        candidateRow("金额", value: "未识别", lowConfidence: true)
      }
      if let payee = candidate.payee {
        candidateRow("商户", value: payee.value, lowConfidence: payee.isLowConfidence)
      } else {
        candidateRow("商户", value: "未识别", lowConfidence: true)
      }
      if let occurredAt = candidate.occurredAt {
        candidateRow(
          "日期",
          value: occurredAt.value.formatted(date: .numeric, time: .shortened),
          lowConfidence: occurredAt.isLowConfidence
        )
      } else {
        candidateRow("日期", value: "未识别", lowConfidence: true)
      }
      if let currencyCode = candidate.currencyCode {
        candidateRow(
          "币种",
          value: currencyCode.value.rawValue,
          lowConfidence: currencyCode.isLowConfidence
        )
      }
      if let orderIdentifier = candidate.orderIdentifier {
        candidateRow(
          "订单号",
          value: orderIdentifier.value,
          lowConfidence: orderIdentifier.isLowConfidence
        )
      }

      if !candidate.lowConfidenceFields.isEmpty {
        Label("标记字段需要重点核对", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if !model.receiptDuplicateMatches.isEmpty {
        Label(
          "可能与 \(model.receiptDuplicateMatches.count) 笔现有账目重复",
          systemImage: "doc.on.doc"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }

      Button("采用候选") {
        model.applyReceiptCandidate()
      }
      .buttonStyle(.borderedProminent)

      Button("忽略候选", role: .cancel) {
        model.ignoreReceiptCandidate()
      }
    } header: {
      Text("识别候选")
    } footer: {
      Text("采用只会填入上方表单；核对并点击保存后才会影响账本。")
    }
  }

  private func candidateRow(
    _ title: LocalizedStringKey,
    value: String,
    lowConfidence: Bool
  ) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        Text(value)
        if lowConfidence {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
            .accessibilityLabel("需要核对")
        }
      }
    } label: {
      Text(title)
    }
  }

  @ViewBuilder
  private var accountSelectors: some View {
    Picker(sourceAccountTitle, selection: $model.selectedSourceAccountID) {
      ForEach(model.sourceAccountOptions) { summary in
        Text(summary.account.name).tag(Optional(summary.id))
      }
    }
    .onChange(of: model.selectedSourceAccountID) {
      model.reconcileSelections()
    }

    switch model.transactionType {
    case .expense, .income:
      Picker("分类", selection: $model.selectedCategoryID) {
        ForEach(model.categoryOptions) { summary in
          Text(summary.account.name).tag(Optional(summary.id))
        }
      }
    case .transfer:
      Picker("转入账户", selection: $model.selectedDestinationAccountID) {
        ForEach(model.destinationAccountOptions) { summary in
          Text(summary.account.name).tag(Optional(summary.id))
        }
      }
    case .creditCardRepayment:
      Picker("信用卡账户", selection: $model.selectedDestinationAccountID) {
        ForEach(model.destinationAccountOptions) { summary in
          Text(summary.account.name).tag(Optional(summary.id))
        }
      }
    }
  }

  private var sourceAccountTitle: LocalizedStringResource {
    switch model.transactionType {
    case .expense:
      "付款账户"
    case .income:
      "收款账户"
    case .transfer:
      "转出账户"
    case .creditCardRepayment:
      "还款账户"
    }
  }

  private var descriptionFieldTitle: LocalizedStringResource {
    switch model.transactionType {
    case .expense:
      "商户（可选）"
    case .income:
      "来源（可选）"
    case .transfer:
      "说明（可选）"
    case .creditCardRepayment:
      "还款说明（可选）"
    }
  }
}
