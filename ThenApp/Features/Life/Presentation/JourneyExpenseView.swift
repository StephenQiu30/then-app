import Observation
import SwiftUI

@MainActor
@Observable
private final class JourneyExpenseViewModel {
  private let journeyID: UUID
  private let ownerID: UUID
  private let lifeLinks: LifeLinkService
  private let ledgerQuery: LedgerQueryService
  private let journeyRecording: JourneyRecordingService

  var summary: JourneyExpenseSummary?
  var recentTransactions: [LedgerTransactionSummary] = []
  var selectedRootID: UUID?
  var selectedRole: JourneyExpenseRole = .transport
  var isLoading = false
  var isSaving = false
  var errorMessage: LocalizedStringResource?

  init(
    journeyID: UUID,
    ownerID: UUID,
    lifeLinks: LifeLinkService,
    ledgerQuery: LedgerQueryService,
    journeyRecording: JourneyRecordingService
  ) {
    self.journeyID = journeyID
    self.ownerID = ownerID
    self.lifeLinks = lifeLinks
    self.ledgerQuery = ledgerQuery
    self.journeyRecording = journeyRecording
  }

  var availableTransactions: [LedgerTransactionSummary] {
    let linkedRoots = Set(summary?.expenses.map(\.link.transactionRootID) ?? [])
    return recentTransactions.filter { transaction in
      transaction.kind == .expense
        && !transaction.isReversed
        && !linkedRoots.contains(transaction.rootID)
    }
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let loadedSummary = lifeLinks.summary(journeyID: journeyID)
      async let loadedTransactions = ledgerQuery.recentTransactions(
        ownerID: ownerID,
        limit: 100
      )
      let values = try await (loadedSummary, loadedTransactions)
      summary = values.0
      recentTransactions = values.1
      reconcileSelection()
    } catch {
      errorMessage = "无法读取行程消费，请稍后重试。"
    }
  }

  func linkSelected() async {
    guard !isSaving, let selectedRootID else { return }
    await link(rootID: selectedRootID)
  }

  func linkNewExpense(_ transaction: PostedLedgerTransaction) async {
    guard transaction.kind == .expense else {
      errorMessage = "只有支出可以计入行程消费。"
      return
    }
    await link(rootID: transaction.canonicalRootID)
  }

  func unlink(_ linkID: UUID) async {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await lifeLinks.unlink(linkID: linkID)
      await loadAfterWrite()
    } catch {
      errorMessage = "无法解除关联，请稍后重试。"
    }
  }

  func markNoExpense() async {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await lifeLinks.markNoExpense(journeyID: journeyID)
      await loadAfterWrite()
    } catch LifeLinkError.journeyHasLinkedExpenses {
      errorMessage = "请先解除已关联消费，再确认本次无消费。"
    } catch {
      errorMessage = "无法确认本次无消费，请稍后重试。"
    }
  }

  func deleteJourney() async -> Bool {
    guard !isSaving else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await journeyRecording.delete(journeyID: journeyID)
      return true
    } catch {
      errorMessage = "只能删除已完成的行程；正式交易和分录不会被删除。"
      return false
    }
  }

  private func link(rootID: UUID) async {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      _ = try await lifeLinks.linkTransaction(
        rootID: rootID,
        to: journeyID,
        role: selectedRole
      )
      await loadAfterWrite()
    } catch LifeLinkError.existingLinkHasDifferentRole {
      errorMessage = "这笔交易已经用其他用途关联到本行程。"
    } catch {
      errorMessage = "无法关联交易，请确认交易和行程都已正式保存。"
    }
  }

  private func loadAfterWrite() async {
    do {
      summary = try await lifeLinks.summary(journeyID: journeyID)
      recentTransactions = try await ledgerQuery.recentTransactions(ownerID: ownerID, limit: 100)
      reconcileSelection()
    } catch {
      errorMessage = "操作已提交，但刷新行程消费失败。"
    }
  }

  private func reconcileSelection() {
    if !availableTransactions.contains(where: { $0.rootID == selectedRootID }) {
      selectedRootID = availableTransactions.first?.rootID
    }
  }
}

struct JourneyExpenseView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: JourneyExpenseViewModel
  @State private var isCreatingExpense = false
  @State private var isConfirmingDeletion = false
  private let environment: AppEnvironment
  private let canDeleteJourney: Bool
  private let onDeleted: @MainActor () -> Void

  init(
    journey: JourneySnapshot,
    environment: AppEnvironment,
    onDeleted: @escaping @MainActor () -> Void = {}
  ) {
    self.environment = environment
    canDeleteJourney = journey.status == .completed || journey.status == .discarded
    self.onDeleted = onDeleted
    _model = State(
      initialValue: JourneyExpenseViewModel(
        journeyID: journey.id,
        ownerID: environment.localLedgerIdentity.profileID,
        lifeLinks: environment.lifeLinks,
        ledgerQuery: environment.ledgerQuery,
        journeyRecording: environment.journeyRecording
      )
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        if let summary = model.summary {
          Section("消费复盘") {
            if summary.expenses.isEmpty {
              switch summary.reviewState {
              case .pending:
                Text("尚未完成本次消费复盘。")
                  .foregroundStyle(.secondary)
                Button("本次无消费", systemImage: "checkmark.circle") {
                  Task { await model.markNoExpense() }
                }
                .disabled(model.isSaving)
              case .noExpense:
                Label("已确认本次无消费", systemImage: "checkmark.circle.fill")
                  .foregroundStyle(.secondary)
                Text("之后仍可新建或关联真实消费。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              case .hasExpense:
                EmptyView()
              }
            } else {
              ForEach(summary.expenses) { expense in
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text(expense.payee ?? "未填写商户")
                    Spacer()
                    Text(LedgerAmountText.formatted(expense.netExpense))
                      .monospacedDigit()
                      .accessibilityLabel(
                        Text(LedgerAmountText.accessibilityFormatted(expense.netExpense))
                      )
                  }
                  Text(roleTitle(expense.link.role))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Button("解除关联", role: .destructive) {
                    Task { await model.unlink(expense.link.id) }
                  }
                }
              }
              LabeledContent("净支出合计") {
                Text(LedgerAmountText.formatted(summary.total))
                  .fontWeight(.semibold)
                  .monospacedDigit()
                  .accessibilityLabel(
                    Text(LedgerAmountText.accessibilityFormatted(summary.total))
                  )
              }
            }
          }
        }

        Section("添加消费") {
          Picker("用途", selection: $model.selectedRole) {
            ForEach(JourneyExpenseRole.allCases) { role in
              Text(roleTitle(role)).tag(role)
            }
          }
          if model.availableTransactions.isEmpty {
            Text("没有尚未关联的正式支出。")
              .foregroundStyle(.secondary)
          } else {
            Picker("已有支出", selection: $model.selectedRootID) {
              ForEach(model.availableTransactions) { transaction in
                Text(transactionTitle(transaction))
                  .accessibilityLabel(Text(transactionAccessibilityTitle(transaction)))
                  .tag(Optional(transaction.rootID))
              }
            }
            Button("关联已有支出", systemImage: "link") {
              Task { await model.linkSelected() }
            }
            .disabled(model.selectedRootID == nil || model.isSaving)
          }
          Button("新建支出并关联", systemImage: "plus.circle") {
            isCreatingExpense = true
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }

        if canDeleteJourney {
          Section {
            Button("删除此行程", systemImage: "trash", role: .destructive) {
              isConfirmingDeletion = true
            }
          } footer: {
            Text("只删除行程摘要和消费关系；已确认交易、分录和出行计划继续保留。")
          }
        }
      }
      .navigationTitle("行程消费")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
      }
      .overlay {
        if model.isLoading || model.isSaving { ProgressView() }
      }
      .task { await model.load() }
      .sheet(isPresented: $isCreatingExpense) {
        QuickTransactionView(
          identity: environment.localLedgerIdentity,
          confirmBaseCurrency: environment.confirmBaseCurrency,
          createTransaction: environment.createTransaction,
          ledgerQuery: environment.ledgerQuery,
          receiptOCR: environment.receiptOCR,
          receiptCameraAccess: environment.receiptCameraAccess,
          initialTransactionType: .expense,
          allowsTransactionTypeSelection: false
        ) { transaction in
          Task { await model.linkNewExpense(transaction) }
        }
      }
      .alert("删除此行程？", isPresented: $isConfirmingDeletion) {
        Button("删除行程", role: .destructive) {
          Task {
            if await model.deleteJourney() {
              onDeleted()
              dismiss()
            }
          }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("行程消费关系会解除，但正式交易、分录和出行计划不会被删除。")
      }
    }
  }

  private func transactionTitle(_ transaction: LedgerTransactionSummary) -> String {
    let payee = transaction.payee ?? "未填写商户"
    return "\(payee) · \(LedgerAmountText.formatted(transaction.money))"
  }

  private func transactionAccessibilityTitle(
    _ transaction: LedgerTransactionSummary
  ) -> String {
    let payee = transaction.payee ?? "未填写商户"
    return "\(payee)，\(LedgerAmountText.accessibilityFormatted(transaction.money))"
  }

  private func roleTitle(_ role: JourneyExpenseRole) -> String {
    switch role {
    case .transport: "交通"
    case .parking: "停车"
    case .toll: "通行费"
    case .meal: "餐饮"
    case .other: "其他"
    }
  }
}
