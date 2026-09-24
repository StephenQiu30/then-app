import SwiftUI

enum ThenPalette {
  static let canvas = Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
  static let surface = Color.white
  static let inset = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
  static let ink = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
  static let body = Color(red: 77 / 255, green: 77 / 255, blue: 77 / 255)
  static let hairline = Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255)
  static let link = Color(red: 0 / 255, green: 112 / 255, blue: 243 / 255)
  static let destructive = Color(red: 197 / 255, green: 0 / 255, blue: 0 / 255)
}

struct RootView: View {
  @Bindable var model: OOTDAppModel
  @State private var studio = AvatarStudioModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      content.accessibilityHidden(scenePhase != .active)
      if scenePhase != .active {
        ZStack {
          ThenPalette.canvas.ignoresSafeArea()
          Label("内容已隐藏", systemImage: "lock.shield")
        }
        .accessibilityElement(children: .combine)
      }
    }
    .task(id: model.attempt) { await model.start() }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .starting:
      ProgressView("正在打开衣橱…")
    case .failed:
      ContentUnavailableView {
        Label("暂时无法打开衣橱", systemImage: "cabinet")
      } description: {
        Text((model.error ?? .storageUnavailable).title)
      } actions: {
        Button("重试") { model.requestRetry() }
      }
    case .ready:
      tabs
    }
  }

  private var tabs: some View {
    @Bindable var wardrobe = model.wardrobe
    @Bindable var outfits = model.outfits
    @Bindable var recommendations = model.recommendations
    return AvatarStudioView(model: studio, wardrobe: wardrobe, outfits: outfits, recommendations: recommendations)
  }
}
