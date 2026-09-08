import Observation
import SwiftUI

@MainActor
@Observable
final class TripPlanListViewModel {
  private let service: TripPlanningService
  private let journeyNavigation: JourneyNavigationCoordinator
  private let journeyRecording: JourneyRecordingService
  private let clipboard: any DestinationClipboard

  var plans: [TripPlanSummary] = []
  var journeys: [JourneySnapshot] = []
  var isLoading = false
  var navigationError: LocalizedStringResource?
  private(set) var failedNavigationPlan: TripPlanSummary?
  private(set) var clipboardConfirmation: LocalizedStringResource?

  init(
    service: TripPlanningService,
    journeyNavigation: JourneyNavigationCoordinator,
    journeyRecording: JourneyRecordingService,
    clipboard: any DestinationClipboard
  ) {
    self.service = service
    self.journeyNavigation = journeyNavigation
    self.journeyRecording = journeyRecording
    self.clipboard = clipboard
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    async let loadedPlans = service.plans()
    async let loadedJourneys = journeyRecording.journeys()
    plans = (try? await loadedPlans) ?? plans
    journeys = (try? await loadedJourneys) ?? journeys
  }

  func openMaps(for plan: TripPlanSummary) async {
    clearNavigationFailure()
    do {
      try await service.openAppleMaps(for: plan)
    } catch {
      failedNavigationPlan = plan
      navigationError = "Apple 地图未能打开，你可以复制目的地后继续。"
    }
  }

  func startRecordingAndOpenMaps(for plan: TripPlanSummary) async -> Bool {
    clearNavigationFailure()
    do {
      let result = try await journeyNavigation.startRecordingAndOpenMaps(for: plan)
      if !result.didOpenAppleMaps {
        failedNavigationPlan = plan
        navigationError = "实际行程已保存，但 Apple 地图未能打开。"
      }
      return true
    } catch JourneyRecordingError.activeJourneyExists {
      navigationError = "已有未结束行程，请先恢复、完成或丢弃。"
      return false
    } catch {
      navigationError = "无法开始记录，未创建新的行程。"
      return false
    }
  }

  func copyFailedDestination() {
    guard let destination = failedNavigationPlan?.destination else { return }
    clipboard.copy(Self.clipboardText(for: destination))
    clipboardConfirmation = "目的地已复制"
  }

  static func clipboardText(for destination: ConfirmedLocation) -> String {
    let address = destination.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return address.isEmpty ? destination.name : address
  }

  private func clearNavigationFailure() {
    navigationError = nil
    failedNavigationPlan = nil
    clipboardConfirmation = nil
  }
}

struct TripPlanListView: View {
  private let environment: AppEnvironment
  @State private var model: TripPlanListViewModel
  @State private var editorSeed: TripPlanEditorSeed?
  @State private var journeyPlan: TripPlanSummary?
  @State private var showsManualJourney = false
  @State private var expenseJourney: JourneySnapshot?

  init(
    environment: AppEnvironment,
    clipboard: any DestinationClipboard = SystemDestinationClipboard()
  ) {
    self.environment = environment
    _model = State(
      initialValue: TripPlanListViewModel(
        service: environment.tripPlanning,
        journeyNavigation: environment.journeyNavigation,
        journeyRecording: environment.journeyRecording,
        clipboard: clipboard
      ))
  }

  var body: some View {
    List {
      if let error = model.navigationError {
        Section(model.failedNavigationPlan == nil ? "操作未完成" : "导航未打开") {
          HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .accessibilityHidden(true)
            Text(error)
              .lineLimit(nil)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("trip.navigation.failure-message")

          if let failedPlan = model.failedNavigationPlan {
            LabeledContent("目的地", value: failedPlan.destination.name)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("trip.navigation.failed-destination")
            Button {
              model.copyFailedDestination()
            } label: {
              HStack {
                Image(systemName: "doc.on.doc")
                Text("复制目的地")
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("trip.navigation.copy-destination")

            if let confirmation = model.clipboardConfirmation {
              HStack(alignment: .firstTextBaseline) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                  .accessibilityHidden(true)
                Text(confirmation)
                  .lineLimit(nil)
                  .foregroundStyle(.primary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("trip.navigation.copy-confirmation")
            }
          }
        }
      }
      if model.plans.isEmpty, model.journeys.isEmpty, !model.isLoading {
        VStack(spacing: 12) {
          Image(systemName: "figure.walk.departure")
            .font(.largeTitle)
            .accessibilityHidden(true)
          Text("还没有行程")
            .font(.headline)
          Text("可以手动创建计划，或直接开始记录实际行程。")
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
      }
      if !model.plans.isEmpty {
        Section("出行计划") {
          ForEach(model.plans) { plan in
            VStack(alignment: .leading, spacing: 6) {
              Text(plan.displayName ?? plan.destination.name)
                .font(.headline)
              LabeledContent("目的地", value: plan.destination.name)
              if let departure = plan.plannedDepartureAt {
                LabeledContent(
                  "出发", value: departure.formatted(date: .abbreviated, time: .shortened))
              }
              LabeledContent(
                "到达", value: plan.targetArrivalAt.formatted(date: .abbreviated, time: .shortened))
              HStack {
                Text(plan.routeEstimate == nil ? "手动时间" : "MapKit 路线")
                Text("·")
                Text(reminderTitle(plan.reminderStatus))
              }
              .font(.caption)
              .foregroundStyle(.primary)
              planActionButton("用 Apple 地图导航", systemImage: "map") {
                Task { await model.openMaps(for: plan) }
              }
              planActionButton("开始记录此行程", systemImage: "location.circle") {
                journeyPlan = plan
              }
              planActionButton(
                "开始记录并打开 Apple 地图",
                systemImage: "location.fill.viewfinder"
              ) {
                Task {
                  if await model.startRecordingAndOpenMaps(for: plan) {
                    journeyPlan = plan
                  }
                }
              }
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
          }
        }
      }
      if !model.journeys.isEmpty {
        Section("实际行程") {
          ForEach(model.journeys) { journey in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(journeyTitle(journey.status))
                  .font(.headline)
                Spacer()
                Text(transportTitle(journey.transportMode))
                  .font(.caption)
                  .foregroundStyle(.primary)
              }
              Text(journey.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.primary)
              if let duration = journey.durationSeconds {
                LabeledContent("时长", value: "\(max(0, Int(duration / 60))) 分钟")
              }
              if let distance = journey.distanceMeters {
                LabeledContent(
                  "距离",
                  value: Measurement(value: distance, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
                )
              }
              if [.recording, .paused, .finalizing, .reviewing].contains(journey.status) {
                Button("恢复处理", systemImage: "arrow.clockwise.circle") {
                  showsManualJourney = true
                }
              }
              if journey.status == .reviewing || journey.status == .completed {
                Button("查看行程消费", systemImage: "creditcard") {
                  expenseJourney = journey
                }
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .headerProminence(.increased)
    .modifier(AdaptiveHardScrollEdgeEffectModifier())
    .navigationTitle("出行计划")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("新建计划", systemImage: "plus") {
          editorSeed = .manual()
        }
      }
      ToolbarItem(placement: .secondaryAction) {
        Button("记录无计划行程", systemImage: "location.circle") {
          showsManualJourney = true
        }
      }
    }
    .overlay {
      if model.isLoading { ProgressView() }
    }
    .task { await model.load() }
    .refreshable { await model.load() }
    .sheet(
      item: $editorSeed,
      onDismiss: {
        Task { await model.load() }
      },
      content: { seed in
        TripPlanEditorView(environment: environment, seed: seed)
      }
    )
    .sheet(
      item: $journeyPlan,
      onDismiss: {
        Task { await model.load() }
      },
      content: { plan in
        JourneyRecordingView(environment: environment, initialPlan: plan)
      }
    )
    .sheet(
      isPresented: $showsManualJourney,
      onDismiss: {
        Task { await model.load() }
      },
      content: {
        JourneyRecordingView(environment: environment, initialPlan: nil)
      }
    )
    .sheet(
      item: $expenseJourney,
      onDismiss: {
        Task { await model.load() }
      },
      content: { journey in
        JourneyExpenseView(journey: journey, environment: environment) {
          expenseJourney = nil
        }
      }
    )
  }

  private func planActionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Image(systemName: systemImage)
        Text(title)
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func reminderTitle(_ status: DepartureReminderStatus) -> String {
    switch status {
    case .scheduled: "已向系统调度提醒"
    case .authorizationDenied: "通知未授权"
    case .failed: "提醒失败"
    case .disabled, .cancelled: "未启用提醒"
    case .notRequested: "提醒待调度"
    }
  }

  private func journeyTitle(_ status: JourneyStatus) -> String {
    switch status {
    case .recording: "正在记录"
    case .paused: "已暂停"
    case .finalizing: "正在生成摘要"
    case .reviewing: "摘要待确认"
    case .completed: "已完成行程"
    case .discarded: "已丢弃"
    }
  }

  private func transportTitle(_ mode: TripTransportMode) -> String {
    switch mode {
    case .walking: "步行"
    case .driving: "驾车"
    case .transit: "公交"
    }
  }
}
