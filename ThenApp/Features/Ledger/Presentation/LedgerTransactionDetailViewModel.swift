import Foundation
import Observation

nonisolated enum LedgerTransactionAction: String, Identifiable, Sendable {
  case refund
  case reverse
  case correct

  var id: Self { self }
}

@MainActor
@Observable
final class LedgerTransactionDetailViewModel {
  private let ownerID: UUID
  private let rootID: UUID
  private let ledgerQuery: LedgerQueryService
  private let refundTransaction: RefundTransactionUseCase
  private let reverseTransaction: ReverseTransactionUseCase
  private let correctTransaction: CorrectTransactionUseCase
  private let lifeLinks: LifeLinkService?
  private let now: @Sendable () -> Date
  private let timeZoneIdentifier: @Sendable () -> String

  private var pendingRefundID = UUID()
  private var pendingReversalID = UUID()
  private var pendingCorrectionGroupID = UUID()
  private var pendingCorrectionReversalID = UUID()
  private var pendingCorrectionReplacementID = UUID()
  private var preparedCurrentTransactionID: UUID?

  var snapshot: LedgerTransactionRootSnapshot?
  var accountSummaries: [LedgerAccountSummary] = []
  var linkedJourneys: [TransactionLinkedJourney] = []
  var presentedAction: LedgerTransactionAction?
  var isLoading = false
  var isSaving = false
  var errorMessage: LocalizedStringResource?
  var successMessage: LocalizedStringResource?

  var refundAmountText = ""
  var refundDestinationAccountID: UUID?
  var refundOccurredAt: Date
  var refundNote = ""

  var reversalReason = ""
  var reversalOccurredAt: Date

  var correctionAmountText = ""
  var correctionOccurredAt: Date
  var correctionPayee = ""
  var correctionNote = ""
  var correctionSourceAccountID: UUID?
  var correctionSecondaryAccountID: UUID?

  convenience init(
    rootID: UUID,
    environment: AppEnvironment,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
  ) {
    self.init(
      rootID: rootID,
      ownerID: environment.localLedgerIdentity.profileID,
      ledgerQuery: environment.ledgerQuery,
      refundTransaction: environment.refundTransaction,
      reverseTransaction: environment.reverseTransaction,
      correctTransaction: environment.correctTransaction,
      lifeLinks: environment.lifeLinks,
      now: now,
      timeZoneIdentifier: timeZoneIdentifier
    )
  }

  init(
    rootID: UUID,
    ownerID: UUID,
    ledgerQuery: LedgerQueryService,
    refundTransaction: RefundTransactionUseCase,
    reverseTransaction: ReverseTransactionUseCase,
    correctTransaction: CorrectTransactionUseCase,
    lifeLinks: LifeLinkService? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
  ) {
    self.ownerID = ownerID
    self.rootID = rootID
    self.ledgerQuery = ledgerQuery
    self.refundTransaction = refundTransaction
    self.reverseTransaction = reverseTransaction
    self.correctTransaction = correctTransaction
    self.lifeLinks = lifeLinks
    self.now = now
    self.timeZoneIdentifier = timeZoneIdentifier
    let initialDate = now()
    refundOccurredAt = initialDate
    reversalOccurredAt = initialDate
    correctionOccurredAt = initialDate
  }

  var currentTransaction: PostedLedgerTransaction? {
    snapshot?.currentTransaction
  }

  var currentMoney: PositiveMoney? {
    currentTransaction?.postings.first?.money
  }

  var canRefund: Bool {
    guard let snapshot else { return false }
    return snapshot.currentTransaction.kind == .expense
      && !snapshot.isCurrentReversed
      && (snapshot.availableRefundMinorUnits ?? 0) > 0
  }

  var canReverse: Bool {
    guard let snapshot else { return false }
    return !snapshot.isCurrentReversed && snapshot.activeRefundMinorUnits == 0
  }

  var canCorrect: Bool {
    guard let snapshot else { return false }
    return !snapshot.isCurrentReversed
      && [.expense, .income, .transfer].contains(snapshot.currentTransaction.kind)
  }

  var activeFundingAccounts: [LedgerAccountSummary] {
    accountSummaries.filter {
      $0.account.status == .active
        && ($0.account.kind == .asset || $0.account.kind == .liability)
    }
  }

  var refundDestinationOptions: [LedgerAccountSummary] {
    activeFundingAccounts
  }

  var correctionSourceOptions: [LedgerAccountSummary] {
    guard let kind = currentTransaction?.kind else { return [] }
    switch kind {
    case .income:
      return accountSummaries.filter {
        $0.account.status == .active && $0.account.kind == .asset
      }
    case .expense, .transfer:
      return activeFundingAccounts
    case .refund, .reversal, .opening, .adjustment:
      return []
    }
  }

  var correctionSecondaryOptions: [LedgerAccountSummary] {
    guard let kind = currentTransaction?.kind else { return [] }
    switch kind {
    case .expense:
      return activeAccounts(kind: .expense)
    case .income:
      return activeAccounts(kind: .income)
    case .transfer:
      return activeFundingAccounts.filter { $0.id != correctionSourceAccountID }
    case .refund, .reversal, .opening, .adjustment:
      return []
    }
  }

  var sortedHistory: [PostedLedgerTransaction] {
    (snapshot?.transactions ?? []).sorted {
      if $0.postedAt == $1.postedAt {
        return $0.id.uuidString > $1.id.uuidString
      }
      return $0.postedAt > $1.postedAt
    }
  }

  func load() async {
    await reload(preserveDrafts: false)
  }

  func accountName(for accountID: UUID) -> String {
    accountSummaries.first(where: { $0.id == accountID })?.account.name ?? "未知账户"
  }

  func postingRole(_ posting: LedgerPosting) -> LocalizedStringResource {
    guard let kind = currentTransaction?.kind else { return "账户" }
    return switch (kind, posting.side) {
    case (.expense, .debit):
      "分类"
    case (.expense, .credit):
      "付款账户"
    case (.income, .debit):
      "收款账户"
    case (.income, .credit):
      "分类"
    case (.transfer, .debit):
      "转入账户"
    case (.transfer, .credit):
      "转出账户"
    default:
      "账户"
    }
  }

  func selectAction(_ action: LedgerTransactionAction) {
    errorMessage = nil
    successMessage = nil
    presentedAction = action
  }

  func reconcileCorrectionSelections() {
    correctionSourceAccountID = validSelection(
      correctionSourceAccountID,
      in: correctionSourceOptions
    )
    correctionSecondaryAccountID = validSelection(
      correctionSecondaryAccountID,
      in: correctionSecondaryOptions
    )
  }

  func saveRefund() async -> Bool {
    guard !isSaving, let snapshot else { return false }
    guard let destinationAccountID = refundDestinationAccountID,
      let currencyCode = currentMoney?.currencyCode
    else {
      errorMessage = "请选择退款到账账户。"
      return false
    }

    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      let money = try LedgerAmountText.parsePositiveMoney(
        refundAmountText,
        currencyCode: currencyCode
      )
      _ = try await refundTransaction.execute(
        RefundLedgerTransactionRequest(
          transactionID: pendingRefundID,
          ownerID: ownerID,
          rootID: snapshot.rootID,
          currentTransactionID: snapshot.currentTransaction.id,
          expectedRootRevision: snapshot.rootRevision,
          destinationAccountID: destinationAccountID,
          money: money,
          occurredAt: refundOccurredAt,
          originalTimeZoneIdentifier: timeZoneIdentifier(),
          note: refundNote,
          submittedAt: now()
        )
      )
      pendingRefundID = UUID()
      await reload(preserveDrafts: false)
      successMessage = "退款已记录。"
      return true
    } catch {
      await handleActionError(error)
      return false
    }
  }

  func saveReversal() async -> Bool {
    guard !isSaving, let snapshot else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      _ = try await reverseTransaction.execute(
        ReverseLedgerTransactionRequest(
          transactionID: pendingReversalID,
          ownerID: ownerID,
          rootID: snapshot.rootID,
          targetTransactionID: snapshot.currentTransaction.id,
          expectedRootRevision: snapshot.rootRevision,
          reason: reversalReason,
          occurredAt: reversalOccurredAt,
          originalTimeZoneIdentifier: timeZoneIdentifier(),
          submittedAt: now()
        )
      )
      pendingReversalID = UUID()
      await reload(preserveDrafts: false)
      successMessage = "交易已撤销。"
      return true
    } catch {
      await handleActionError(error)
      return false
    }
  }

  func saveCorrection() async -> Bool {
    guard !isSaving, let snapshot else { return false }
    guard let details = correctionDetails(), let currencyCode = currentMoney?.currencyCode else {
      errorMessage = "请选择可用的账户和分类。"
      return false
    }

    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      let money = try LedgerAmountText.parsePositiveMoney(
        correctionAmountText,
        currencyCode: currencyCode
      )
      _ = try await correctTransaction.execute(
        CorrectLedgerTransactionRequest(
          correctionGroupID: pendingCorrectionGroupID,
          reversalTransactionID: pendingCorrectionReversalID,
          replacementTransactionID: pendingCorrectionReplacementID,
          ownerID: ownerID,
          rootID: snapshot.rootID,
          currentTransactionID: snapshot.currentTransaction.id,
          expectedRootRevision: snapshot.rootRevision,
          replacementDetails: details,
          replacementMoney: money,
          replacementOccurredAt: correctionOccurredAt,
          originalTimeZoneIdentifier: timeZoneIdentifier(),
          payee: correctionPayee,
          note: correctionNote,
          submittedAt: now()
        )
      )
      resetCorrectionCommandIdentifiers()
      await reload(preserveDrafts: false)
      successMessage = "交易已更正，历史记录已保留。"
      return true
    } catch {
      await handleActionError(error)
      return false
    }
  }

  private func reload(preserveDrafts: Bool) async {
    guard !isLoading else { return }
    isLoading = true
    if !preserveDrafts {
      errorMessage = nil
    }
    defer { isLoading = false }

    do {
      async let loadedSnapshot = ledgerQuery.transactionRoot(ownerID: ownerID, rootID: rootID)
      async let loadedAccounts = ledgerQuery.accountSummaries(ownerID: ownerID)
      let (newSnapshot, newAccounts) = try await (loadedSnapshot, loadedAccounts)
      snapshot = newSnapshot
      accountSummaries = newAccounts
      if !preserveDrafts || preparedCurrentTransactionID != newSnapshot.currentTransaction.id {
        prepareDrafts(from: newSnapshot)
      }
      if let lifeLinks {
        linkedJourneys = (try? await lifeLinks.journeys(rootID: rootID)) ?? linkedJourneys
      }
    } catch {
      errorMessage = "无法读取交易详情，请稍后重试。"
    }
  }

  private func prepareDrafts(from snapshot: LedgerTransactionRootSnapshot) {
    let current = snapshot.currentTransaction
    preparedCurrentTransactionID = current.id
    if let money = current.postings.first?.money {
      correctionAmountText = Self.editableAmount(money)
    }
    correctionOccurredAt = current.occurredAt
    correctionPayee = current.payee ?? ""
    correctionNote = current.note ?? ""
    refundAmountText = ""
    refundOccurredAt = now()
    refundNote = ""
    reversalReason = ""
    reversalOccurredAt = now()

    let accountByID = Dictionary(uniqueKeysWithValues: accountSummaries.map { ($0.id, $0.account) })
    switch current.kind {
    case .expense:
      correctionSourceAccountID =
        current.postings.first {
          $0.side == .credit
            && accountByID[$0.accountID].map {
              [.asset, .liability].contains($0.kind)
            } == true
        }?.accountID
      correctionSecondaryAccountID =
        current.postings.first {
          $0.side == .debit && accountByID[$0.accountID]?.kind == .expense
        }?.accountID
      refundDestinationAccountID = validSelection(
        correctionSourceAccountID,
        in: refundDestinationOptions
      )
    case .income:
      correctionSourceAccountID =
        current.postings.first {
          $0.side == .debit && accountByID[$0.accountID]?.kind == .asset
        }?.accountID
      correctionSecondaryAccountID =
        current.postings.first {
          $0.side == .credit && accountByID[$0.accountID]?.kind == .income
        }?.accountID
      refundDestinationAccountID = nil
    case .transfer:
      correctionSourceAccountID =
        current.postings.first {
          $0.side == .credit
            && accountByID[$0.accountID].map {
              [.asset, .liability].contains($0.kind)
            } == true
        }?.accountID
      correctionSecondaryAccountID =
        current.postings.first {
          $0.side == .debit
            && accountByID[$0.accountID].map {
              [.asset, .liability].contains($0.kind)
            } == true
        }?.accountID
      refundDestinationAccountID = nil
    case .refund, .reversal, .opening, .adjustment:
      correctionSourceAccountID = nil
      correctionSecondaryAccountID = nil
      refundDestinationAccountID = nil
    }
    reconcileCorrectionSelections()
  }

  private func correctionDetails() -> ManualLedgerTransactionDetails? {
    guard let sourceID = correctionSourceAccountID,
      let secondaryID = correctionSecondaryAccountID,
      let kind = currentTransaction?.kind
    else {
      return nil
    }
    switch kind {
    case .expense:
      return .expense(paymentAccountID: sourceID, categoryAccountID: secondaryID)
    case .income:
      return .income(receivingAccountID: sourceID, categoryAccountID: secondaryID)
    case .transfer:
      return .transfer(sourceAccountID: sourceID, destinationAccountID: secondaryID)
    case .refund, .reversal, .opening, .adjustment:
      return nil
    }
  }

  private func activeAccounts(kind: LedgerAccountKind) -> [LedgerAccountSummary] {
    accountSummaries.filter {
      $0.account.status == .active && $0.account.kind == kind
    }
  }

  private func validSelection(
    _ selection: UUID?,
    in options: [LedgerAccountSummary]
  ) -> UUID? {
    if let selection, options.contains(where: { $0.id == selection }) {
      return selection
    }
    return options.first?.id
  }

  private func handleActionError(_ error: Error) async {
    if case LedgerError.rootRevisionConflict = error {
      await reload(preserveDrafts: true)
      errorMessage = "交易已发生变化，输入已保留。请检查最新详情后再次确认。"
      return
    }
    errorMessage = Self.userMessage(for: error)
  }

  private func resetCorrectionCommandIdentifiers() {
    pendingCorrectionGroupID = UUID()
    pendingCorrectionReversalID = UUID()
    pendingCorrectionReplacementID = UUID()
  }

  private static func editableAmount(_ money: PositiveMoney) -> String {
    let currencyFormatter = NumberFormatter()
    currencyFormatter.numberStyle = .currency
    currencyFormatter.currencyCode = money.currencyCode.rawValue
    let fractionDigits = max(0, currencyFormatter.maximumFractionDigits)
    let formatter = NumberFormatter()
    formatter.locale = .current
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    var scale = Decimal(1)
    for _ in 0..<fractionDigits {
      scale *= 10
    }
    let value = Decimal(money.minorUnits) / scale
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? ""
  }

  private static func userMessage(for error: Error) -> LocalizedStringResource {
    switch error {
    case LedgerAmountText.ParsingError.empty:
      "请输入金额。"
    case LedgerAmountText.ParsingError.invalidCharacters,
      PositiveMoney.ValidationError.amountMustBePositive:
      "请输入大于零的有效金额。"
    case LedgerAmountText.ParsingError.tooManyFractionDigits:
      "金额的小数位数超过当前币种允许的范围。"
    case LedgerAmountText.ParsingError.outOfRange:
      "金额过大，请输入较小的金额。"
    case LedgerError.refundAmountExceedsAvailable:
      "退款金额超过当前可退金额。"
    case LedgerError.activeRefundsPreventReversal:
      "这笔支出仍有有效退款，请先撤销退款记录后再整笔撤销。"
    case LedgerError.correctionAmountBelowActiveRefunds:
      "更正后的支出金额不能小于已记录的有效退款。"
    case LedgerError.invalidReversalReason:
      "请输入 1 至 200 个字符的撤销原因。"
    case LedgerError.accountArchived, LedgerError.accountNotFound:
      "所选账户或分类已不可用，请重新选择。"
    case LedgerError.transactionAlreadyReversed:
      "这笔交易已经撤销。"
    case LedgerError.transactionNotCurrent:
      "这不是当前有效版本，请刷新后重试。"
    default:
      "操作失败，输入内容仍然保留，请稍后重试。"
    }
  }
}
