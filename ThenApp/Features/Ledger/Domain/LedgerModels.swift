import Foundation

nonisolated enum BaseCurrencyState: String, Codable, Sendable {
  case suggested
  case confirmed
}

nonisolated struct LocalLedgerProfile: Equatable, Sendable {
  let id: UUID
  let baseCurrencyCode: CurrencyCode
  let baseCurrencyState: BaseCurrencyState
}

nonisolated enum LedgerAccountKind: String, Codable, Hashable, Sendable {
  case asset
  case liability
  case income
  case expense
  case equity
}

nonisolated enum LedgerAccountSubtype: String, Codable, Hashable, Sendable {
  case openingBalance = "opening_balance"
  case uncategorized
  case cash
  case bank
  case electronicWallet = "electronic_wallet"
  case creditCard = "credit_card"
  case food
  case transport
  case shopping
  case housing
  case otherExpense = "other_expense"
  case salary
  case otherIncome = "other_income"
  case custom
}

nonisolated enum LedgerAccountConfigurationState: String, Codable, Sendable {
  case pendingCurrencyConfirmation = "pending_currency_confirmation"
  case ready
}

nonisolated enum LedgerAccountStatus: String, Codable, Sendable {
  case active
  case archived
}

nonisolated struct LedgerAccount: Equatable, Sendable {
  let id: UUID
  let ownerID: UUID
  let parentID: UUID?
  let kind: LedgerAccountKind
  let subtype: LedgerAccountSubtype
  let name: String
  let nativeCurrencyCode: CurrencyCode
  let configurationState: LedgerAccountConfigurationState
  let systemKey: String?
  let status: LedgerAccountStatus
  let displayOrder: Int
}

nonisolated struct SignedMoney: Equatable, Sendable {
  let minorUnits: Int64
  let currencyCode: CurrencyCode
}

nonisolated struct LedgerAccountSummary: Identifiable, Equatable, Sendable {
  let account: LedgerAccount
  let balance: SignedMoney

  var id: UUID { account.id }
}

nonisolated enum LedgerAccountCreationType: String, CaseIterable, Codable, Hashable, Sendable {
  case cash
  case bank
  case electronicWallet = "electronic_wallet"
  case creditCard = "credit_card"
  case expenseCategory = "expense_category"
  case incomeCategory = "income_category"

  var kind: LedgerAccountKind {
    switch self {
    case .cash, .bank, .electronicWallet:
      .asset
    case .creditCard:
      .liability
    case .expenseCategory:
      .expense
    case .incomeCategory:
      .income
    }
  }

  var subtype: LedgerAccountSubtype {
    switch self {
    case .cash:
      .cash
    case .bank:
      .bank
    case .electronicWallet:
      .electronicWallet
    case .creditCard:
      .creditCard
    case .expenseCategory, .incomeCategory:
      .custom
    }
  }

  var supportsParent: Bool {
    switch self {
    case .expenseCategory, .incomeCategory:
      true
    case .cash, .bank, .electronicWallet, .creditCard:
      false
    }
  }
}

nonisolated struct CreateLedgerAccountRequest: Equatable, Sendable {
  let accountID: UUID
  let ownerID: UUID
  let creationType: LedgerAccountCreationType
  let name: String
  let parentID: UUID?
  let submittedAt: Date

  init(
    accountID: UUID,
    ownerID: UUID,
    creationType: LedgerAccountCreationType,
    name: String,
    parentID: UUID? = nil,
    submittedAt: Date
  ) throws {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(normalizedName.count) else {
      throw LedgerError.invalidAccountName
    }
    guard creationType.supportsParent || parentID == nil else {
      throw LedgerError.financialAccountCannotHaveParent
    }
    guard submittedAt.timeIntervalSince1970 >= 0 else {
      throw LedgerError.invalidSubmissionTime
    }

    self.accountID = accountID
    self.ownerID = ownerID
    self.creationType = creationType
    self.name = normalizedName
    self.parentID = parentID
    self.submittedAt = submittedAt
  }
}

nonisolated struct SetLedgerAccountStatusRequest: Equatable, Sendable {
  let ownerID: UUID
  let accountID: UUID
  let status: LedgerAccountStatus
  let changedAt: Date

  init(
    ownerID: UUID,
    accountID: UUID,
    status: LedgerAccountStatus,
    changedAt: Date
  ) throws {
    guard changedAt.timeIntervalSince1970 >= 0 else {
      throw LedgerError.invalidSubmissionTime
    }
    self.ownerID = ownerID
    self.accountID = accountID
    self.status = status
    self.changedAt = changedAt
  }
}

nonisolated enum LedgerTransactionKind: String, Codable, Sendable {
  case expense
  case income
  case transfer
  case refund
  case reversal
  case opening
  case adjustment
}

nonisolated enum LedgerTransactionSource: String, Codable, Sendable {
  case manual
  case ocr
  case systemSuggestion = "system_suggestion"
}

nonisolated enum LedgerPostingSide: String, Codable, Sendable {
  case debit
  case credit
}

nonisolated struct LedgerPosting: Equatable, Sendable {
  let id: UUID
  let transactionID: UUID
  let accountID: UUID
  let side: LedgerPostingSide
  let money: PositiveMoney
  let sequence: Int
}

nonisolated struct PostedLedgerTransaction: Equatable, Sendable {
  let id: UUID
  let ownerID: UUID
  let kind: LedgerTransactionKind
  let canonicalRootID: UUID
  let localRootRevision: Int
  let occurredAt: Date
  let originalTimeZoneIdentifier: String
  let localDate: String
  let payee: String?
  let note: String?
  let source: LedgerTransactionSource
  let postedAt: Date
  let refundOfID: UUID?
  let reversalOfID: UUID?
  let replacementForID: UUID?
  let correctionGroupID: UUID?
  let postings: [LedgerPosting]
}

nonisolated struct CorrectedLedgerTransaction: Equatable, Sendable {
  let reversal: PostedLedgerTransaction
  let replacement: PostedLedgerTransaction
  let rootRevision: Int
}

nonisolated struct LedgerTransactionRootSnapshot: Equatable, Sendable {
  let rootID: UUID
  let rootRevision: Int
  let currentTransaction: PostedLedgerTransaction
  let activeRefundMinorUnits: Int64
  let availableRefundMinorUnits: Int64?
  let isCurrentReversed: Bool
  let transactions: [PostedLedgerTransaction]
}

nonisolated struct LedgerTransactionSummary: Identifiable, Equatable, Sendable {
  let rootID: UUID
  let currentTransactionID: UUID
  let rootRevision: Int
  let kind: LedgerTransactionKind
  let occurredAt: Date
  let localDate: String
  let payee: String?
  let money: PositiveMoney
  let isReversed: Bool
  let activeRefundMinorUnits: Int64

  var id: UUID { rootID }
}

nonisolated enum LedgerJourneyLinkFilter: String, CaseIterable, Equatable, Sendable {
  case any
  case linked
  case unlinked
}

nonisolated struct LedgerTransactionFilter: Equatable, Sendable {
  let searchText: String
  let amountMinorUnits: Int64?
  let fundingAccountID: UUID?
  let categoryAccountID: UUID?
  let journeyLink: LedgerJourneyLinkFilter

  init(
    searchText: String = "",
    amountMinorUnits: Int64? = nil,
    fundingAccountID: UUID? = nil,
    categoryAccountID: UUID? = nil,
    journeyLink: LedgerJourneyLinkFilter = .any
  ) {
    self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    self.amountMinorUnits = amountMinorUnits
    self.fundingAccountID = fundingAccountID
    self.categoryAccountID = categoryAccountID
    self.journeyLink = journeyLink
  }

  var isActive: Bool {
    !searchText.isEmpty || fundingAccountID != nil || categoryAccountID != nil
      || journeyLink != .any
  }
}

nonisolated struct LedgerMonth: Equatable, Sendable {
  let year: Int
  let month: Int
  let startLocalDate: String
  let endExclusiveLocalDate: String

  init(containing date: Date, timeZoneIdentifier: String) throws {
    guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
      throw LedgerError.invalidTimeZoneIdentifier
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month], from: date)
    guard let year = components.year, let month = components.month,
      let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
      let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
    else {
      throw LedgerError.invalidSubmissionTime
    }
    self.year = year
    self.month = month
    startLocalDate = Self.localDate(monthStart, calendar: calendar)
    endExclusiveLocalDate = Self.localDate(nextMonthStart, calendar: calendar)
  }

  init(year: Int, month: Int) throws {
    guard year >= 1, year <= 9999, month >= 1, month <= 12,
      year < 9999 || month < 12
    else {
      throw LedgerError.invalidSubmissionTime
    }
    self.year = year
    self.month = month
    startLocalDate = String(format: "%04d-%02d-01", year, month)
    let nextYear = month == 12 ? year + 1 : year
    let nextMonth = month == 12 ? 1 : month + 1
    endExclusiveLocalDate = String(format: "%04d-%02d-01", nextYear, nextMonth)
  }

  var key: String {
    String(format: "%04d-%02d", year, month)
  }

  func addingMonths(_ offset: Int) throws -> LedgerMonth {
    let zeroBasedMonth = month - 1
    let (yearProduct, yearOverflow) = year.multipliedReportingOverflow(by: 12)
    let (base, baseOverflow) = yearProduct.addingReportingOverflow(zeroBasedMonth)
    let (shifted, shiftedOverflow) = base.addingReportingOverflow(offset)
    guard !yearOverflow, !baseOverflow, !shiftedOverflow, shifted >= 12 else {
      throw LedgerError.invalidSubmissionTime
    }
    return try LedgerMonth(
      year: shifted / 12,
      month: (shifted % 12) + 1
    )
  }

  private static func localDate(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}

nonisolated struct LedgerCategoryTotal: Identifiable, Equatable, Sendable {
  let accountID: UUID
  let name: String
  let total: SignedMoney

  var id: UUID { accountID }
}

nonisolated struct LedgerMonthlyExpenseTotal: Identifiable, Equatable, Sendable {
  let month: LedgerMonth
  let expense: SignedMoney

  var id: String { month.key }
}

nonisolated struct LedgerMonthlyReport: Equatable, Sendable {
  let month: LedgerMonth
  let income: SignedMoney
  let expense: SignedMoney
  let netChange: SignedMoney
  let expenseCategories: [LedgerCategoryTotal]
  let expenseTrend: [LedgerMonthlyExpenseTotal]
}

nonisolated enum ManualLedgerTransactionDetails: Equatable, Sendable {
  case expense(paymentAccountID: UUID, categoryAccountID: UUID)
  case income(receivingAccountID: UUID, categoryAccountID: UUID)
  case transfer(sourceAccountID: UUID, destinationAccountID: UUID)

  var kind: LedgerTransactionKind {
    switch self {
    case .expense:
      .expense
    case .income:
      .income
    case .transfer:
      .transfer
    }
  }

  var accountIDs: [UUID] {
    switch self {
    case .expense(let paymentAccountID, let categoryAccountID):
      [paymentAccountID, categoryAccountID]
    case .income(let receivingAccountID, let categoryAccountID):
      [receivingAccountID, categoryAccountID]
    case .transfer(let sourceAccountID, let destinationAccountID):
      [sourceAccountID, destinationAccountID]
    }
  }
}

nonisolated struct CreateLedgerTransactionRequest: Equatable, Sendable {
  let transactionID: UUID
  let ownerID: UUID
  let details: ManualLedgerTransactionDetails
  let money: PositiveMoney
  let occurredAt: Date
  let originalTimeZoneIdentifier: String
  let payee: String?
  let note: String?
  let source: LedgerTransactionSource
  let submittedAt: Date

  init(
    transactionID: UUID,
    ownerID: UUID,
    details: ManualLedgerTransactionDetails,
    money: PositiveMoney,
    occurredAt: Date,
    originalTimeZoneIdentifier: String,
    payee: String? = nil,
    note: String? = nil,
    source: LedgerTransactionSource = .manual,
    submittedAt: Date
  ) throws {
    guard TimeZone(identifier: originalTimeZoneIdentifier) != nil else {
      throw LedgerError.invalidTimeZoneIdentifier
    }
    guard submittedAt.timeIntervalSince1970 >= 0 else {
      throw LedgerError.invalidSubmissionTime
    }

    self.transactionID = transactionID
    self.ownerID = ownerID
    self.details = details
    self.money = money
    self.occurredAt = occurredAt
    self.originalTimeZoneIdentifier = originalTimeZoneIdentifier
    self.payee = Self.normalizedOptionalText(payee)
    self.note = Self.normalizedOptionalText(note)
    self.source = source
    self.submittedAt = submittedAt
  }

  var localDate: String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: originalTimeZoneIdentifier) ?? .gmt
    let components = calendar.dateComponents([.year, .month, .day], from: occurredAt)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  private static func normalizedOptionalText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}

nonisolated struct RefundLedgerTransactionRequest: Equatable, Sendable {
  let transactionID: UUID
  let ownerID: UUID
  let rootID: UUID
  let currentTransactionID: UUID
  let expectedRootRevision: Int
  let destinationAccountID: UUID
  let money: PositiveMoney
  let occurredAt: Date
  let originalTimeZoneIdentifier: String
  let note: String?
  let submittedAt: Date

  init(
    transactionID: UUID,
    ownerID: UUID,
    rootID: UUID,
    currentTransactionID: UUID,
    expectedRootRevision: Int,
    destinationAccountID: UUID,
    money: PositiveMoney,
    occurredAt: Date,
    originalTimeZoneIdentifier: String,
    note: String? = nil,
    submittedAt: Date
  ) throws {
    guard transactionID != rootID, transactionID != currentTransactionID else {
      throw LedgerError.duplicateTransactionIdentifier
    }
    try Self.validateCommandContext(
      expectedRootRevision: expectedRootRevision,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      submittedAt: submittedAt
    )
    self.transactionID = transactionID
    self.ownerID = ownerID
    self.rootID = rootID
    self.currentTransactionID = currentTransactionID
    self.expectedRootRevision = expectedRootRevision
    self.destinationAccountID = destinationAccountID
    self.money = money
    self.occurredAt = occurredAt
    self.originalTimeZoneIdentifier = originalTimeZoneIdentifier
    self.note = Self.normalizedOptionalText(note)
    self.submittedAt = submittedAt
  }

  var localDate: String {
    Self.localDate(for: occurredAt, timeZoneIdentifier: originalTimeZoneIdentifier)
  }
}

nonisolated struct ReverseLedgerTransactionRequest: Equatable, Sendable {
  let transactionID: UUID
  let ownerID: UUID
  let rootID: UUID
  let targetTransactionID: UUID
  let expectedRootRevision: Int
  let reason: String
  let occurredAt: Date
  let originalTimeZoneIdentifier: String
  let submittedAt: Date

  init(
    transactionID: UUID,
    ownerID: UUID,
    rootID: UUID,
    targetTransactionID: UUID,
    expectedRootRevision: Int,
    reason: String,
    occurredAt: Date,
    originalTimeZoneIdentifier: String,
    submittedAt: Date
  ) throws {
    guard transactionID != rootID, transactionID != targetTransactionID else {
      throw LedgerError.duplicateTransactionIdentifier
    }
    let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...200).contains(normalizedReason.count) else {
      throw LedgerError.invalidReversalReason
    }
    try Self.validateCommandContext(
      expectedRootRevision: expectedRootRevision,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      submittedAt: submittedAt
    )
    self.transactionID = transactionID
    self.ownerID = ownerID
    self.rootID = rootID
    self.targetTransactionID = targetTransactionID
    self.expectedRootRevision = expectedRootRevision
    self.reason = normalizedReason
    self.occurredAt = occurredAt
    self.originalTimeZoneIdentifier = originalTimeZoneIdentifier
    self.submittedAt = submittedAt
  }

  var localDate: String {
    Self.localDate(for: occurredAt, timeZoneIdentifier: originalTimeZoneIdentifier)
  }
}

nonisolated struct CorrectLedgerTransactionRequest: Equatable, Sendable {
  let correctionGroupID: UUID
  let reversalTransactionID: UUID
  let replacementTransactionID: UUID
  let ownerID: UUID
  let rootID: UUID
  let currentTransactionID: UUID
  let expectedRootRevision: Int
  let replacementDetails: ManualLedgerTransactionDetails
  let replacementMoney: PositiveMoney
  let replacementOccurredAt: Date
  let originalTimeZoneIdentifier: String
  let payee: String?
  let note: String?
  let submittedAt: Date

  init(
    correctionGroupID: UUID,
    reversalTransactionID: UUID,
    replacementTransactionID: UUID,
    ownerID: UUID,
    rootID: UUID,
    currentTransactionID: UUID,
    expectedRootRevision: Int,
    replacementDetails: ManualLedgerTransactionDetails,
    replacementMoney: PositiveMoney,
    replacementOccurredAt: Date,
    originalTimeZoneIdentifier: String,
    payee: String? = nil,
    note: String? = nil,
    submittedAt: Date
  ) throws {
    let commandIDs = [
      correctionGroupID,
      reversalTransactionID,
      replacementTransactionID,
    ]
    guard Set(commandIDs).count == commandIDs.count,
      !commandIDs.contains(rootID),
      !commandIDs.contains(currentTransactionID)
    else {
      throw LedgerError.duplicateCorrectionIdentifier
    }
    try Self.validateCommandContext(
      expectedRootRevision: expectedRootRevision,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      submittedAt: submittedAt
    )
    self.correctionGroupID = correctionGroupID
    self.reversalTransactionID = reversalTransactionID
    self.replacementTransactionID = replacementTransactionID
    self.ownerID = ownerID
    self.rootID = rootID
    self.currentTransactionID = currentTransactionID
    self.expectedRootRevision = expectedRootRevision
    self.replacementDetails = replacementDetails
    self.replacementMoney = replacementMoney
    self.replacementOccurredAt = replacementOccurredAt
    self.originalTimeZoneIdentifier = originalTimeZoneIdentifier
    self.payee = Self.normalizedOptionalText(payee)
    self.note = Self.normalizedOptionalText(note)
    self.submittedAt = submittedAt
  }

  var replacementLocalDate: String {
    Self.localDate(
      for: replacementOccurredAt,
      timeZoneIdentifier: originalTimeZoneIdentifier
    )
  }
}

nonisolated struct BaseCurrencyConfirmation: Equatable, Sendable {
  let ownerID: UUID
  let currencyCode: CurrencyCode
  let confirmedAt: Date
}

nonisolated enum LedgerError: Error, Equatable, Sendable {
  case localProfileNotFound
  case inconsistentLocalProfile
  case baseCurrencyNotConfirmed
  case baseCurrencyAlreadyConfirmed
  case postedTransactionsExistBeforeCurrencyConfirmation
  case accountNotFound(UUID)
  case invalidAccountName
  case financialAccountCannotHaveParent
  case categoryParentKindMismatch
  case categoryHierarchyTooDeep
  case duplicateAccountIdentifier
  case internalAccountProtected
  case accountHasActiveChildren
  case accountArchived(UUID)
  case accountNotReady(UUID)
  case invalidAccountKind(UUID)
  case accountCurrencyMismatch(UUID)
  case transferAccountsMustDiffer
  case transactionNotFound(UUID)
  case duplicateTransactionIdentifier
  case duplicateCorrectionIdentifier
  case canonicalRootNotFound(UUID)
  case inconsistentCanonicalRoot
  case rootRevisionConflict(expected: Int, actual: Int)
  case transactionNotCurrent(UUID)
  case transactionAlreadyReversed(UUID)
  case transactionNotRefundable(UUID)
  case refundAmountExceedsAvailable
  case activeRefundsPreventReversal
  case correctionAmountBelowActiveRefunds
  case correctionKindCannotChange
  case reversalCannotBeReversed
  case invalidReversalReason
  case invalidTimeZoneIdentifier
  case invalidSubmissionTime
  case corruptedStoredLedger
  case unbalancedPostings
}

extension RefundLedgerTransactionRequest {
  nonisolated fileprivate static func validateCommandContext(
    expectedRootRevision: Int,
    originalTimeZoneIdentifier: String,
    submittedAt: Date
  ) throws {
    guard expectedRootRevision >= 1 else {
      throw LedgerError.inconsistentCanonicalRoot
    }
    guard TimeZone(identifier: originalTimeZoneIdentifier) != nil else {
      throw LedgerError.invalidTimeZoneIdentifier
    }
    guard submittedAt.timeIntervalSince1970 >= 0 else {
      throw LedgerError.invalidSubmissionTime
    }
  }

  nonisolated fileprivate static func normalizedOptionalText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  nonisolated fileprivate static func localDate(
    for date: Date,
    timeZoneIdentifier: String
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}

extension ReverseLedgerTransactionRequest {
  nonisolated fileprivate static func validateCommandContext(
    expectedRootRevision: Int,
    originalTimeZoneIdentifier: String,
    submittedAt: Date
  ) throws {
    try RefundLedgerTransactionRequest.validateCommandContext(
      expectedRootRevision: expectedRootRevision,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      submittedAt: submittedAt
    )
  }

  nonisolated fileprivate static func localDate(
    for date: Date,
    timeZoneIdentifier: String
  ) -> String {
    RefundLedgerTransactionRequest.localDate(
      for: date,
      timeZoneIdentifier: timeZoneIdentifier
    )
  }
}

extension CorrectLedgerTransactionRequest {
  nonisolated fileprivate static func validateCommandContext(
    expectedRootRevision: Int,
    originalTimeZoneIdentifier: String,
    submittedAt: Date
  ) throws {
    try RefundLedgerTransactionRequest.validateCommandContext(
      expectedRootRevision: expectedRootRevision,
      originalTimeZoneIdentifier: originalTimeZoneIdentifier,
      submittedAt: submittedAt
    )
  }

  nonisolated fileprivate static func normalizedOptionalText(_ value: String?) -> String? {
    RefundLedgerTransactionRequest.normalizedOptionalText(value)
  }

  nonisolated fileprivate static func localDate(
    for date: Date,
    timeZoneIdentifier: String
  ) -> String {
    RefundLedgerTransactionRequest.localDate(
      for: date,
      timeZoneIdentifier: timeZoneIdentifier
    )
  }
}
