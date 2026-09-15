import SwiftUI

struct OutfitPlanView: View {
  @Bindable var model: OutfitPlanViewModel
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    List {
      if let error = model.error {
        Section { Text(error); Button("重试") { model.reload() } }
      }
      if model.timelineEntries.isEmpty && !model.isLoading && model.error == nil {
        ContentUnavailableView("还没有穿搭记录", systemImage: "book.closed",
          description: Text("可以安排未来穿搭，也可以补记今天或过去的实际穿着。"))
      }
      ForEach(Array(Set(model.timelineEntries.map(\.localDate))).sorted(by: >), id: \.self) { day in
        Section {
          ForEach(model.timelineEntries.filter { $0.localDate == day }) { entry in
            switch entry {
            case .plan(let plan): planRow(plan)
            case .wear(let event): wearRow(event)
            }
          }
        } header: { Text(day.value).foregroundStyle(Color.primary) }
      }
      if model.isLoading { ProgressView("正在读取计划…") }
      if model.hasMore { Button("加载更早的记录") { model.loadMore() }.disabled(model.isLoading) }
    }
    .scrollEdgeEffectStyle(.hard, for: .all)
    .navigationTitle("穿搭簿")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("记录实际穿着", systemImage: "checkmark.circle") { model.recordActual() }
      }
      ToolbarItem(placement: .primaryAction) { Button("新建计划", systemImage: "plus") { model.open() } }
    }
    .task(id: model.request) { await model.load() }
    .onChange(of: scenePhase) { _, phase in if phase == .active { model.reload() } }
    .refreshable { model.nextPage = false; await model.load() }
    .sheet(item: $model.editor, onDismiss: { model.reload() }) { draft in
      OutfitPlanEditorView(draft: draft)
    }
    .sheet(item: $model.wearEditor, onDismiss: { model.reload() }) { draft in WearEventView(model: draft) }
  }

  private func planRow(_ plan: OutfitPlan) -> some View {
    Button { model.open(plan) } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text(plan.contextSummary ?? String(localized: "穿搭计划")).font(.headline)
        Text(plan.items.map { $0.content?.input.name ?? String(localized: "已删除的单品") }.joined(separator: " · "))
          .font(.body).fixedSize(horizontal: false, vertical: true)
        Text(planStatusTitle(plan.status)).font(.caption)
      }.foregroundStyle(Color.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }.accessibilityHint("查看穿搭计划")
  }

  private func wearRow(_ event: WearEvent) -> some View {
    Button { model.open(event) } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text(event.contextSummary ?? String(localized: "实际穿着")).font(.headline)
        Text(event.items.map { $0.content?.input.name ?? String(localized: "已删除的单品") }.joined(separator: " · "))
          .font(.body).fixedSize(horizontal: false, vertical: true)
        Text(event.completeness == .complete ? String(localized: "实际穿着 · 整套已记录")
          : String(localized: "实际穿着 · 部分记录")).font(.caption)
      }.foregroundStyle(Color.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }.accessibilityHint("查看实际穿着")
  }
}

struct OutfitPlanEditorView: View {
  @Bindable var draft: OutfitPlanEditorModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var summaryFocused
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    NavigationStack {
      Group {
        if draft.isEditing {
          Form {
            if draft.error != nil { Section { errorContent } }
            if draft.isDeleted { Section { Text("计划内容已删除") } }
            else { editing }
            if draft.isWorking { ProgressView("正在处理计划…") }
          }
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 20) {
                if draft.error != nil { contentCard { errorContent } }
                if draft.isDeleted { contentCard { Text("计划内容已删除") } }
                else if let plan = draft.plan { detail(plan) }
                if draft.isWorking { ProgressView("正在处理计划…") }
              }
              .id("outfit.detail.top")
              .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: draft.plan?.status) { previous, current in
              guard previous != current, current == .cancelled else { return }
              proxy.scrollTo("outfit.detail.top", anchor: .top)
            }
          }
        }
      }
      .accessibilityIdentifier("outfit.form")
      .scrollEdgeEffectStyle(.hard, for: .all)
      .navigationBarTitleDisplayMode(.inline)
      .navigationTitle(draft.isEditing ? (draft.plan == nil ? String(localized: "新建计划") : String(localized: "编辑计划")) : String(localized: "穿搭计划"))
      .safeAreaInset(edge: .top, spacing: 0) {
        if draft.isEditing && !dynamicTypeSize.isAccessibilitySize && !draft.selectedChoices.isEmpty {
          selectedTray
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(draft.isEditing ? "取消" : "关闭") {
            if draft.isEditing { draft.confirmsDiscard = true } else { dismiss() }
          }.disabled(draft.isWorking)
        }
        if draft.isEditing {
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { draft.submit(.save) }.disabled(draft.isWorking)
          }
        }
      }
      .interactiveDismissDisabled(draft.isEditing || draft.isWorking)
      .confirmationDialog("放弃未保存的计划？", isPresented: $draft.confirmsDiscard, titleVisibility: .visible) {
        Button("放弃修改", role: .destructive) { dismiss() }
      }
      .confirmationDialog("取消这个计划？", isPresented: $draft.confirmsCancel, titleVisibility: .visible) {
        Button("确认取消计划", role: .destructive) { draft.submit(.cancel) }
      } message: { Text("保留计划内容，不会记为实际穿着。") }
      .confirmationDialog("确认最后没有穿这套？", isPresented: $draft.confirmsNotWorn, titleVisibility: .visible) {
        Button("确认没穿", role: .destructive) { draft.submit(.markNotWorn) }
      } message: { Text("不会创建实际记录，也不会增加穿着次数。") }
      .confirmationDialog("永久删除这个计划？", isPresented: $draft.confirmsDelete, titleVisibility: .visible) {
        Button("确认删除计划", role: .destructive) { draft.submit(.delete) }
      } message: { Text("计划与单品快照将被清除，衣橱中的衣物和照片仍保留。") }
      .task { await draft.load() }
      .task(id: draft.request) { if draft.request > 0 { await draft.perform() } }
      .onChange(of: draft.finished) { _, finished in if finished { dismiss() } }
      .sheet(item: $draft.wearEditor, onDismiss: { draft.submit(.refresh) }) { WearEventView(model: $0) }
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
    .onChange(of: scenePhase) { _, phase in if phase != .active { summaryFocused = false } }
  }

  @ViewBuilder private var errorContent: some View {
    if let error = draft.error {
      Text(error).accessibilityIdentifier("outfit.error")
      if draft.isDeleted { Button("重试清理") { draft.submit(.delete) } }
      else { Button("刷新并复核") { draft.submit(.refresh) } }
    }
  }

  private func contentCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 16, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
  }

  private var editing: some View {
    Group {
      Section {
        sectionHeading(Text("安排"))
        dateSelection
          .environment(\.calendar, draft.calendar)
          .environment(\.timeZone, draft.calendar.timeZone)
        if draft.isPast { Text("过去的计划可保留原日期；更改日期须选择今天或未来。").font(.footnote) }
        VStack(alignment: .leading, spacing: 8) {
          Text("场景（可选）")
          TextField("", text: $draft.summary, axis: .vertical)
            .accessibilityLabel("场景（可选）")
            .lineLimit(1...4).frame(minHeight: 44).submitLabel(.done).focused($summaryFocused)
            .accessibilityIdentifier("outfit.summary")
          Text("最多 120 字").font(.footnote)
        }.foregroundStyle(Color.primary)
        Text("原始时区：\(draft.timeZone)").font(.footnote)
      }
      if dynamicTypeSize.isAccessibilitySize && !draft.selectedChoices.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 16) {
            sectionHeading(Text("已选单品（\(draft.selected.count)）"))
            ForEach(draft.selectedChoices) { item in selectedItem(item).foregroundStyle(Color.primary) }
          }
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      if draft.removedPlaceholders > 0 || !draft.missingIDs.isEmpty {
        Section {
          sectionHeading(Text("需要移除的单品"))
          Text("部分单品已删除，请移除占位或选择其他衣物后保存。")
          Button("移除已删除的单品") {
            let missing = Set(draft.missingIDs)
            draft.selected.removeAll { missing.contains($0) }; draft.removedPlaceholders = 0
          }
        }
      }
      Section {
        sectionHeading(Text("选择衣物（\(draft.selected.count)/20）"))
        Picker("选衣类别", selection: $draft.choiceCategory) {
          Text("全部类别").tag(Optional<WardrobeCategory>.none)
          ForEach(choiceCategoryOrder, id: \.self) { category in
            Text(category.title).tag(Optional(category))
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("outfit.choice.category")
        if draft.choices.isEmpty { Text("衣橱里还没有衣物，请先添加一件。") }
        else if draft.visibleChoices.isEmpty { Text("这个类别还没有衣物。") }
        ForEach(choiceCategoryOrder.filter { category in
          draft.visibleChoices.contains { $0.input.category == category }
        }, id: \.self) { category in
          VStack(alignment: .leading, spacing: 12) {
            sectionHeading(Text(category.title))
            LazyVGrid(columns: choiceColumns, alignment: .leading, spacing: 16) {
              ForEach(draft.visibleChoices.filter { $0.input.category == category }) { item in
                choiceCard(item)
              }
            }
          }
        }
      }
      if draft.hasChanges { Section { Toggle("已复核变化，按当前衣物保存", isOn: $draft.confirmsChanges) } }
      if !draft.unavailable.isEmpty {
        Section {
          Text(draft.unavailable.map { $0.input.name + " · " + $0.input.availability.title }.joined(separator: "、"))
          Toggle("仍将这些当前不可穿的衣物安排进计划", isOn: $draft.confirmsUnavailable)
        }
      }
    }.disabled(draft.isWorking)
  }

  private var choiceCategoryOrder: [WardrobeCategory] {
    [.top, .outerwear, .bottom, .onePiece, .shoes, .bag, .accessory]
  }

  private var dateSelection: some View {
    // Measure the native field instead of replacing its label at a font-size threshold.
    ViewThatFits(in: .horizontal) {
      DatePicker("穿搭日期", selection: $draft.date, displayedComponents: .date)
      VStack(alignment: .leading, spacing: 8) {
        Text("穿搭日期").fixedSize(horizontal: false, vertical: true)
        DatePicker("穿搭日期", selection: $draft.date, displayedComponents: .date)
          .datePickerStyle(.graphical).labelsHidden()
      }
    }
  }

  private var choiceColumns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible())] }
    return [GridItem(.adaptive(minimum: dynamicTypeSize >= .xxLarge ? 140 : 72), spacing: 12, alignment: .top)]
  }

  private func choiceCard(_ item: WardrobeItem) -> some View {
    Button { summaryFocused = false; draft.toggle(item) } label: {
      VStack(alignment: .leading, spacing: 8) {
        OutfitItemThumbnail(itemID: item.id, assetID: nil, revision: item.revision,
          model: draft.thumbnail(), side: dynamicTypeSize.isAccessibilitySize ? 100 : 64)
          .frame(maxWidth: .infinity)
          .overlay(alignment: .topTrailing) { selectionMark(item) }
        choiceText(item)
      }
      .foregroundStyle(Color.primary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.input.name + ", " + item.input.category.title + ", " + item.input.availability.title)
    .accessibilityValue(draft.selected.contains(item.id) ? String(localized: "已选择") : String(localized: "未选择"))
  }

  private var selectedTray: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("已选单品（\(draft.selected.count)）").font(.headline).accessibilityAddTraits(.isHeader)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(draft.selectedChoices) { item in selectedItem(item).frame(width: 112) }
        }
      }.scrollIndicators(.hidden)
    }
    .padding(16)
    .foregroundStyle(Color.white)
    .background(Color.black, in: RoundedRectangle(cornerRadius: 24))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("outfit.selected.tray")
    .padding(.horizontal, 16).padding(.vertical, 8)
    .background(Color(.systemGroupedBackground))
    .disabled(draft.isWorking)
  }

  private func selectedItem(_ item: WardrobeItem) -> some View {
    Button { draft.toggle(item) } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          OutfitItemThumbnail(itemID: item.id, assetID: nil, revision: item.revision,
            model: draft.thumbnail(), side: 40)
          Spacer(minLength: 0)
          Image(systemName: "xmark.circle.fill").accessibilityHidden(true)
        }
        Text(item.input.name).font(.caption).fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("移除已选单品：\(item.input.name)")
    .accessibilityIdentifier("outfit.selected.remove.\(item.id.uuidString)")
  }

  private func sectionHeading(_ title: Text) -> some View {
    title.font(.headline).foregroundStyle(Color.primary)
      .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
  }

  private func choiceText(_ item: WardrobeItem) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.input.name)
      Text("\(item.input.category.title) · \(item.input.availability.title)").font(.caption)
      if let summary = item.input.attributes.confirmedSummary {
        Text(summary).font(.caption)
        Text("由你确认").font(.caption2)
      }
      if draft.changedIDs.contains(item.id) { Text("与原计划或上次查看时不同").font(.caption) }
    }.fixedSize(horizontal: false, vertical: true)
  }

  private func selectionMark(_ item: WardrobeItem) -> some View {
    Image(systemName: draft.selected.contains(item.id) ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
  }

  @ViewBuilder private func detail(_ plan: OutfitPlan) -> some View {
    contentCard {
      sectionHeading(Text("安排"))
      Text(plan.localDate.value)
      Text("原始时区：\(plan.timeZone)").font(.footnote)
      if let summary = plan.contextSummary { Text(summary) }
      Text(planStatusTitle(plan.status))
      Text("计划不代表实际穿着。").font(.footnote)
    }
    contentCard {
      sectionHeading(Text("保存时的单品"))
      ForEach(plan.items) { item in
        if let content = item.content {
          let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
          layout {
            if let assetID = content.photoAssetID {
              OutfitItemThumbnail(itemID: content.itemID, assetID: assetID, revision: plan.revision, model: draft.thumbnail())
            }
            VStack(alignment: .leading) {
              Text(content.input.name)
              Text("\(content.input.category.title) · \(content.input.availability.title)").font(.caption)
              if let summary = content.input.attributes.confirmedSummary {
                Text(summary).font(.caption)
                Text("保存时由你确认").font(.caption2)
              } else {
                Text("保存时属性未知").font(.caption2)
              }
            }.fixedSize(horizontal: false, vertical: true)
          }
        } else { Label("已删除的单品", systemImage: "minus.circle") }
      }
    }
    contentCard {
      if plan.status == .active {
        if draft.canRecordActual {
          Button { draft.recordActual(.followedPlan) } label: { detailAction(Text("按计划穿了")) }
          Button { draft.recordActual(.changedPlan) } label: { detailAction(Text("换了几件")) }
          Button { draft.recordActual(.differentOutfit) } label: { detailAction(Text("穿了别套")) }
          Button(role: .destructive) { draft.confirmsNotWorn = true } label: { detailAction(Text("最后没穿")) }
        }
        Button { draft.submit(.edit) } label: { detailAction(Text("编辑计划")) }
        Button(role: .destructive) { draft.confirmsCancel = true } label: { detailAction(Text("取消计划")) }
      }
      if plan.status == .notWorn {
        Button { draft.submit(.restoreActive) } label: { detailAction(Text("撤销未穿")) }
      }
      Button(role: .destructive) { draft.confirmsDelete = true } label: { detailAction(Text("删除计划")) }
    }.disabled(draft.isWorking)
  }

  private func detailAction(_ text: Text) -> some View {
    text.foregroundStyle(Color.primary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
  }
}

private func planStatusTitle(_ status: OutfitPlanStatus) -> LocalizedStringKey {
  switch status {
  case .active: "计划中"
  case .completed: "已有实际穿着"
  case .notWorn: "未穿"
  case .cancelled: "已取消"
  }
}

struct OutfitItemThumbnail: View {
  let itemID: UUID
  let assetID: UUID?
  let revision: Int
  private struct Request: Hashable { let itemID: UUID; let assetID: UUID?; let revision: Int; let active: Bool }
  @State var model: WardrobeThumbnailViewModel
  var side: CGFloat = 56
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      Color(.secondarySystemBackground)
      if let image = model.image { image.resizable().scaledToFit() }
      else {
        Image(systemName: "tshirt").resizable().scaledToFit()
          .padding(side * 0.2).foregroundStyle(Color.primary)
      }
    }
    .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    .task(id: Request(itemID: itemID, assetID: assetID, revision: revision, active: scenePhase == .active)) {
      if scenePhase == .active { await model.load(itemID: itemID, expectedAssetID: assetID) }
      else { model.clear() }
    }
    .onChange(of: scenePhase) { _, phase in if phase != .active { model.clear() } }
    .onDisappear { model.clear() }
  }
}
