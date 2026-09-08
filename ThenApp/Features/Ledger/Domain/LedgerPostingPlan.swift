import Foundation

nonisolated struct LedgerPostingBlueprint: Equatable, Sendable {
  let accountID: UUID
  let side: LedgerPostingSide
  let money: PositiveMoney
  let sequence: Int
}

nonisolated struct LedgerPostingPlan: Equatable, Sendable {
  let kind: LedgerTransactionKind
  let postings: [LedgerPostingBlueprint]

  static func make(
    request: CreateLedgerTransactionRequest,
    profile: LocalLedgerProfile,
    accounts: [LedgerAccount]
  ) throws -> LedgerPostingPlan {
    if case .transfer(let sourceAccountID, let destinationAccountID) = request.details,
      sourceAccountID == destinationAccountID
    {
      throw LedgerError.transferAccountsMustDiffer
    }
    guard profile.id == request.ownerID else {
      throw LedgerError.inconsistentLocalProfile
    }
    guard profile.baseCurrencyState == .confirmed else {
      throw LedgerError.baseCurrencyNotConfirmed
    }
    guard profile.baseCurrencyCode == request.money.currencyCode else {
      throw LedgerError.accountCurrencyMismatch(request.details.accountIDs[0])
    }

    var accountsByID: [UUID: LedgerAccount] = [:]
    for account in accounts {
      accountsByID[account.id] = account
    }
    let requiredAccounts = try request.details.accountIDs.map { accountID in
      guard let account = accountsByID[accountID] else {
        throw LedgerError.accountNotFound(accountID)
      }
      guard account.ownerID == request.ownerID else {
        throw LedgerError.accountNotFound(accountID)
      }
      guard account.status == .active else {
        throw LedgerError.accountArchived(accountID)
      }
      guard account.configurationState == .ready else {
        throw LedgerError.accountNotReady(accountID)
      }
      guard account.nativeCurrencyCode == request.money.currencyCode else {
        throw LedgerError.accountCurrencyMismatch(accountID)
      }
      return account
    }

    let postings: [LedgerPostingBlueprint]
    switch request.details {
    case .expense(let paymentAccountID, let categoryAccountID):
      try Self.requireKind(
        of: requiredAccounts[0],
        isOneOf: [.asset, .liability]
      )
      try Self.requireKind(of: requiredAccounts[1], isOneOf: [.expense])
      postings = [
        LedgerPostingBlueprint(
          accountID: categoryAccountID,
          side: .debit,
          money: request.money,
          sequence: 0
        ),
        LedgerPostingBlueprint(
          accountID: paymentAccountID,
          side: .credit,
          money: request.money,
          sequence: 1
        ),
      ]

    case .income(let receivingAccountID, let categoryAccountID):
      try Self.requireKind(of: requiredAccounts[0], isOneOf: [.asset])
      try Self.requireKind(of: requiredAccounts[1], isOneOf: [.income])
      postings = [
        LedgerPostingBlueprint(
          accountID: receivingAccountID,
          side: .debit,
          money: request.money,
          sequence: 0
        ),
        LedgerPostingBlueprint(
          accountID: categoryAccountID,
          side: .credit,
          money: request.money,
          sequence: 1
        ),
      ]

    case .transfer(let sourceAccountID, let destinationAccountID):
      try Self.requireKind(
        of: requiredAccounts[0],
        isOneOf: [.asset, .liability]
      )
      try Self.requireKind(
        of: requiredAccounts[1],
        isOneOf: [.asset, .liability]
      )
      postings = [
        LedgerPostingBlueprint(
          accountID: destinationAccountID,
          side: .debit,
          money: request.money,
          sequence: 0
        ),
        LedgerPostingBlueprint(
          accountID: sourceAccountID,
          side: .credit,
          money: request.money,
          sequence: 1
        ),
      ]
    }

    guard Self.isBalanced(postings) else {
      throw LedgerError.unbalancedPostings
    }
    return LedgerPostingPlan(kind: request.details.kind, postings: postings)
  }

  static func isBalanced(_ postings: [LedgerPostingBlueprint]) -> Bool {
    guard postings.count >= 2 else {
      return false
    }

    let currencies = Set(postings.map(\.money.currencyCode))
    guard currencies.count == 1 else {
      return false
    }

    var debitTotal: Int64 = 0
    var creditTotal: Int64 = 0
    for posting in postings {
      let (newTotal, overflow): (Int64, Bool)
      switch posting.side {
      case .debit:
        (newTotal, overflow) = debitTotal.addingReportingOverflow(posting.money.minorUnits)
        guard !overflow else { return false }
        debitTotal = newTotal
      case .credit:
        (newTotal, overflow) = creditTotal.addingReportingOverflow(posting.money.minorUnits)
        guard !overflow else { return false }
        creditTotal = newTotal
      }
    }
    return debitTotal == creditTotal
  }

  private static func requireKind(
    of account: LedgerAccount,
    isOneOf acceptedKinds: Set<LedgerAccountKind>
  ) throws {
    guard acceptedKinds.contains(account.kind) else {
      throw LedgerError.invalidAccountKind(account.id)
    }
  }
}
