import Foundation
import Observation

@MainActor
@Observable
final class LedgerViewModel {
  private let ownerID: UUID
  private let ledgerQuery: any LedgerQuerying
  private let now: @Sendable () -> Date
  private let timeZoneIdentifier: @Sendable () -> String
  private var searchGeneration = 0

  var accountSummaries: [LedgerAccountSummary] = []
  var recentTransactions: [LedgerTransactionSummary] = []
  var searchResults: [LedgerTransactionSummary] = []
  var monthlyReport: LedgerMonthlyReport?
  var baseCurrencyCode: CurrencyCode
  var baseCurrencyState: BaseCurrencyState
  var selectedMonthDate: Date
  var searchText = ""
  var selectedFundingAccountID: UUID?
  var selectedCategoryAccountID: UUID?
  var journeyLinkFilter: LedgerJourneyLinkFilter = .any
  var isLoading = false
  var isSearching = false
  var isLoadingReport = false
  var errorMessage: LocalizedStringResource?
  var reportErrorMessage: LocalizedStringResource?

  init(
    identity: LocalLedgerIdentity,
    ledgerQuery: any LedgerQuerying,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
  ) {
    ownerID = identity.profileID
    self.ledgerQuery = ledgerQuery
    self.now = now
    self.timeZoneIdentifier = timeZoneIdentifier
    baseCurrencyCode = identity.baseCurrencyCode
    baseCurrencyState = identity.baseCurrencyState
    selectedMonthDate = now()
  }

  var isSearchActive: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var hasStructuredFilters: Bool {
    selectedFundingAccountID != nil || selectedCategoryAccountID != nil
      || journeyLinkFilter != .any
  }

  var hasActiveFilters: Bool {
    isSearchActive || hasStructuredFilters
  }

  var displayedTransactions: [LedgerTransactionSummary] {
    hasActiveFilters ? searchResults : recentTransactions
  }

  var filterSummary: String {
    var parts: [String] = []
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      parts.append("关键词：\(query)")
    }
    if let selectedFundingAccountID,
      let account = fundingAccounts.first(where: { $0.id == selectedFundingAccountID })
    {
      parts.append("账户：\(account.account.name)")
    }
    if let selectedCategoryAccountID,
      let category = categoryAccounts.first(where: { $0.id == selectedCategoryAccountID })
    {
      parts.append("分类：\(category.account.name)")
    }
    switch journeyLinkFilter {
    case .any:
      break
    case .linked:
      parts.append("已关联行程")
    case .unlinked:
      parts.append("未关联行程")
    }
    return parts.isEmpty ? "全部账目" : parts.joined(separator: "；")
  }

  var monthTitle: String {
    guard
      let month = try? LedgerMonth(
        containing: selectedMonthDate,
        timeZoneIdentifier: timeZoneIdentifier()
      )
    else {
      return "所选月份"
    }
    return "\(month.year) 年 \(month.month) 月"
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

  var categoryAccounts: [LedgerAccountSummary] {
    expenseCategories + incomeCategories
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let profile = try await ledgerQuery.localProfile(ownerID: ownerID)
      baseCurrencyCode = profile.baseCurrencyCode
      baseCurrencyState = profile.baseCurrencyState
    } catch {
      errorMessage = "无法读取本位币状态，请稍后重试。"
    }

    do {
      accountSummaries = try await ledgerQuery.accountSummaries(ownerID: ownerID)
    } catch {
      errorMessage = "部分账本信息无法读取，请稍后重试。"
    }

    do {
      recentTransactions = try await ledgerQuery.recentTransactions(
        ownerID: ownerID,
        limit: 100
      )
    } catch {
      errorMessage = "部分账本信息无法读取，请稍后重试。"
    }

    await refreshFilteredContent()
  }

  func search() async {
    await refreshFilteredContent()
  }

  func applyStructuredFilters(
    fundingAccountID: UUID?,
    categoryAccountID: UUID?,
    journeyLink: LedgerJourneyLinkFilter
  ) async {
    selectedFundingAccountID = fundingAccountID
    selectedCategoryAccountID = categoryAccountID
    journeyLinkFilter = journeyLink
    await refreshFilteredContent()
  }

  func clearFilters() async {
    searchText = ""
    selectedFundingAccountID = nil
    selectedCategoryAccountID = nil
    journeyLinkFilter = .any
    await refreshFilteredContent()
  }

  private func refreshFilteredContent() async {
    searchGeneration += 1
    let generation = searchGeneration
    let filter = currentFilter
    if !filter.isActive {
      searchResults = []
      isSearching = false
      await loadMonthlyReport(generation: generation, filter: filter)
      return
    }

    isSearching = true
    errorMessage = nil
    defer {
      if searchGeneration == generation {
        isSearching = false
      }
    }

    do {
      let results = try await ledgerQuery.filteredTransactions(
        ownerID: ownerID,
        filter: filter,
        limit: 100
      )
      guard searchGeneration == generation, currentFilter == filter else {
        return
      }
      searchResults = results
    } catch {
      errorMessage = "无法读取本地筛选结果，请稍后重试。"
    }
    await loadMonthlyReport(generation: generation, filter: filter)
  }

  func moveSelectedMonth(by offset: Int) async {
    guard offset != 0, let timeZone = TimeZone(identifier: timeZoneIdentifier()) else {
      return
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let date = calendar.date(byAdding: .month, value: offset, to: selectedMonthDate) else {
      return
    }
    selectedMonthDate = date
    searchGeneration += 1
    let generation = searchGeneration
    await loadMonthlyReport(generation: generation, filter: currentFilter)
  }

  private func loadMonthlyReport(
    generation: Int,
    filter: LedgerTransactionFilter
  ) async {
    guard baseCurrencyState == .confirmed else {
      if searchGeneration == generation {
        monthlyReport = nil
        reportErrorMessage = nil
      }
      return
    }
    isLoadingReport = true
    reportErrorMessage = nil
    defer {
      if searchGeneration == generation {
        isLoadingReport = false
      }
    }

    do {
      let report = try await ledgerQuery.monthlyReport(
        ownerID: ownerID,
        containing: selectedMonthDate,
        timeZoneIdentifier: timeZoneIdentifier(),
        filter: filter
      )
      guard searchGeneration == generation, currentFilter == filter else { return }
      monthlyReport = report
    } catch {
      if searchGeneration == generation {
        reportErrorMessage = "无法读取所选月份的本地报表，请稍后重试。"
      }
    }
  }

  private var currentFilter: LedgerTransactionFilter {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let amountMinorUnits = try? LedgerAmountText.parsePositiveMoney(
      query,
      currencyCode: baseCurrencyCode
    ).minorUnits
    return LedgerTransactionFilter(
      searchText: query,
      amountMinorUnits: amountMinorUnits,
      fundingAccountID: selectedFundingAccountID,
      categoryAccountID: selectedCategoryAccountID,
      journeyLink: journeyLinkFilter
    )
  }

  private var visibleSummaries: [LedgerAccountSummary] {
    accountSummaries.filter { $0.account.kind != .equity }
  }
}
