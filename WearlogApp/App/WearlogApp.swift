import SwiftUI

@main
struct WearlogApp: App {
  @State private var model: WearlogAppModel

  init() {
    let repository = GRDBWardrobeRepository.applicationStore()
    _model = State(initialValue: WearlogAppModel(repository: repository, wearEvents: repository, feedback: repository))
  }

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .tint(WearlogPalette.ink)
        .preferredColorScheme(.light)
    }
  }
}
