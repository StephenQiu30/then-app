import SwiftUI

struct CalendarView: View {
  private let environment: AppEnvironment
  @State private var model: CalendarViewModel
  @State private var editorSeed: TripPlanEditorSeed?
  @State private var revisionOccurrence: CalendarOccurrenceSummary?

  init(environment: AppEnvironment) {
    self.environment = environment
    _model = State(initialValue: CalendarViewModel(calendarImport: environment.calendarImport))
  }

  var body: some View {
    NavigationStack {
      Group {
        if model.isLoading, model.sources.isEmpty {
          ProgressView("正在读取日历状态")
        } else {
          content
        }
      }
      .navigationTitle("日程")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink {
            TripPlanListView(environment: environment)
          } label: {
            Label("出行计划", systemImage: "figure.walk.departure")
          }
        }
        if model.authorizationState == .fullAccess {
          ToolbarItem(placement: .primaryAction) {
            Button("更新日程", systemImage: "arrow.clockwise") {
              Task { await model.scan() }
            }
            .disabled(model.isScanning || !model.hasSelectedSources)
          }
        }
      }
      .overlay {
        if model.isScanning {
          ProgressView("正在更新选中日历")
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
      }
      .task {
        await model.load()
      }
      .task {
        await model.observeEventStoreChanges()
      }
      .refreshable {
        await model.load()
        if model.hasSelectedSources {
          await model.scan()
        }
      }
      .sheet(item: $editorSeed) { seed in
        TripPlanEditorView(environment: environment, seed: seed) {
          Task { await model.load() }
        }
      }
      .sheet(item: $revisionOccurrence) { occurrence in
        CalendarRevisionReviewView(environment: environment, occurrence: occurrence) {
          Task { await model.load() }
        }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.authorizationState {
    case .notDetermined:
      ScrollView {
        VStack(spacing: 16) {
          Image(systemName: "calendar.badge.plus")
            .font(.largeTitle)
            .accessibilityHidden(true)
          Text("连接系统日历")
            .font(.title2.bold())
          Text("于是会请求 iOS 的日历完整访问，但只读取你随后明确选择的日历、时间、标题和地点。")
            .multilineTextAlignment(.center)
          Button("继续并请求访问") {
            Task { await model.requestAccess() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isRequestingAccess)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
      }
      .modifier(AdaptiveHardScrollEdgeEffectModifier())
    case .denied, .restricted, .writeOnly:
      ScrollView {
        VStack(spacing: 16) {
          Image(systemName: "calendar.badge.exclamationmark")
            .font(.largeTitle)
            .accessibilityHidden(true)
          Text("日历访问未开启")
            .font(.title2.bold())
          permissionDescription
            .multilineTextAlignment(.center)
          Button("重新检查") {
            Task { await model.load() }
          }
          .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
      }
      .modifier(AdaptiveHardScrollEdgeEffectModifier())
    case .fullAccess:
      calendarContent
    }
  }

  private var calendarContent: some View {
    List {
      Section {
        if model.sources.isEmpty {
          ContentUnavailableView(
            "没有可用日历",
            systemImage: "calendar",
            description: Text("系统日历中暂时没有可供选择的事件日历。")
          )
        } else {
          ForEach(model.sources) { source in
            Toggle(
              isOn: Binding(
                get: { source.isSelected },
                set: { isSelected in
                  Task { await model.setSourceSelection(source, isSelected: isSelected) }
                }
              )
            ) {
              VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                Text(sourceSubtitle(source))
                  .font(.caption)
                  .foregroundStyle(.primary)
              }
            }
            .disabled(!source.isAvailable || model.isScanning)
          }
        }
      } header: {
        Text("日历来源")
          .foregroundStyle(.primary)
      } footer: {
        Text("新来源默认关闭。取消选择只停止跟踪，不会把已有事件标记为删除。")
          .foregroundStyle(.primary)
      }

      if let errorMessage = model.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      } else if let scanMessage = model.scanMessage {
        Section {
          Label(scanMessage, systemImage: "checkmark.circle")
            .foregroundStyle(.primary)
        }
      }

      Section("窗口内事件") {
        if !model.hasSelectedSources {
          ContentUnavailableView(
            "选择要读取的日历",
            systemImage: "checklist",
            description: Text("选择后点击右上角更新；于是不会自动勾选节假日或订阅日历。")
          )
        } else if model.occurrences.isEmpty {
          ContentUnavailableView(
            "窗口内没有事件",
            systemImage: "calendar",
            description: Text("显示过去 30 天至未来 90 天；下拉或点击更新可重新扫描。")
          )
        } else {
          ForEach(model.occurrences) { occurrence in
            occurrenceRow(occurrence)
          }
        }
      }
    }
    .headerProminence(.increased)
    .modifier(AdaptiveHardScrollEdgeEffectModifier())
  }

  private func occurrenceRow(_ occurrence: CalendarOccurrenceSummary) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(occurrence.title ?? "未命名事件")
        Spacer()
        if occurrence.hasPendingRevision {
          Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(.orange)
            .accessibilityLabel("来源已变化")
        }
      }
      Text(occurrenceTime(occurrence))
        .font(.subheadline)
        .foregroundStyle(.primary)
      if let location = occurrence.locationText {
        Label(location, systemImage: "mappin.and.ellipse")
          .font(.caption)
          .foregroundStyle(.primary)
      }
      HStack {
        Text(occurrence.sourceTitle)
        if occurrence.sourceState != .active {
          Text("· \(sourceStateTitle(occurrence.sourceState))")
        }
      }
      .font(.caption)
      .foregroundStyle(.primary)
      if occurrence.sourceState == .active || occurrence.sourceState == .missing {
        if occurrence.hasPendingRevision {
          Button("查看来源变化", systemImage: "arrow.triangle.2.circlepath") {
            revisionOccurrence = occurrence
          }
          .buttonStyle(.borderless)
        }
        if occurrence.linkedPlanCount == 0 {
          Button("创建出行计划", systemImage: "arrow.right.circle") {
            editorSeed = TripPlanEditorSeed(occurrence: occurrence)
          }
          .buttonStyle(.borderless)
        } else {
          Label("已关联出行计划", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var permissionDescription: some View {
    switch model.authorizationState {
    case .denied:
      Text("你拒绝了日历完整访问。已有缓存不会被误判为删除，记账仍可正常使用。")
    case .restricted:
      Text("系统限制了日历访问。已有缓存保持原状态，记账仍可正常使用。")
    case .writeOnly:
      Text("iOS 只授予了写入权限；于是不会写系统事件，也无法读取日程。")
    case .notDetermined, .fullAccess:
      EmptyView()
    }
  }

  private func sourceSubtitle(_ source: CalendarSourceSummary) -> String {
    if !source.isAvailable { return "暂不可用" }
    if source.isSubscribed { return "订阅日历，需手动选择" }
    return source.allowsContentModifications ? "可编辑来源（于是只读）" : "只读来源"
  }

  private func occurrenceTime(_ occurrence: CalendarOccurrenceSummary) -> String {
    if occurrence.isAllDay {
      return "全天 · \(occurrence.localStartDate)"
    }
    return
      "\(occurrence.startsAt.formatted(date: .abbreviated, time: .shortened)) · \(occurrence.timeZoneIdentifier)"
  }

  private func sourceStateTitle(_ state: CalendarOccurrenceSourceState) -> String {
    switch state {
    case .active:
      "有效"
    case .missing:
      "暂未发现"
    case .sourceDeleted:
      "来源已删除"
    case .outOfWindow:
      "已移出窗口"
    case .cancelled:
      "已取消"
    case .ambiguous:
      "需要确认"
    }
  }
}
