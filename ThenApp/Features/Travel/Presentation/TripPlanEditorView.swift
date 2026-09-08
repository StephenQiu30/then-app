import SwiftUI

struct TripPlanEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: TripPlanEditorViewModel
  private let onSaved: @MainActor () -> Void

  init(
    environment: AppEnvironment,
    seed: TripPlanEditorSeed,
    onSaved: @escaping @MainActor () -> Void = {}
  ) {
    self.onSaved = onSaved
    _model = State(
      initialValue: TripPlanEditorViewModel(
        ownerID: environment.localLedgerIdentity.profileID,
        service: environment.tripPlanning,
        seed: seed
      )
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        planSection
        originSection
        destinationSection
        routeSection
        messageSection
      }
      .navigationTitle(model.isAdoptingRevision ? "确认来源变化" : "出行计划")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(model.isAdoptingRevision ? "采用" : "保存") {
            Task { await model.save() }
          }
          .disabled(!model.canSave)
        }
      }
      .onChange(of: model.savedResult) { _, result in
        if result != nil {
          onSaved()
          dismiss()
        }
      }
    }
  }

  private var planSection: some View {
    Section("计划") {
      if model.isAdoptingRevision {
        Text("请逐项确认采用后的计划。目的地必须重新确认，旧路线不会自动沿用。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      TextField(
        "计划名称（可选）",
        text: Binding(
          get: { model.displayName },
          set: { model.updateDisplayName($0) }
        )
      )
      DatePicker(
        "目标到达",
        selection: Binding(
          get: { model.targetArrivalAt },
          set: { model.updateTargetArrival($0) }
        )
      )
      Picker(
        "交通方式",
        selection: Binding(
          get: { model.transportMode },
          set: { model.updateTransportMode($0) }
        )
      ) {
        ForEach(TripTransportMode.allCases) { mode in
          Text(transportTitle(mode)).tag(mode)
        }
      }
      if !model.hasConfirmedAllDayTime {
        Text("全天事件没有具体时刻。请调整上方时间，或明确确认当前显示的时间。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("确认具体到达时间") {
          model.confirmAllDayArrivalTime()
        }
      }
    }
  }

  private var originSection: some View {
    Section("起点（路线可选）") {
      TextField("输入起点", text: $model.originQuery)
      Button("搜索起点", systemImage: "magnifyingglass") {
        Task { await model.searchOrigin() }
      }
      .disabled(model.isSearchingOrigin)
      if model.isSearchingOrigin { ProgressView() }
      if let selected = model.selectedOrigin {
        Label(selected.name, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      ForEach(model.originCandidates) { candidate in
        Button {
          model.selectOrigin(candidate)
        } label: {
          candidateLabel(candidate)
        }
      }
    }
  }

  private var destinationSection: some View {
    Section("目的地") {
      TextField("输入目的地或地址", text: $model.destinationQuery)
      Button("搜索目的地", systemImage: "magnifyingglass") {
        Task { await model.searchDestination() }
      }
      .disabled(model.isSearchingDestination)
      if model.isSearchingDestination { ProgressView() }
      if let selected = model.selectedDestination {
        Label(selected.name, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      ForEach(model.destinationCandidates) { candidate in
        Button {
          model.selectDestination(candidate)
        } label: {
          candidateLabel(candidate)
        }
      }
      Button("搜索不到，使用当前文字地址") {
        model.useManualDestination()
      }
    }
  }

  private var routeSection: some View {
    Section("路线与出发") {
      Button(
        "使用 MapKit 计算路线",
        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
      ) {
        Task { await model.calculateRoute() }
      }
      .disabled(!model.canCalculateRoute)
      if model.isCalculatingRoute {
        ProgressView("正在计算路线")
      }
      if let route = model.routeEstimate {
        LabeledContent("预计耗时", value: duration(route.expectedTravelSeconds))
        LabeledContent("距离", value: distance(route.distanceMeters))
        LabeledContent(
          "计算时间",
          value: route.calculatedAt.formatted(date: .omitted, time: .shortened)
        )
        LabeledContent(
          "新鲜至",
          value: route.expiresAt.formatted(date: .omitted, time: .shortened)
        )
      } else {
        Text("没有路线也可以保存；请直接确认下面的手动出发时间。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Stepper(
        "准备缓冲：\(model.preparationBufferMinutes) 分钟",
        value: Binding(
          get: { model.preparationBufferMinutes },
          set: { model.updateBufferMinutes($0) }
        ),
        in: 0...120,
        step: 5
      )
      DatePicker(
        "计划出发",
        selection: Binding(
          get: { model.plannedDepartureAt },
          set: { model.updateDeparture($0) }
        )
      )
      Toggle("安排普通本地提醒", isOn: $model.reminderEnabled)
        .disabled(!model.hasConfirmedAllDayTime)
    }
  }

  @ViewBuilder
  private var messageSection: some View {
    if let error = model.errorMessage {
      Section {
        Label {
          Text(error)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
      }
    } else if let status = model.statusMessage {
      Section {
        Label(status, systemImage: "checkmark.circle")
      }
    }
  }

  private func candidateLabel(_ candidate: PlaceCandidate) -> some View {
    VStack(alignment: .leading) {
      Text(candidate.name)
      if let address = candidate.address {
        Text(address).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func transportTitle(_ mode: TripTransportMode) -> String {
    switch mode {
    case .walking: "步行"
    case .driving: "驾车"
    case .transit: "公共交通"
    }
  }

  private func duration(_ seconds: TimeInterval) -> String {
    "\(Int((seconds / 60).rounded())) 分钟"
  }

  private func distance(_ meters: Double) -> String {
    if meters >= 1_000 { return String(format: "%.1f 公里", meters / 1_000) }
    return "\(Int(meters.rounded())) 米"
  }
}
