import SwiftUI

struct WearEventView: View {
  @Bindable var model: WearEventEditorModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    NavigationStack {
      Group {
        if model.isEditing { editor }
        else { detail }
      }
      .navigationTitle(model.isEditing ? String(localized: "记录实际穿着") : String(localized: "实际穿着"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.isEditing ? "取消" : "关闭") {
            if model.isEditing { model.confirmsDiscard = true } else { dismiss() }
          }.disabled(model.isWorking)
        }
        if model.isEditing {
          ToolbarItem(placement: .confirmationAction) {
            Button("实际穿了") { model.submit(.save) }.disabled(model.isWorking)
          }
        }
      }
      .interactiveDismissDisabled(model.isEditing || model.isWorking)
      .task { await model.load() }
      .task(id: model.request) { if model.request > 0 { await model.perform() } }
      .onChange(of: model.finished) { _, finished in if finished { dismiss() } }
      .confirmationDialog("放弃未保存的实际记录？", isPresented: $model.confirmsDiscard,
        titleVisibility: .visible) {
        Button("放弃修改", role: .destructive) { dismiss() }
      }
      .confirmationDialog("永久删除这条实际穿着？", isPresented: $model.confirmsDelete,
        titleVisibility: .visible) {
        Button("确认删除记录", role: .destructive) { model.submit(.delete) }
      } message: {
        Text("穿着次数会重新计算；衣物当前状态和原计划都会保留。")
      }
      .confirmationDialog("可能已经记录过这次穿着", isPresented: duplicateBinding,
        titleVisibility: .visible) {
        Button("查看旧记录") { model.previewDuplicate() }
        Button("仍是另一次穿着") { model.confirmDuplicate() }
        Button("返回修改", role: .cancel) { model.cancelDuplicate() }
      } message: {
        Text("同一天已有高度相似的实际单品。确认后会再检查旧记录是否变化。")
      }
      .sheet(item: $model.duplicatePreview) { DuplicateWearEventPreview(event: $0) }
    }
    .accessibilityHidden(scenePhase != .active)
    .overlay {
      if scenePhase != .active {
        ZStack {
          Color(.systemBackground).ignoresSafeArea()
          Label("内容已隐藏", systemImage: "lock.shield")
        }.accessibilityElement(children: .combine)
      }
    }
  }

  private var duplicateBinding: Binding<Bool> {
    $model.showsDuplicateConfirmation
  }

  private var editor: some View {
    Form {
      if let error = model.error {
        Section { Text(error).accessibilityIdentifier("wear.error"); Button("刷新并复核") { model.submit(.refresh) } }
      }
      Section("发生时间") {
        DatePicker("实际日期", selection: $model.date, in: ...model.latestDate, displayedComponents: .date)
          .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
          .accessibilityIdentifier("wear.date")
        Picker("记录完整度", selection: $model.completeness) {
          Text("部分记录").tag(WearEventCompleteness.partial)
          Text("整套已记录").tag(WearEventCompleteness.complete)
        }
        Text("默认是部分记录，不会自动补齐未知单品。").font(.footnote)
        TextField("场景（可选）", text: $model.summary, axis: .vertical).lineLimit(1...4)
        Text("原始时区：\(model.timeZone)").font(.footnote)
      }
      if model.isSourcePlanStale {
        Section { Label("原计划已修改，本页仍保留确认当时的来源版本。", systemImage: "exclamationmark.triangle") }
      }
      if !model.missingIDs.isEmpty {
        Section("需要处理的单品") {
          Text("原记录中的单品已删除。请移除它，或选择其他真实衣物。")
          Button("移除已删除的单品") {
            let missing = Set(model.missingIDs); model.selected.removeAll { missing.contains($0) }
          }
        }
      }
      if !model.duplicateCandidates.isEmpty && !model.showsDuplicateConfirmation {
        Section("可能重复") {
          Button("继续处理可能重复的记录") { model.showsDuplicateConfirmation = true }
        }
      }
      Section("选择实际穿着（\(model.selected.count)/20）") {
        Picker("选衣类别", selection: $model.choiceCategory) {
          Text("全部类别").tag(Optional<WardrobeCategory>.none)
          ForEach(categoryOrder, id: \.self) { Text($0.title).tag(Optional($0)) }
        }.pickerStyle(.menu)
        if model.visibleChoices.isEmpty { Text("这个类别还没有衣物。") }
        ForEach(model.visibleChoices) { item in
          Button { model.toggle(item) } label: {
            HStack {
              OutfitItemThumbnail(itemID: item.id, assetID: nil, revision: item.revision,
                model: model.thumbnail(), side: 48)
              VStack(alignment: .leading) {
                Text(item.input.name)
                Text("\(item.input.category.title) · \(item.input.availability.title)").font(.caption)
              }
              Spacer()
              Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
            }.foregroundStyle(Color.primary).frame(minHeight: 44)
          }.buttonStyle(.plain)
        }
      }
      if !model.selectedChoices.isEmpty {
        Section("穿后状态") {
          Text("默认保持当前状态；删除或纠正记录也不会自动恢复衣物状态。")
            .font(.footnote)
          ForEach(model.selectedChoices) { item in
            Toggle("\(item.input.name) · 标为待洗", isOn: Binding(
              get: { model.laundry.contains(item.id) },
              set: { model.setLaundry(item, enabled: $0) }))
          }
        }
      }
      if !model.unavailable.isEmpty {
        Section("当前状态有变化") {
          Text(model.unavailable.map { "\($0.input.name) · \($0.input.availability.title)" }.joined(separator: "、"))
          Toggle("已确认这是过去发生的实际穿着", isOn: $model.confirmsUnavailable)
        }
      }
      if model.isWorking { Section { ProgressView("正在保存实际穿着…") } }
    }
    .scrollEdgeEffectStyle(.hard, for: .all)
    .accessibilityIdentifier("wear.form")
  }

  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let error = model.error { card { Text(error); Button("重试") { model.submit(.refresh) } } }
        if model.isDeleted { card { Text("这条实际穿着已删除") } }
        else if let event = model.event {
          card {
            Text(event.completeness == .complete ? "整套已记录" : "部分记录").font(.headline)
            Text(event.localDate.value)
            Text(sourceTitle(event.sourceKind)).font(.subheadline)
            if let summary = event.contextSummary { Text(summary) }
            Text("原始时区：\(event.timeZone)").font(.footnote)
          }
          card {
            Text("实际单品").font(.headline)
            ForEach(event.items) { snapshot in
              if let item = snapshot.content {
                HStack {
                  if let assetID = item.photoAssetID {
                    OutfitItemThumbnail(itemID: item.itemID, assetID: assetID, revision: event.revision,
                      model: model.thumbnail())
                  }
                  Text(item.input.name)
                }
              } else { Label("已删除的单品", systemImage: "minus.circle") }
            }
          }
          card {
            Button("纠正记录") { model.submit(.edit) }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Button("删除实际记录", role: .destructive) { model.confirmsDelete = true }
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Text("删除后会重新计算穿着次数，衣物当前状态保持不变。").font(.footnote)
          }
        }
        if model.isWorking { ProgressView("正在读取实际穿着…") }
      }.padding(20)
    }.background(Color(.systemGroupedBackground))
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
  }

  private var categoryOrder: [WardrobeCategory] {
    [.top, .outerwear, .bottom, .onePiece, .shoes, .bag, .accessory]
  }

  private func sourceTitle(_ kind: WearEventSourceKind) -> LocalizedStringKey {
    switch kind {
    case .followedPlan: "按计划穿了"
    case .changedPlan: "换了几件"
    case .differentOutfit: "穿了别套"
    case .unplanned: "无计划补录"
    }
  }
}

private struct DuplicateWearEventPreview: View {
  let event: WearEvent
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section("旧记录") {
          Text(event.localDate.value)
          Text(event.completeness == .complete ? "整套已记录" : "部分记录")
          if let summary = event.contextSummary { Text(summary) }
        }
        Section("实际单品") {
          ForEach(event.items) { item in
            Text(item.content?.input.name ?? String(localized: "已删除的单品"))
          }
        }
      }
      .navigationTitle("查看旧记录")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
  }
}
