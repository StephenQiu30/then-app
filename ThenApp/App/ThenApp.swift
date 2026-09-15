import SwiftUI

nonisolated enum ThenLaunchMode: Equatable {
  case product
  case avatarPhotoIntakePOC

  static func resolve(arguments: [String], debugFeaturesEnabled: Bool) -> Self {
    guard debugFeaturesEnabled,
          arguments.contains("--then-avatar-photo-intake-poc") else { return .product }
    return .avatarPhotoIntakePOC
  }
}

@main
struct ThenApp: App {
  private let launchMode: ThenLaunchMode
  @State private var model: OOTDAppModel?

  init() {
    #if DEBUG
    let launchMode = ThenLaunchMode.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugFeaturesEnabled: true
    )
    #else
    let launchMode = ThenLaunchMode.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugFeaturesEnabled: false
    )
    #endif
    self.launchMode = launchMode
    _model = State(initialValue: launchMode == .product
      ? Self.applicationModel()
      : nil)
  }

  private static func applicationModel() -> OOTDAppModel {
    let repository = GRDBWardrobeRepository.applicationStore()
    return OOTDAppModel(repository: repository, wearEvents: repository)
  }

  var body: some Scene {
    WindowGroup { root }
  }

  @ViewBuilder private var root: some View {
    switch launchMode {
    case .product:
      if let model { RootView(model: model) }
    case .avatarPhotoIntakePOC:
      #if DEBUG
      AvatarPhotoIntakePOCHost()
      #else
      EmptyView()
      #endif
    }
  }
}
