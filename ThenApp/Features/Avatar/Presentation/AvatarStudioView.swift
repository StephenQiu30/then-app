import Observation
import SwiftUI

struct BuiltInGarment: Identifiable {
  enum Category: String, CaseIterable, Identifiable {
    case tops = "TOPS"
    case outerwear = "OUTERWEAR"
    case bottoms = "BOTTOMS"
    case shoes = "SHOES"

    var id: Self { self }
  }

  let id: String
  let name: LocalizedStringKey
  let category: Category
  let assetName: String
  let rendererValue: String
  let color: Color
}

@MainActor @Observable
final class AvatarStudioModel {
  enum Screen { case look, wardrobe }

  static let catalog: [BuiltInGarment] = [
    .init(id: "ivory-knit", name: "象牙白针织上衣", category: .tops, assetName: "top-ivory-knit", rendererValue: "ivory-knit", color: Color(red: 0.90, green: 0.87, blue: 0.80)),
    .init(id: "blue-shirt", name: "雾蓝宽松衬衫", category: .outerwear, assetName: "outerwear-blue-shirt", rendererValue: "blue-shirt", color: Color(red: 0.61, green: 0.71, blue: 0.81)),
    .init(id: "black-skirt", name: "黑色百褶裙", category: .bottoms, assetName: "bottom-black-pleated", rendererValue: "black-skirt", color: Color(red: 0.08, green: 0.08, blue: 0.09)),
    .init(id: "mint-skirt", name: "薄荷绿层叠裙", category: .bottoms, assetName: "bottom-mint-layered", rendererValue: "mint-skirt", color: Color(red: 0.68, green: 0.84, blue: 0.74)),
    .init(id: "black-boots", name: "黑色短靴", category: .shoes, assetName: "shoes-black-boots", rendererValue: "black-boots", color: Color(red: 0.06, green: 0.06, blue: 0.07)),
    .init(id: "cream-sneakers", name: "奶油色运动鞋", category: .shoes, assetName: "shoes-cream-sneakers", rendererValue: "cream-sneakers", color: Color(red: 0.92, green: 0.89, blue: 0.83)),
  ]

  let sessionID = UUID().uuidString.lowercased()
  var screen: Screen = .look
  var category: BuiltInGarment.Category = .tops
  var selectedIDs: Set<String> = ["ivory-knit", "black-skirt", "cream-sneakers"]
  var appliedIDs: Set<String> = ["ivory-knit", "black-skirt", "cream-sneakers"]
  var yaw = -0.08
  var shoulderWidth = 0.0
  var torsoDepth = 0.0
  var reduceMotion = false
  var revision = 0
  var rendererState: AvatarRendererState = .loading
  var isFavorite = false
  var notice: LocalizedStringKey?

  var visibleGarments: [BuiltInGarment] {
    Self.catalog.filter { $0.category == category }
  }

  var selectedGarments: [BuiltInGarment] {
    Self.catalog.filter { selectedIDs.contains($0.id) }
  }

  var appliedGarments: [BuiltInGarment] {
    Self.catalog.filter { appliedIDs.contains($0.id) }
  }

  var renderConfiguration: AvatarRenderConfiguration {
    let top = appliedGarments.first(where: { $0.category == .outerwear })
      ?? appliedGarments.first(where: { $0.category == .tops })
    let bottom = appliedGarments.first(where: { $0.category == .bottoms })
    let shoes = appliedGarments.first(where: { $0.category == .shoes })
    return AvatarRenderConfiguration(
      sessionID: sessionID,
      top: top?.rendererValue ?? "ivory-knit",
      bottom: bottom?.rendererValue ?? "black-skirt",
      shoes: shoes?.rendererValue ?? "cream-sneakers",
      shoulderWidth: shoulderWidth,
      torsoDepth: torsoDepth,
      yaw: yaw,
      reduceMotion: reduceMotion,
      revision: revision
    )
  }

  func toggle(_ garment: BuiltInGarment) {
    if selectedIDs.contains(garment.id) {
      selectedIDs.remove(garment.id)
    } else {
      // One garment per category keeps the first POC deterministic.
      for item in Self.catalog where item.category == garment.category {
        selectedIDs.remove(item.id)
      }
      if garment.category == .outerwear {
        for item in Self.catalog where item.category == .tops { selectedIDs.remove(item.id) }
      } else if garment.category == .tops {
        for item in Self.catalog where item.category == .outerwear { selectedIDs.remove(item.id) }
      }
      selectedIDs.insert(garment.id)
    }
  }

  func dressUp() {
    guard !selectedIDs.isEmpty else { return }
    appliedIDs = selectedIDs
    rendererState = .loading
    revision += 1
    screen = .look
    notice = "已换上所选服装"
  }

  func turn(_ delta: Double) {
    yaw += delta
    rendererState = .loading
    revision += 1
  }

  func showAngle(_ angle: Double) {
    yaw = angle
    rendererState = .loading
    revision += 1
  }

  func updateShoulderWidth(_ value: Double) {
    shoulderWidth = min(0.25, max(-0.25, value))
    rendererState = .loading
    revision += 1
  }

  func updateTorsoDepth(_ value: Double) {
    torsoDepth = min(0.25, max(-0.25, value))
    rendererState = .loading
    revision += 1
  }

  func setReduceMotion(_ isEnabled: Bool) {
    guard reduceMotion != isEnabled else { return }
    reduceMotion = isEnabled
    revision += 1
  }

  func resetLook() {
    selectedIDs = ["ivory-knit", "black-skirt", "cream-sneakers"]
    appliedIDs = selectedIDs
    yaw = -0.08
    shoulderWidth = 0
    torsoDepth = 0
    isFavorite = false
    rendererState = .loading
    revision += 1
    notice = "已恢复默认穿搭"
  }
}

struct AvatarStudioView: View {
  @Bindable var model: AvatarStudioModel
  @Bindable var wardrobe: WardrobeViewModel
  @Bindable var outfits: OutfitPlanViewModel
  @Bindable var recommendations: RecommendationViewModel
  @State private var showsCalendar = false
  @State private var showsMenu = false
  @State private var showsPhotoPath = false
  @State private var showsShare = false
  @State private var showsAppearance = false
  @State private var showsRecommendations = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.white.ignoresSafeArea()
      Group {
        switch model.screen {
        case .look:
          look
        case .wardrobe:
          builtInWardrobe
        }
      }
      bottomDock
        .padding(.bottom, 8)
    }
    .preferredColorScheme(.light)
    .task { model.setReduceMotion(accessibilityReduceMotion) }
    .onChange(of: accessibilityReduceMotion) { _, isEnabled in
      model.setReduceMotion(isEnabled)
    }
    .sheet(isPresented: $showsCalendar) {
      NavigationStack {
        OutfitPlanView(model: outfits)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("关闭") { showsCalendar = false }
            }
          }
      }
    }
    .sheet(isPresented: $showsMenu) {
      NavigationStack {
        WardrobeView(model: wardrobe)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("关闭") { showsMenu = false }
            }
          }
      }
    }
    .sheet(isPresented: $showsPhotoPath) { optionalPhotoSheet }
    .sheet(isPresented: $showsShare) { shareSheet }
    .sheet(isPresented: $showsAppearance) { appearanceSheet }
    .sheet(isPresented: $showsRecommendations) {
      NavigationStack {
        RecommendationView(model: recommendations)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("关闭") { showsRecommendations = false }
            }
          }
      }
    }
    .overlay(alignment: .top) {
      if let notice = model.notice {
        Text(notice)
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(.black, in: Capsule())
          .foregroundStyle(.white)
          .padding(.top, 54)
          .transition(.move(edge: .top).combined(with: .opacity))
          .task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { model.notice = nil }
          }
      }
    }
    .animation(.snappy, value: model.notice != nil)
  }

  private var topBar: some View {
    HStack {
      HStack(spacing: 8) {
        Image("BrandMark")
          .resizable()
          .scaledToFit()
          .frame(width: 30, height: 30)
          .accessibilityHidden(true)
        Text(verbatim: "于是")
          .font(.system(size: 25, weight: .black, design: .rounded))
          .tracking(-1.2)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("于是")
      Spacer()
      Button { showsRecommendations = true } label: {
        Image(systemName: "sparkles")
      }
      .accessibilityLabel("获取穿搭建议")
      Button { showsCalendar = true } label: {
        Image(systemName: "calendar")
      }
      .accessibilityLabel("打开穿搭日历")
      Button { showsMenu = true } label: {
        Image(systemName: "line.3.horizontal")
      }
      .accessibilityLabel("打开个人衣橱")
    }
    .font(.title3.weight(.semibold))
    .foregroundStyle(.black)
    .padding(.horizontal, 22)
    .frame(height: 54)
  }

  private var look: some View {
    VStack(spacing: 0) {
      topBar
      ZStack(alignment: .bottom) {
        if case .failed = model.rendererState {
          BundledAvatarImage(name: "avatar-fallback")
            .scaledToFit()
            .padding(.horizontal, 54)
            .accessibilityLabel("三维渲染暂不可用，显示静态穿搭形象")
            .accessibilityIdentifier("avatar.renderer.fallback")
            .accessibilityValue(rendererAccessibilityValue)
        } else {
          ThreeAvatarView(
            configuration: model.renderConfiguration,
            isActive: stageActivity.rendererIsActive,
            onStateChange: { model.rendererState = $0 },
            onYawChange: { model.yaw = $0 }
          )
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("三维穿搭形象")
          .accessibilityHint("单指左右拖动可旋转")
          .accessibilityIdentifier("avatar.renderer")
          .accessibilityValue(rendererAccessibilityValue)
          if model.rendererState == .loading {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在准备三维形象")
              .accessibilityIdentifier("avatar.renderer.loading")
          }
        }
        HStack {
          turnButton(systemName: "chevron.left", delta: -0.35, label: "向左转动")
          Spacer()
          turnButton(systemName: "chevron.right", delta: 0.35, label: "向右转动")
        }
        .padding(.horizontal, 16)
        anglePicker
          .padding(.bottom, 8)
      }
      .frame(maxHeight: .infinity)

      lookCard
        .padding(.horizontal, 14)
        .padding(.bottom, 88)
    }
  }

  private var stageActivity: AvatarStageActivity {
    AvatarStageActivity(
      appIsActive: scenePhase == .active,
      stageIsVisible: model.screen == .look,
      hasPresentedCover: showsCalendar || showsMenu || showsPhotoPath || showsShare || showsAppearance
        || showsRecommendations
    )
  }

  private var rendererAccessibilityValue: LocalizedStringKey {
    switch model.rendererState {
    case .loading: "正在渲染"
    case .ready: "已就绪"
    case .failed: "暂不可用"
    }
  }

  private var anglePicker: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        Menu("观察角度") {
          Button("正面") { model.showAngle(0) }
          Button("侧面") { model.showAngle(.pi / 2) }
          Button("背面") { model.showAngle(.pi) }
        }
        .font(.body.bold())
        .foregroundStyle(.black)
        .frame(minHeight: 44)
      } else {
        HStack(spacing: 4) {
          angleButton("正面", angle: 0)
          angleButton("侧面", angle: .pi / 2)
          angleButton("背面", angle: .pi)
        }
      }
    }
    .padding(4)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 0.5))
    .accessibilityElement(children: .contain)
  }

  private func angleButton(_ label: LocalizedStringKey, angle: Double) -> some View {
    Button(label) { model.showAngle(angle) }
      .font(.caption2.weight(.bold))
      .foregroundStyle(.black)
      .padding(.horizontal, 10)
      .frame(minHeight: 36)
      .contentShape(Rectangle())
  }

  private func turnButton(systemName: String, delta: Double, label: LocalizedStringKey) -> some View {
    Button { model.turn(delta) } label: {
      Image(systemName: systemName)
        .font(.body.weight(.bold))
        .frame(width: 44, height: 44)
        .background(.white.opacity(0.9), in: Circle())
        .shadow(color: .black.opacity(0.09), radius: 10, y: 4)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.black)
    .accessibilityLabel(label)
  }

  private var lookCard: some View {
    VStack(spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack { lookCardHeading; Spacer(); lookCardActions }
        VStack(alignment: .leading, spacing: 10) { lookCardHeading; lookCardActions }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { appliedGarmentImages; Spacer(); lookCardHint }
        VStack(alignment: .leading, spacing: 10) { appliedGarmentImages; lookCardHint }
      }
    }
    .padding(16)
    .foregroundStyle(.black)
    .background(.white, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    .shadow(color: .black.opacity(0.09), radius: 24, y: 8)
  }

  private var lookCardHeading: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(Date.now, format: .dateTime.month(.wide).day().weekday(.wide))
        .font(.system(.title3, design: .rounded, weight: .bold))
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 7) {
        ForEach(model.appliedGarments) { garment in
          Circle().fill(garment.color).frame(width: 11, height: 11)
        }
      }
    }
  }

  private var lookCardActions: some View {
    HStack {
      Button { model.isFavorite.toggle() } label: {
        Image(systemName: model.isFavorite ? "heart.fill" : "heart")
      }
      .accessibilityLabel(model.isFavorite ? "取消收藏" : "收藏穿搭")
      Button { showsShare = true } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel("分享穿搭")
      Button(role: .destructive) { model.resetLook() } label: { Image(systemName: "trash") }
        .accessibilityLabel("恢复默认穿搭")
    }
  }

  private var appliedGarmentImages: some View {
    HStack(spacing: 10) {
      ForEach(model.appliedGarments) { garment in
        BundledAvatarImage(name: garment.assetName)
          .scaledToFit()
          .frame(width: 52, height: 52)
          .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 13))
          .accessibilityLabel(garment.name)
      }
    }
  }

  private var lookCardHint: some View {
    Text("拖动形象查看 360°")
      .font(.caption.weight(.medium))
      .foregroundStyle(.black)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var builtInWardrobe: some View {
    VStack(spacing: 0) {
      topBar
      if !model.selectedGarments.isEmpty { selectionTray }
      HStack(spacing: 18) {
        ForEach(BuiltInGarment.Category.allCases) { category in
          Button(category.rawValue) { model.category = category }
            .font(.caption2.weight(model.category == category ? .black : .semibold))
            .foregroundStyle(model.category == category ? .black : .secondary)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
              if model.category == category { Capsule().frame(height: 2) }
            }
        }
      }
      .padding(.horizontal, 18)
      .frame(maxWidth: .infinity)

      ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
          ForEach(model.visibleGarments) { garment in
            garmentCard(garment)
          }
        }
        .padding(16)
        .padding(.bottom, 96)
      }
      .scrollIndicators(.hidden)
    }
  }

  private var selectionTray: some View {
    HStack(spacing: 10) {
      Text("\(model.selectedGarments.count)")
        .font(.headline.monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(.white.opacity(0.18), in: Circle())
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(model.selectedGarments) { garment in
            ZStack(alignment: .topTrailing) {
              BundledAvatarImage(name: garment.assetName)
                .scaledToFit()
                .frame(width: 46, height: 46)
                .background(.white, in: RoundedRectangle(cornerRadius: 11))
              Button { model.toggle(garment) } label: {
                Image(systemName: "xmark.circle.fill")
                  .symbolRenderingMode(.palette)
                  .foregroundStyle(.white, .black)
              }
              .offset(x: 5, y: -5)
              .accessibilityLabel("移除所选衣物")
            }
          }
        }
      }
      .scrollIndicators(.hidden)
      Spacer(minLength: 0)
      Button("Dress up") { model.dressUp() }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Color(red: 0.28, green: 0.47, blue: 0.98))
        .disabled(model.selectedGarments.isEmpty)
    }
    .padding(12)
    .background(.black)
  }

  private func garmentCard(_ garment: BuiltInGarment) -> some View {
    Button { model.toggle(garment) } label: {
      VStack(alignment: .leading, spacing: 10) {
        ZStack(alignment: .topTrailing) {
          Color(white: 0.965)
          BundledAvatarImage(name: garment.assetName)
            .scaledToFit()
            .padding(12)
          Image(systemName: model.selectedIDs.contains(garment.id) ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(model.selectedIDs.contains(garment.id) ? .black : .gray)
            .padding(10)
        }
        .aspectRatio(0.88, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        Text(garment.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.black)
          .lineLimit(1)
      }
    }
    .buttonStyle(.plain)
  }

  private var bottomDock: some View {
    HStack(spacing: 18) {
      dockButton(systemName: "person.fill", selected: model.screen == .look, label: "形象") {
        if model.screen == .look {
          showsAppearance = true
        } else {
          model.screen = .look
        }
      }
      Button { showsPhotoPath = true } label: {
        Image(systemName: "camera.fill")
          .font(.title3)
          .frame(width: 54, height: 54)
          .background(.black, in: Circle())
          .foregroundStyle(.white)
      }
      .accessibilityLabel("可选照片穿搭")
      dockButton(systemName: "hanger", selected: model.screen == .wardrobe, label: "内置衣橱") {
        model.screen = .wardrobe
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
  }

  private var appearanceSheet: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 6) {
          Text("调整数字形象")
            .font(.title2.bold())
          Text("使用经过服装适配验证的有限范围。数值不会被解释为真实身体尺寸。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        bodySlider(
          title: "肩部宽度",
          value: Binding(
            get: { model.shoulderWidth },
            set: { model.updateShoulderWidth($0) }
          )
        )
        bodySlider(
          title: "躯干厚度",
          value: Binding(
            get: { model.torsoDepth },
            set: { model.updateTorsoDepth($0) }
          )
        )
        HStack {
          Button("恢复默认") {
            model.updateShoulderWidth(0)
            model.updateTorsoDepth(0)
          }
          .buttonStyle(.bordered)
          Spacer()
          Button("完成") { showsAppearance = false }
            .buttonStyle(.borderedProminent)
            .tint(.black)
        }
      }
      .padding(24)
      .navigationTitle("形象")
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium])
  }

  private func bodySlider(
    title: LocalizedStringKey,
    value: Binding<Double>
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: -0.25...0.25, step: 0.05)
      .tint(.black)
      .accessibilityLabel(title)
      .accessibilityValue(Text(value.wrappedValue, format: .number.precision(.fractionLength(2))))
    }
  }

  private func dockButton(
    systemName: String,
    selected: Bool,
    label: LocalizedStringKey,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.title3.weight(.semibold))
        .frame(width: 46, height: 46)
        .background(selected ? .black : .clear, in: Circle())
        .foregroundStyle(selected ? .white : .black)
    }
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var optionalPhotoSheet: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Image(systemName: "camera.aperture")
          .font(.system(size: 52))
        Text("照片穿搭是可选增强")
          .font(.title2.bold())
        Text("无需上传衣服即可使用内置衣橱和三维形象。本人照片生成仍需经过同意、质量、隐私和供应商门禁。")
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
        Button("继续使用三维形象") { showsPhotoPath = false }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
          .tint(.black)
      }
      .padding(28)
      .navigationTitle("可选照片穿搭")
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium])
  }

  private var shareSheet: some View {
    VStack(spacing: 18) {
      Text("分享今日穿搭")
        .font(.title2.bold())
      ShareLink(
        item: "我在于是用内置衣橱完成了今日三维穿搭。",
        subject: Text("于是 · 今日穿搭")
      ) {
        Label("打开系统分享", systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .tint(.black)
    }
    .padding(30)
    .presentationDetents([.height(220)])
  }
}
