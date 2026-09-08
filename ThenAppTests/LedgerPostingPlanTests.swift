import Foundation
import Testing

@testable import ThenApp

@Suite("账务分录计划")
struct LedgerPostingPlanTests {
  private let ownerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private let cashID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  private let bankID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
  private let expenseID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
  private let incomeID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

  @Test("支出收入转账生成正确且平衡的分录")
  func commonTransactionKindsAreBalanced() throws {
    let profile = LocalLedgerProfile(
      id: ownerID,
      baseCurrencyCode: .cny,
      baseCurrencyState: .confirmed
    )
    let accounts = [
      account(id: cashID, kind: .asset),
      account(id: bankID, kind: .asset),
      account(id: expenseID, kind: .expense),
      account(id: incomeID, kind: .income),
    ]

    let expense = try LedgerPostingPlan.make(
      request: request(
        details: .expense(paymentAccountID: cashID, categoryAccountID: expenseID)
      ),
      profile: profile,
      accounts: accounts
    )
    #expect(expense.kind == .expense)
    #expect(expense.postings.map(\.side) == [.debit, .credit])
    #expect(expense.postings.map(\.accountID) == [expenseID, cashID])
    #expect(LedgerPostingPlan.isBalanced(expense.postings))

    let income = try LedgerPostingPlan.make(
      request: request(
        details: .income(receivingAccountID: bankID, categoryAccountID: incomeID)
      ),
      profile: profile,
      accounts: accounts
    )
    #expect(income.kind == .income)
    #expect(income.postings.map(\.side) == [.debit, .credit])
    #expect(income.postings.map(\.accountID) == [bankID, incomeID])
    #expect(LedgerPostingPlan.isBalanced(income.postings))

    let transfer = try LedgerPostingPlan.make(
      request: request(
        details: .transfer(sourceAccountID: cashID, destinationAccountID: bankID)
      ),
      profile: profile,
      accounts: accounts
    )
    #expect(transfer.kind == .transfer)
    #expect(transfer.postings.map(\.accountID) == [bankID, cashID])
    #expect(LedgerPostingPlan.isBalanced(transfer.postings))
  }

  @Test("未确认本币、同账户转账和错误账户类型会被拒绝")
  func invalidPostingContextsAreRejected() throws {
    let suggestedProfile = LocalLedgerProfile(
      id: ownerID,
      baseCurrencyCode: .cny,
      baseCurrencyState: .suggested
    )
    let confirmedProfile = LocalLedgerProfile(
      id: ownerID,
      baseCurrencyCode: .cny,
      baseCurrencyState: .confirmed
    )
    let accounts = [
      account(id: cashID, kind: .asset),
      account(id: expenseID, kind: .expense),
    ]

    #expect(throws: LedgerError.baseCurrencyNotConfirmed) {
      try LedgerPostingPlan.make(
        request: request(
          details: .expense(paymentAccountID: cashID, categoryAccountID: expenseID)
        ),
        profile: suggestedProfile,
        accounts: accounts
      )
    }
    #expect(throws: LedgerError.transferAccountsMustDiffer) {
      try LedgerPostingPlan.make(
        request: request(
          details: .transfer(sourceAccountID: cashID, destinationAccountID: cashID)
        ),
        profile: confirmedProfile,
        accounts: accounts
      )
    }
    #expect(throws: LedgerError.invalidAccountKind(expenseID)) {
      try LedgerPostingPlan.make(
        request: request(
          details: .income(receivingAccountID: expenseID, categoryAccountID: cashID)
        ),
        profile: confirmedProfile,
        accounts: accounts
      )
    }
  }

  @Test("金额必须使用正整数最小货币单位")
  func moneyRejectsNonPositiveMinorUnits() {
    #expect(throws: PositiveMoney.ValidationError.amountMustBePositive) {
      try PositiveMoney(minorUnits: 0, currencyCode: .cny)
    }
    #expect(throws: PositiveMoney.ValidationError.amountMustBePositive) {
      try PositiveMoney(minorUnits: -1, currencyCode: .cny)
    }
  }

  private func account(id: UUID, kind: LedgerAccountKind) -> LedgerAccount {
    LedgerAccount(
      id: id,
      ownerID: ownerID,
      parentID: nil,
      kind: kind,
      subtype: .custom,
      name: "测试账户",
      nativeCurrencyCode: .cny,
      configurationState: .ready,
      systemKey: nil,
      status: .active,
      displayOrder: 0
    )
  }

  private func request(
    details: ManualLedgerTransactionDetails
  ) throws -> CreateLedgerTransactionRequest {
    try CreateLedgerTransactionRequest(
      transactionID: UUID(),
      ownerID: ownerID,
      details: details,
      money: PositiveMoney(minorUnits: 1_250, currencyCode: .cny),
      occurredAt: Date(timeIntervalSince1970: 1_786_287_000),
      originalTimeZoneIdentifier: "Asia/Shanghai",
      submittedAt: Date(timeIntervalSince1970: 1_786_287_100)
    )
  }
}
