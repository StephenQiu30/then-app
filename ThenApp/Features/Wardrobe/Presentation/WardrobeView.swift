import SwiftUI

struct WardrobeView: View {
  @Bindable var model: WardrobeViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if model.items.isEmpty {
        ContentUnavailableView(
          "你的衣橱", systemImage: "cabinet",
          description: Text("添加你确认拥有的衣物，无需照片。")
            .foregroundStyle(Color.primary)
        )
      } else {
        wardrobeGrid
      }
    }
    .navigationTitle("衣橱")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("添加衣物", systemImage: "plus") { model.beginAdding(source: .wardrobe) }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if model.photoCleanupPending {
        VStack {
          Text("照片已隐藏或替换，旧文件清理待完成。")
          Button("重试照片清理") { model.requestPhotoCleanup() }.disabled(model.isCleaningPhotos)
        }
        .padding().background(.background)
      }
    }
    .task(id: model.cleanupRequest) {
      if model.cleanupRequest > 0 { await model.retryPhotoCleanup() }
    }
    .sheet(item: $model.editor) { draft in
      WardrobeEditorView(draft: draft, model: model)
    }
  }

  private var wardrobeGrid: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          TextField("搜索衣物名称", text: $model.search)
            .font(.body)
            .frame(minHeight: 44)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .accessibilityIdentifier("wardrobe.search")
          Picker("可用状态", selection: $model.availability) {
            Text("全部状态").tag(Optional<WardrobeAvailability>.none)
            ForEach(WardrobeAvailability.allCases, id: \.self) { value in
              Text(value.title).tag(Optional(value))
            }
          }
          .accessibilityIdentifier("wardrobe.filter.availability")
          Picker("类别", selection: $model.category) {
            Text("全部类别").tag(Optional<WardrobeCategory>.none)
            ForEach(WardrobeCategory.allCases, id: \.self) { value in
              Text(value.title).tag(Optional(value))
            }
          }
          .accessibilityIdentifier("wardrobe.filter.category")
        }
        .pickerStyle(.menu)
        if model.visibleItems.isEmpty {
          ContentUnavailableView(
            "没有符合条件的衣物", systemImage: "cabinet",
            description: Text("试试其他类别、状态或名称。")
              .foregroundStyle(Color.primary)
          )
        }
        ForEach(model.visibleCategories, id: \.self) { category in
          VStack(alignment: .leading, spacing: 12) {
            Text(category.title).font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
              ForEach(model.visibleItems.filter { $0.input.category == category }) { item in
                WardrobeItemCard(item: item, thumbnail: model.makeThumbnailModel()) {
                  model.beginEditing(item)
                }
              }
            }
          }
          Divider()
        }
      }
      .padding(16)
    }
    .background(.background)
    .scrollEdgeEffectStyle(dynamicTypeSize.isAccessibilitySize ? .hard : .automatic, for: .all)
  }

  private var columns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible())] }
    return [GridItem(.adaptive(minimum: dynamicTypeSize >= .xxLarge ? 150 : 80), spacing: 12, alignment: .top)]
  }
}

private struct WardrobeItemCard: View {
  let item: WardrobeItem
  @State var thumbnail: WardrobeThumbnailViewModel
  let edit: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private struct Request: Hashable {
    let revision: Int
    let active: Bool
  }

  var body: some View {
    Button(action: edit) {
      VStack(alignment: .leading, spacing: 6) {
        ZStack {
          Color(.secondarySystemBackground)
          if let image = thumbnail.image {
            image.resizable().scaledToFit()
              .accessibilityLabel("已保存的衣物照片")
              .accessibilityIdentifier("wardrobe.thumbnail")
          } else {
            Image(systemName: "photo")
              .font(.title2).foregroundStyle(Color.primary)
              .accessibilityHidden(true)
          }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 160 : nil)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        Text(item.input.name).font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Text(item.input.availability.title).font(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(Color.primary)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("编辑衣物")
    .task(id: Request(revision: item.revision, active: scenePhase == .active)) {
      if scenePhase == .active { await thumbnail.load(itemID: item.id, expectedAssetID: nil) }
      else { thumbnail.clear() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { thumbnail.clear() }
    }
    .onDisappear { thumbnail.clear() }
  }

}

struct WardrobeEditorView: View {
  @Bindable var draft: WardrobeEditorModel
  let model: WardrobeViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var confirmsPhotoRemoval = false
  @FocusState private var nameFocused: Bool

  var body: some View {
    NavigationStack {
      Form {
        if !draft.isDeleted {
          Section {
            TextField("衣物名称", text: $draft.name)
              .focused($nameFocused)
              .autocorrectionDisabled()
              .accessibilityIdentifier("wardrobe.name")
            Picker("类别", selection: $draft.category) {
              Text("请选择").tag(Optional<WardrobeCategory>.none)
              ForEach(WardrobeCategory.allCases, id: \.self) { value in
                Text(value.title).tag(Optional(value))
              }
            }
            .accessibilityIdentifier("wardrobe.category")
            Picker("当前状态", selection: $draft.availability) {
              ForEach(WardrobeAvailability.allCases, id: \.self) { value in
                Text(value.title).tag(value)
              }
            }
            .accessibilityIdentifier("wardrobe.availability")
          } footer: {
            Text("仅添加你拥有的衣物。照片和其他属性可以稍后补充。")
              .foregroundStyle(Color.primary)
          }
          .disabled(draft.isWorking)
        }
        if draft.needsCategory {
          Text("请选择衣物类别。")
            .font(.body).foregroundStyle(Color.primary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = draft.error {
          Text(error.title)
            .font(.body).foregroundStyle(Color.primary)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("wardrobe.error")
        }
        if !draft.isDeleted { photoSection }
        if draft.isWorking { ProgressView("正在保存更改…") }
        if draft.isDeleted {
          if draft.canRetryDeletion {
            Button("重试清理") { draft.submit(.delete) }.disabled(draft.isWorking)
          }
        } else if draft.revision != nil {
          Button("删除衣物", role: .destructive) { draft.submit(.reviewDeletion) }
            .disabled(draft.isWorking)
        }
      }
      .scrollEdgeEffectStyle(.hard, for: .all)
      .navigationTitle(draft.isDeleted ? (draft.canRetryDeletion ? "清理衣物数据" : "衣物已删除") : (draft.revision == nil ? "添加衣物" : "编辑衣物"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(draft.isDeleted ? "关闭" : "取消") { dismiss() }.disabled(draft.isWorking)
        }
        if !draft.isDeleted {
          ToolbarItem(placement: .confirmationAction) {
            Button("保存") { draft.submit(.save) }.disabled(draft.isWorking || !draft.canSavePhoto)
          }
        }
      }
      .confirmationDialog("删除这件衣物？", isPresented: $draft.confirmsDeletion, titleVisibility: .visible) {
        if draft.deletionImpact?.plans.isEmpty == false {
          Button("保留计划并清除单品信息", role: .destructive) {
            draft.historyDeletionPolicy = .redactSnapshots
            draft.submit(.delete)
          }
          Button("同时删除相关计划", role: .destructive) {
            draft.historyDeletionPolicy = .deleteAffectedPlans
            draft.submit(.delete)
          }
        } else {
          Button("确认删除", role: .destructive) {
            draft.historyDeletionPolicy = .redactSnapshots
            draft.submit(.delete)
          }
        }
      } message: {
        if let impact = draft.deletionImpact, !impact.plans.isEmpty {
          Text("这件衣物出现在 \(impact.plans.count) 个计划中。可保留无单品信息的占位，或同时删除这些计划；衣物和照片都会移除。")
        } else {
          Text("这件衣物将从本机衣橱移除，不再用于新的推荐。此操作无法撤销。")
        }
      }
      .confirmationDialog("移除这张照片？", isPresented: $confirmsPhotoRemoval, titleVisibility: .visible) {
        Button("确认移除照片", role: .destructive) { draft.submit(.removePhoto) }
      } message: {
        Text("立即移除本机照片，衣物仍保留。取消编辑不会恢复已移除的照片。")
      }
    }
    .accessibilityHidden(scenePhase != .active)
    .overlay {
      if scenePhase != .active {
        ZStack {
          Color(.systemBackground).ignoresSafeArea()
          Label("内容已隐藏", systemImage: "lock.shield")
        }
        .accessibilityElement(children: .combine)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        nameFocused = false
        draft.cancelPhotoSelection()
      } else if phase != .active { nameFocused = false }
    }
    .onDisappear { draft.cancelPhotoSelection() }
    .interactiveDismissDisabled(draft.isWorking)
    .task { await model.loadExistingPhoto(draft) }
    .task(id: draft.photoRequest) { await model.preparePhoto(draft) }
    .task(id: draft.request) {
      if draft.request > 0 { await model.perform(draft) }
    }
  }

  @ViewBuilder private var photoSection: some View {
    Section {
      if let image = draft.candidateImage ?? draft.existingImage {
        image.resizable().scaledToFit()
          .frame(maxWidth: .infinity).frame(height: 220)
          .accessibilityLabel(draft.candidateImage == nil ? "已保存的衣物照片" : "待保存的衣物照片")
          .accessibilityIdentifier("wardrobe.photo.preview")
      }
      WardrobePhotoPickerButton {
        guard scenePhase != .background else { return }
        nameFocused = false
        draft.selectPhoto($0)
      }
      if draft.isProcessingPhoto {
        ProgressView("正在处理衣物照片…")
          .accessibilityIdentifier("wardrobe.photo.processing")
      }
      if draft.photoReview.phase == .needsConfirmation {
        Picker("照片中的单品", selection: $draft.photoSubject) {
          Text("请选择单品形式").tag(Optional<WardrobePhotoConfirmation.Subject>.none)
          Text("一件衣物或配件").tag(Optional(WardrobePhotoConfirmation.Subject.singleGarment))
          Text("一双鞋").tag(Optional(WardrobePhotoConfirmation.Subject.pairOfShoes))
        }
        .accessibilityIdentifier("wardrobe.photo.subject")
        Toggle("这是我拥有的单品", isOn: $draft.photoOwned).accessibilityIdentifier("wardrobe.photo.owned")
        Toggle("照片中没有人物或身体部位", isOn: $draft.photoNoPerson).accessibilityIdentifier("wardrobe.photo.no-person")
        Toggle("主要单品完整且没有多件重叠", isOn: $draft.photoComplete).accessibilityIdentifier("wardrobe.photo.complete")
        Button("确认单件照片") { draft.confirmPhoto() }.accessibilityIdentifier("wardrobe.photo.confirm")
      }
      if draft.photoReview.phase == .confirmed {
        Label("照片已复核，保存后生效", systemImage: "checkmark.circle")
          .accessibilityIdentifier("wardrobe.photo.confirmed")
      }
      if let issue = draft.photoIssue {
        Text(issue.title).foregroundStyle(Color.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("wardrobe.photo.error")
      }
      if draft.photoReview.phase != .empty {
        Button(draft.existingPhoto == nil ? "使用无图方式" : "保留原照片") { draft.cancelPhotoSelection() }
          .accessibilityIdentifier("wardrobe.photo.discard")
      }
      if draft.existingPhoto != nil {
        Button("移除照片", role: .destructive) { confirmsPhotoRemoval = true }
          .accessibilityIdentifier("wardrobe.photo.remove")
      } else if draft.pendingPhotoRemoval != nil {
        Button("重试照片清理") { draft.submit(.removePhoto) }
      }
    } header: {
      Text("衣物照片（可选）")
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
    } footer: {
      Text("选择平铺或悬挂的单件照片。图片仅保存在本机；检测未发现人物仍需你复核。")
        .foregroundStyle(Color.primary)
    }
    .disabled(draft.isWorking)
  }
}

extension WardrobeEditorModel.PhotoIssue {
  var title: String {
    switch self {
    case .personDetected: String(localized: "照片中检测到人物或面部。请更换单件平铺照片，或使用无图方式。")
    case .inputFailed: String(localized: "无法处理这张照片。请选择清晰的 JPEG、PNG 或 HEIC 单件图，或使用无图方式。")
    case .confirmationRequired: String(localized: "请完成本张照片的单件复核，再保存。")
    case .shoeCategoryRequired: String(localized: "一双鞋的照片需要选择“鞋”类别。")
    case .unreadable: String(localized: "无法显示已保存照片。衣物仍保留，你可以换图或移除照片。")
    case .cleanupPending: String(localized: "照片已移除，文件清理尚未完成，请重试照片清理。")
    }
  }
}

extension WardrobeCategory {
  var title: String {
    switch self {
    case .top: String(localized: "上装")
    case .bottom: String(localized: "下装")
    case .onePiece: String(localized: "连体／连衣")
    case .outerwear: String(localized: "外套")
    case .shoes: String(localized: "鞋")
    case .bag: String(localized: "包")
    case .accessory: String(localized: "配饰")
    }
  }
}

extension WardrobeAvailability {
  var title: String {
    switch self {
    case .wearable: String(localized: "可穿")
    case .laundry: String(localized: "待洗")
    case .lentOut: String(localized: "借出")
    case .packed: String(localized: "已打包")
    }
  }
}

extension WardrobeError {
  var title: String {
    switch self {
    case .invalidName: String(localized: "请输入 1–80 个字符的衣物名称，不能包含控制字符。")
    case .conflict: String(localized: "衣物已发生变化。请保留需要的修改，取消后重新打开。")
    case .notFound: String(localized: "这件衣物已被删除，请关闭编辑。")
    case .newerDatabase: String(localized: "本机数据由更新版本创建，请使用更新版本打开。")
    case .invalidStoredData: String(localized: "无法读取衣橱中的部分数据。数据已保留，请重试。")
    case .storageUnavailable: String(localized: "无法访问本机衣橱。数据和本次修改已保留，请解锁设备、检查可用空间后重试。")
    case .deletionCleanupPending: String(localized: "衣物已移出衣橱，本机存储清理尚未完成。请重试清理。")
    }
  }
}
