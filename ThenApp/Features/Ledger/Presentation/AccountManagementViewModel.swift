import Foundation
import Observation

@MainActor
@Observable
final class AccountManagementViewModel {
  private let ownerID: UUID
  private let ledgerQuery: LedgerQueryService
  private let setLedgerAccountStatus: SetLedgerAccountStatusUseCase
  private let now: @Sendable () -> Date

  var accountSummaries: [LedgerAccountSummary] = []
  var isCurrencyConfirmed = false
  var isLoading = false
  var changingAccountIDs: Set<UUID> = []
  var errorMessage: LocalizedStringResource?

  init(
    ownerID: UUID,
    ledgerQuery: LedgerQueryService,
    setLedgerAccountStatus: SetLedgerAccountStatusUseCase,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.ownerID = ownerID
    self.ledgerQuery = ledgerQuery
    self.setLedgerAccountStatus = setLedgerAccountStatus
    self.now = now
  }

  var visibleSummaries: [LedgerAccountSummary] {
    accountSummaries.filter { $0.account.kind != .equity }
  }

  var fundingAccounts: [LedgerAccountSummary] {
    visibleSummaries.filter {
      $0.account.kind == .asset || $0.account.kind == .liability
    }
  }

  var expenseCategories: [LedgerAccountSummary] {
    visibleSummaries.filter { $0.account.kind == .expense }
  }

  var incomeCategories: [LedgerAccountSummary] {
    visibleSummaries.filter { $0.account.kind == .income }
  }

  func parentName(for summary: LedgerAccountSummary) -> String? {
    guard let parentID = summary.account.parentID else { return nil }
    return accountSummaries.first(where: { $0.id == parentID })?.account.name
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      async let profile = ledgerQuery.localProfile(ownerID: ownerID)
      async let summaries = ledgerQuery.accountSummaries(ownerID: ownerID)
      isCurrencyConfirmed = try await profile.baseCurrencyState == .confirmed
      accountSummaries = try await summaries
    } catch {
      errorMessage = "无法读取账户和分类，请稍后重试。"
    }
  }

  func setStatus(for summary: LedgerAccountSummary) async {
    guard !changingAccountIDs.contains(summary.id) else { return }
    changingAccountIDs.insert(summary.id)
    errorMessage = nil
    defer { changingAccountIDs.remove(summary.id) }

    let targetStatus: LedgerAccountStatus =
      summary.account.status == .active ? .archived : .active
    do {
      let account = try await setLedgerAccountStatus.execute(
        SetLedgerAccountStatusRequest(
          ownerID: ownerID,
          accountID: summary.id,
          status: targetStatus,
          changedAt: now()
        )
      )
      guard let index = accountSummaries.firstIndex(where: { $0.id == account.id }) else {
        await load()
        return
      }
      accountSummaries[index] = LedgerAccountSummary(
        account: account,
        balance: accountSummaries[index].balance
      )
    } catch LedgerError.accountHasActiveChildren {
      errorMessage = "请先归档该分类下仍在使用的子分类。"
    } catch LedgerError.internalAccountProtected {
      errorMessage = "系统内部账户受保护，不能归档。"
    } catch LedgerError.accountArchived {
      errorMessage = "请先恢复该分类的父分类。"
    } catch {
      errorMessage = "状态修改失败，原有数据没有改变。"
    }
  }
}

@MainActor
@Observable
final class CreateLedgerAccountViewModel {
  private let ownerID: UUID
  private let createLedgerAccount: CreateLedgerAccountUseCase
  private let now: @Sendable () -> Date
  private var pendingAccountID = UUID()

  let existingSummaries: [LedgerAccountSummary]
  var creationType: LedgerAccountCreationType = .bank
  var name = ""
  var parentID: UUID?
  var isSaving = false
  var errorMessage: LocalizedStringResource?

  init(
    ownerID: UUID,
    existingSummaries: [LedgerAccountSummary],
    createLedgerAccount: CreateLedgerAccountUseCase,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.ownerID = ownerID
    self.existingSummaries = existingSummaries
    self.createLedgerAccount = createLedgerAccount
    self.now = now
  }

  var parentOptions: [LedgerAccountSummary] {
    existingSummaries.filter {
      $0.account.status == .active
        && $0.account.kind == creationType.kind
        && $0.account.parentID == nil
    }
  }

  func selectCreationType(_ type: LedgerAccountCreationType) {
    creationType = type
    if !type.supportsParent
      || !parentOptions.contains(where: { $0.id == parentID })
    {
      parentID = nil
    }
    errorMessage = nil
  }

  func save() async -> LedgerAccount? {
    guard !isSaving else { return nil }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }

    do {
      let account = try await createLedgerAccount.execute(
        CreateLedgerAccountRequest(
          accountID: pendingAccountID,
          ownerID: ownerID,
          creationType: creationType,
          name: name,
          parentID: parentID,
          submittedAt: now()
        )
      )
      pendingAccountID = UUID()
      return account
    } catch LedgerError.invalidAccountName {
      errorMessage = "名称需要包含 1 至 40 个字符。"
    } catch LedgerError.baseCurrencyNotConfirmed {
      errorMessage = "请先保存首笔账目并确认本位币。"
    } catch LedgerError.categoryParentKindMismatch {
      errorMessage = "父分类必须与新分类属于同一类型。"
    } catch LedgerError.categoryHierarchyTooDeep {
      errorMessage = "分类最多支持一层父子关系。"
    } catch {
      errorMessage = "创建失败，输入内容仍然保留，请稍后重试。"
    }
    return nil
  }
}

extension LedgerAccountCreationType {
  var title: LocalizedStringResource {
    switch self {
    case .cash:
      "现金"
    case .bank:
      "银行卡"
    case .electronicWallet:
      "电子钱包"
    case .creditCard:
      "信用卡"
    case .expenseCategory:
      "支出分类"
    case .incomeCategory:
      "收入分类"
    }
  }
}
