import SwiftUI

struct RootView: View {
  @Bindable var model: OOTDAppModel
  @State private var studio = AvatarStudioModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      content.accessibilityHidden(scenePhase != .active)
      if scenePhase != .active {
        ZStack {
          Color(.systemBackground).ignoresSafeArea()
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
