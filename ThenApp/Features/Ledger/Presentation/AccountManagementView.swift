import SwiftUI

struct AccountManagementView: View {
  @State private var model: AccountManagementViewModel
  @State private var isPresentingCreateAccount = false
  private let environment: AppEnvironment

  init(environment: AppEnvironment) {
    self.environment = environment
    _model = State(
      initialValue: AccountManagementViewModel(
        ownerID: environment.localLedgerIdentity.profileID,
        ledgerQuery: environment.ledgerQuery,
        setLedgerAccountStatus: environment.setLedgerAccountStatus
      )
    )
  }

  var body: some View {
    List {
      if !model.isCurrencyConfirmed {
        Section {
          Label(
            "保存首笔账目并确认本位币后，才可以添加自定义账户和分类。",
            systemImage: "info.circle"
          )
          .foregroundStyle(.secondary)
        }
      }

      managedSection("资金账户", summaries: model.fundingAccounts)
      managedSection("支出分类", summaries: model.expenseCategories)
      managedSection("收入分类", summaries: model.incomeCategories)
    }
    .overlay {
      if model.isLoading, model.accountSummaries.isEmpty {
        ProgressView("正在读取账户")
      }
    }
    .navigationTitle("账户与分类")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("添加", systemImage: "plus") {
          isPresentingCreateAccount = true
        }
        .disabled(!model.isCurrencyConfirmed)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding()
          .frame(maxWidth: .infinity)
          .background(.bar)
      }
    }
    .task {
      await model.load()
    }
    .refreshable {
      await model.load()
    }
    .sheet(isPresented: $isPresentingCreateAccount) {
      CreateLedgerAccountView(
        ownerID: environment.localLedgerIdentity.profileID,
        existingSummaries: model.accountSummaries,
        createLedgerAccount: environment.createLedgerAccount
      ) { _ in
        Task { await model.load() }
      }
    }
  }

  @ViewBuilder
  private func managedSection(
    _ title: LocalizedStringKey,
    summaries: [LedgerAccountSummary]
  ) -> some View {
    if !summaries.isEmpty {
      Section(title) {
        ForEach(summaries) { summary in
          accountRow(summary)
        }
      }
    }
  }

  private func accountRow(_ summary: LedgerAccountSummary) -> some View {
    LedgerAccountSummaryRow(
      summary: summary,
      parentName: model.parentName(for: summary)
    )
    .id("\(summary.id.uuidString)-\(summary.account.status.rawValue)")
    .padding(.leading, summary.account.parentID == nil ? 0 : 16)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        Task { await model.setStatus(for: summary) }
      } label: {
        Label(
          summary.account.status == .active ? "归档" : "恢复",
          systemImage: summary.account.status == .active
            ? "archivebox"
            : "arrow.uturn.backward"
        )
      }
      .tint(summary.account.status == .active ? .orange : .blue)
      .disabled(model.changingAccountIDs.contains(summary.id))
    }
  }
}

private struct CreateLedgerAccountView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: CreateLedgerAccountViewModel
  let onCreated: (LedgerAccount) -> Void

  init(
    ownerID: UUID,
    existingSummaries: [LedgerAccountSummary],
    createLedgerAccount: CreateLedgerAccountUseCase,
    onCreated: @escaping (LedgerAccount) -> Void
  ) {
    _model = State(
      initialValue: CreateLedgerAccountViewModel(
        ownerID: ownerID,
        existingSummaries: existingSummaries,
        createLedgerAccount: createLedgerAccount
      )
    )
    self.onCreated = onCreated
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("类型") {
          Picker(
            "账户或分类类型",
            selection: Binding(
              get: { model.creationType },
              set: { model.selectCreationType($0) }
            )
          ) {
            ForEach(LedgerAccountCreationType.allCases, id: \.self) { type in
              Text(type.title).tag(type)
            }
          }
        }

        Section("基本信息") {
          TextField("名称", text: $model.name)
          if model.creationType.supportsParent {
            Picker("父分类（可选）", selection: $model.parentID) {
              Text("无").tag(Optional<UUID>.none)
              ForEach(model.parentOptions) { summary in
                Text(summary.account.name).tag(Optional(summary.id))
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
      }
      .navigationTitle("添加账户或分类")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(model.isSaving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            dismiss()
          }
          .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              if let account = await model.save() {
                onCreated(account)
                dismiss()
              }
            }
          }
          .disabled(model.isSaving)
        }
      }
      .overlay {
        if model.isSaving {
          ProgressView("正在保存")
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
      }
    }
  }
}
