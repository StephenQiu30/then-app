import Foundation
import Observation

nonisolated enum ManualTransactionType: String, CaseIterable, Identifiable, Sendable {
  case expense
  case income
  case transfer
  case creditCardRepayment

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .expense:
      "支出"
    case .income:
      "收入"
    case .transfer:
      "转账"
    case .creditCardRepayment:
      "还款"
    }
  }
}

@MainActor
@Observable
final class QuickTransactionViewModel {
  private let ownerID: UUID
  private let defaultCashAccountID: UUID
  private let defaultExpenseCategoryID: UUID
  private let defaultIncomeCategoryID: UUID
  private let confirmBaseCurrency: ConfirmBaseCurrencyUseCase
  private let createTransaction: CreateTransactionUseCase
  private let ledgerQuery: LedgerQueryService
  private let receiptOCR: any ReceiptOCRService
  private let receiptCameraAccess: any ReceiptCameraAccessService
  private let now: @Sendable () -> Date
  private let timeZoneIdentifier: @Sendable () -> String
  private var pendingTransactionID = UUID()
  private var receiptRecognitionGeneration = 0
  private var transactionSource: LedgerTransactionSource = .manual

  let currencyOptions: [CurrencyCode]
  var transactionType: ManualTransactionType = .expense
  var amountText = ""
  var payee = ""
  var note = ""
  var occurredAt: Date
  var selectedCurrencyCode: CurrencyCode
  var selectedSourceAccountID: UUID?
  var selectedDestinationAccountID: UUID?
  var selectedCategoryID: UUID?
  var accountSummaries: [LedgerAccountSummary] = []
  var isCurrencyConfirmed: Bool
  var isLoadingAccounts = false
  var isSaving = false
  var savedTransaction: PostedLedgerTransaction?
  var errorMessage: LocalizedStringResource?
  var receiptCandidate: ReceiptOCRCandidate?
  var receiptDuplicateMatches: [LedgerTransactionSummary] = []
  var isRecognizingReceipt = false
  var receiptMessage: LocalizedStringResource?

  init(
    identity: LocalLedgerIdentity,
    confirmBaseCurrency: ConfirmBaseCurrencyUseCase,
    createTransaction: CreateTransactionUseCase,
    ledgerQuery: LedgerQueryService,
    receiptOCR: any ReceiptOCRService = VisionReceiptOCRService(),
    receiptCameraAccess: any ReceiptCameraAccessService = AVReceiptCameraAccessService(),
    initialTransactionType: ManualTransactionType = .expense,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
  ) {
    ownerID = identity.profileID
    defaultCashAccountID = identity.defaultCashAccountID
    defaultExpenseCategoryID = identity.defaultExpenseCategoryID
    defaultIncomeCategoryID = identity.defaultIncomeCategoryID
    self.confirmBaseCurrency = confirmBaseCurrency
    self.createTransaction = createTransaction
    self.ledgerQuery = ledgerQuery
    self.receiptOCR = receiptOCR
    self.receiptCameraAccess = receiptCameraAccess
    transactionType = initialTransactionType
    self.now = now
    self.timeZoneIdentifier = timeZoneIdentifier
    occurredAt = now()
    selectedCurrencyCode = identity.baseCurrencyCode
    isCurrencyConfirmed = identity.baseCurrencyState == .confirmed
    currencyOptions = Locale.commonISOCurrencyCodes
      .compactMap(CurrencyCode.init(rawValue:))
      .sorted { $0.rawValue < $1.rawValue }
  }

  var activeFundingAccounts: [LedgerAccountSummary] {
    accountSummaries.filter {
      $0.account.status == .active
        && ($0.account.kind == .asset || $0.account.kind == .liability)
    }
  }

  var activeReceivingAccounts: [LedgerAccountSummary] {
    accountSummaries.filter {
      $0.account.status == .active && $0.account.kind == .asset
    }
  }

  var activeCreditCardAccounts: [LedgerAccountSummary] {
    accountSummaries.filter {
      $0.account.status == .active
        && $0.account.kind == .liability
        && $0.account.subtype == .creditCard
    }
  }

  var activeExpenseCategories: [LedgerAccountSummary] {
    activeCategories(kind: .expense)
  }

  var activeIncomeCategories: [LedgerAccountSummary] {
    activeCategories(kind: .income)
  }

  var sourceAccountOptions: [LedgerAccountSummary] {
    switch transactionType {
    case .expense, .transfer:
      activeFundingAccounts
    case .income, .creditCardRepayment:
      activeReceivingAccounts
    }
  }

  var categoryOptions: [LedgerAccountSummary] {
    switch transactionType {
    case .expense:
      activeExpenseCategories
    case .income:
      activeIncomeCategories
    case .transfer, .creditCardRepayment:
      []
    }
  }

  var destinationAccountOptions: [LedgerAccountSummary] {
    switch transactionType {
    case .creditCardRepayment:
      activeCreditCardAccounts
    case .transfer:
      activeFundingAccounts.filter { $0.id != selectedSourceAccountID }
    case .expense, .income:
      []
    }
  }

  var hasRequiredOptions: Bool {
    guard selectedSourceAccountID != nil else { return false }
    switch transactionType {
    case .expense, .income:
      return selectedCategoryID != nil
    case .transfer, .creditCardRepayment:
      return selectedDestinationAccountID != nil
    }
  }

  func loadAccounts() async {
    guard !isLoadingAccounts else { return }
    isLoadingAccounts = true
    errorMessage = nil
    defer { isLoadingAccounts = false }

    do {
      async let profile = ledgerQuery.localProfile(ownerID: ownerID)
      async let summaries = ledgerQuery.accountSummaries(ownerID: ownerID)
      let loadedProfile = try await profile
      selectedCurrencyCode = loadedProfile.baseCurrencyCode
      isCurrencyConfirmed = loadedProfile.baseCurrencyState == .confirmed
      accountSummaries = try await summaries
      reconcileSelections()
    } catch {
      errorMessage = "无法读取账户和分类，请稍后重试。"
    }
  }

  func selectTransactionType(_ type: ManualTransactionType) {
    guard savedTransaction == nil else { return }
    transactionType = type
    selectedSourceAccountID = nil
    selectedDestinationAccountID = nil
    selectedCategoryID = nil
    errorMessage = nil
    if type != .expense {
      clearReceiptSession()
      transactionSource = .manual
    }
    reconcileSelections()
  }

  func recognizeReceiptImage(_ imageData: Data) async {
    guard transactionType == .expense, !isSaving else { return }
    receiptRecognitionGeneration += 1
    let generation = receiptRecognitionGeneration
    isRecognizingReceipt = true
    receiptCandidate = nil
    receiptDuplicateMatches = []
    receiptMessage = nil
    defer {
      if generation == receiptRecognitionGeneration {
        isRecognizingReceipt = false
      }
    }

    do {
      let candidate = try await receiptOCR.recognizeReceipt(
        imageData: imageData,
        referenceDate: occurredAt,
        baseCurrencyCode: selectedCurrencyCode
      )
      guard generation == receiptRecognitionGeneration else { return }
      receiptCandidate = candidate
      receiptDuplicateMatches = await duplicateMatches(for: candidate)
      receiptMessage = nil
    } catch is CancellationError {
      return
    } catch ReceiptOCRError.noRecognizedText, ReceiptOCRError.noUsableCandidate {
      guard generation == receiptRecognitionGeneration else { return }
      receiptMessage = "没有识别出可用字段，现有手动输入未改变。"
    } catch {
      guard generation == receiptRecognitionGeneration else { return }
      receiptMessage = "票据识别失败，现有手动输入未改变，可以重试或继续手动记账。"
    }
  }

  func receiptImageLoadingFailed() {
    receiptMessage = "无法读取所选图片，现有手动输入未改变。"
  }

  func cameraUnavailable() {
    receiptMessage = "当前设备无法使用相机，可以选择照片或继续手动记账。"
  }

  func requestReceiptCameraAccess() async -> Bool {
    guard !isSaving, !isRecognizingReceipt else { return false }
    let access = await receiptCameraAccess.requestAccess()
    guard access == .allowed else {
      receiptMessage = "没有相机权限，现有手动输入未改变；可以选择照片或继续手动记账。"
      return false
    }
    receiptMessage = nil
    return true
  }

  func applyReceiptCandidate() {
    guard let candidate = receiptCandidate else { return }
    if let amount = candidate.amount {
      if let currency = candidate.currencyCode, currency.value != selectedCurrencyCode {
        receiptMessage = "票据币种与当前账本本位币不同，金额未自动填入，请手动核对。"
      } else {
        amountText = amount.value
        receiptMessage = "候选已填入表单，请逐项核对并点击保存。"
      }
    } else {
      receiptMessage = "已采用可用候选，请补充金额并点击保存。"
    }
    if let payee = candidate.payee {
      self.payee = payee.value
    }
    if let candidateDate = candidate.occurredAt {
      occurredAt = candidateDate.value
    }
    if let orderIdentifier = candidate.orderIdentifier, note.isEmpty {
      note = "订单号：\(orderIdentifier.value)"
    }
    transactionSource = .ocr
    receiptCandidate = nil
    receiptDuplicateMatches = []
  }

  func ignoreReceiptCandidate() {
    receiptRecognitionGeneration += 1
    isRecognizingReceipt = false
    receiptCandidate = nil
    receiptDuplicateMatches = []
    receiptMessage = nil
  }

  func clearReceiptSession() {
    receiptRecognitionGeneration += 1
    isRecognizingReceipt = false
    receiptCandidate = nil
    receiptDuplicateMatches = []
    receiptMessage = nil
  }

  func reconcileSelections() {
    selectedSourceAccountID = validSelection(
      selectedSourceAccountID,
      in: sourceAccountOptions,
      preferredID: defaultCashAccountID
    )

    switch transactionType {
    case .expense:
      selectedCategoryID = validSelection(
        selectedCategoryID,
        in: activeExpenseCategories,
        preferredID: defaultExpenseCategoryID
      )
      selectedDestinationAccountID = nil
    case .income:
      selectedCategoryID = validSelection(
        selectedCategoryID,
        in: activeIncomeCategories,
        preferredID: defaultIncomeCategoryID
      )
      selectedDestinationAccountID = nil
    case .transfer, .creditCardRepayment:
      selectedCategoryID = nil
      selectedDestinationAccountID = validSelection(
        selectedDestinationAccountID,
        in: destinationAccountOptions,
        preferredID: nil
      )
    }
  }

  func save() async {
    guard !isSaving, savedTransaction == nil else { return }
    guard let details = transactionDetails() else {
      errorMessage = "没有足够的可用账户或分类，请先到账本中管理账户。"
      return
    }

    isSaving = true
    errorMessage = nil
    defer { isSaving = false }

    do {
      let money = try LedgerAmountText.parsePositiveMoney(
        amountText,
        currencyCode: selectedCurrencyCode
      )
      if !isCurrencyConfirmed {
        let profile = try await confirmBaseCurrency.execute(
          ownerID: ownerID,
          currencyCode: selectedCurrencyCode,
          confirmedAt: now()
        )
        selectedCurrencyCode = profile.baseCurrencyCode
        isCurrencyConfirmed = profile.baseCurrencyState == .confirmed
      }

      let request = try CreateLedgerTransactionRequest(
        transactionID: pendingTransactionID,
        ownerID: ownerID,
        details: details,
        money: money,
        occurredAt: occurredAt,
        originalTimeZoneIdentifier: timeZoneIdentifier(),
        payee: payee,
        note: note,
        source: transactionSource,
        submittedAt: now()
      )
      savedTransaction = try await createTransaction.execute(request)
      pendingTransactionID = UUID()
    } catch {
      errorMessage = Self.userMessage(for: error)
    }
  }

  private func activeCategories(kind: LedgerAccountKind) -> [LedgerAccountSummary] {
    accountSummaries.filter {
      $0.account.status == .active && $0.account.kind == kind
    }
  }

  private func duplicateMatches(
    for candidate: ReceiptOCRCandidate
  ) async -> [LedgerTransactionSummary] {
    let currencyCode = candidate.currencyCode?.value ?? selectedCurrencyCode
    guard let amountText = candidate.amount?.value,
      currencyCode == selectedCurrencyCode,
      let money = try? LedgerAmountText.parsePositiveMoney(
        amountText,
        currencyCode: currencyCode,
        locale: Locale(identifier: "en_US_POSIX")
      )
    else {
      return []
    }

    do {
      let matches = try await ledgerQuery.searchTransactions(
        ownerID: ownerID,
        searchText: amountText,
        amountMinorUnits: money.minorUnits,
        limit: 20
      )
      guard let candidatePayee = candidate.payee?.value else {
        return matches.filter { $0.money.currencyCode == currencyCode }
      }
      let normalizedCandidatePayee = normalizedPayee(candidatePayee)
      return matches.filter { summary in
        guard summary.money.currencyCode == currencyCode,
          let existingPayee = summary.payee
        else {
          return false
        }
        let normalizedExistingPayee = normalizedPayee(existingPayee)
        return normalizedExistingPayee.contains(normalizedCandidatePayee)
          || normalizedCandidatePayee.contains(normalizedExistingPayee)
      }
    } catch {
      return []
    }
  }

  private func normalizedPayee(_ payee: String) -> String {
    payee
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current
      )
      .filter { !$0.isWhitespace && !$0.isPunctuation }
  }

  private func validSelection(
    _ selection: UUID?,
    in options: [LedgerAccountSummary],
    preferredID: UUID?
  ) -> UUID? {
    if let selection, options.contains(where: { $0.id == selection }) {
      return selection
    }
    if let preferredID, options.contains(where: { $0.id == preferredID }) {
      return preferredID
    }
    return options.first?.id
  }

  private func transactionDetails() -> ManualLedgerTransactionDetails? {
    guard let selectedSourceAccountID else { return nil }
    switch transactionType {
    case .expense:
      guard let selectedCategoryID else { return nil }
      return .expense(
        paymentAccountID: selectedSourceAccountID,
        categoryAccountID: selectedCategoryID
      )
    case .income:
      guard let selectedCategoryID else { return nil }
      return .income(
        receivingAccountID: selectedSourceAccountID,
        categoryAccountID: selectedCategoryID
      )
    case .transfer, .creditCardRepayment:
      guard let selectedDestinationAccountID else { return nil }
      return .transfer(
        sourceAccountID: selectedSourceAccountID,
        destinationAccountID: selectedDestinationAccountID
      )
    }
  }

  private static func userMessage(for error: Error) -> LocalizedStringResource {
    switch error {
    case LedgerAmountText.ParsingError.empty:
      "请输入金额。"
    case LedgerAmountText.ParsingError.tooManyFractionDigits:
      "金额的小数位数超过了当前币种允许的范围。"
    case LedgerAmountText.ParsingError.invalidCharacters,
      PositiveMoney.ValidationError.amountMustBePositive:
      "请输入大于零的有效金额。"
    case LedgerAmountText.ParsingError.outOfRange:
      "金额过大，请输入较小的金额。"
    case LedgerError.baseCurrencyAlreadyConfirmed:
      "本位币已经确认，不能在记账时直接修改。"
    case LedgerError.accountArchived, LedgerError.accountNotFound:
      "所选账户或分类已经不可用，请重新选择。"
    case LedgerError.transferAccountsMustDiffer:
      "转出和转入账户不能相同。"
    default:
      "保存失败，输入内容仍然保留，请稍后重试。"
    }
  }
}
