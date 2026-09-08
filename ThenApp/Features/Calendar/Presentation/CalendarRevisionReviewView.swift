import SwiftUI

struct CalendarRevisionReviewView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: CalendarRevisionReviewViewModel
  private let environment: AppEnvironment
  private let onResolved: @MainActor () -> Void

  init(
    environment: AppEnvironment,
    occurrence: CalendarOccurrenceSummary,
    onResolved: @escaping @MainActor () -> Void = {}
  ) {
    self.environment = environment
    self.onResolved = onResolved
    _model = State(
      initialValue: CalendarRevisionReviewViewModel(
        occurrence: occurrence,
        calendarImport: environment.calendarImport,
        tripPlanning: environment.tripPlanning
      )
    )
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.isLoading, model.revisions.isEmpty {
          ProgressView("正在读取来源变化")
        } else {
          reviewContent
        }
      }
      .navigationTitle("来源变化")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
      }
      .task { await model.load() }
      .sheet(item: $model.editorSeed) { seed in
        TripPlanEditorView(environment: environment, seed: seed) {
          model.adoptionCompleted()
          onResolved()
          dismiss()
        }
      }
    }
  }

  private var reviewContent: some View {
    Form {
      Section("当前计划") {
        if let plan = model.linkedPlans.first, model.linkedPlans.count == 1 {
          LabeledContent("名称", value: plan.displayName ?? "未命名计划")
          LabeledContent("目的地", value: plan.destination.name)
          LabeledContent(
            "到达",
            value: plan.targetArrivalAt.formatted(date: .abbreviated, time: .shortened)
          )
          if let departure = plan.plannedDepartureAt {
            LabeledContent(
              "出发",
              value: departure.formatted(date: .abbreviated, time: .shortened)
            )
          }
        }
        if let message = model.planStateMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      ForEach(model.reviewedRevisions) { revision in
        Section("来源版本 \(revision.fromVersion) → \(revision.toVersion)") {
          differenceRow("标题", old: revision.oldTitle, new: revision.newTitle)
          differenceRow(
            "开始",
            old: revision.oldStartsAt.formatted(date: .abbreviated, time: .shortened),
            new: revision.newStartsAt.formatted(date: .abbreviated, time: .shortened)
          )
          differenceRow(
            "时区", old: revision.oldTimeZoneIdentifier, new: revision.newTimeZoneIdentifier)
          differenceRow("地点", old: revision.oldLocationText, new: revision.newLocationText)
          LabeledContent(
            "发现时间",
            value: revision.detectedAt.formatted(date: .abbreviated, time: .shortened)
          )
        }
      }

      if let error = model.errorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      } else if let status = model.statusMessage {
        Section {
          Label(status, systemImage: "checkmark.circle")
        }
      }

      if !model.reviewedRevisions.isEmpty {
        Section {
          Button("采用到计划", systemImage: "arrow.down.doc") {
            model.beginAdoption()
          }
          .disabled(!model.canAdopt || model.isResolving)

          Button("保留当前计划", systemImage: "checkmark.shield") {
            Task {
              if await model.keepCurrentPlan() {
                onResolved()
                dismiss()
              }
            }
          }
          .disabled(model.isResolving)
        } footer: {
          Text("采用会进入编辑确认页；保留只解决你已看到的变化，不修改计划、路线或提醒。")
        }
      }
    }
    .headerProminence(.increased)
    .modifier(AdaptiveHardScrollEdgeEffectModifier())
  }

  @ViewBuilder
  private func differenceRow(_ label: String, old: String?, new: String?) -> some View {
    if old != new {
      VStack(alignment: .leading, spacing: 4) {
        Text(label).font(.subheadline.weight(.semibold))
        Text("原值：\(old ?? "无")")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("新值：\(new ?? "无")")
          .font(.body)
      }
      .accessibilityElement(children: .combine)
    }
  }
}
