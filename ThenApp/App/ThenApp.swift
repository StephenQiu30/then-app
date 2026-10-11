import SwiftUI

@main
struct ThenApp: App {
  @State private var model: OOTDAppModel

  init() {
    let repository = GRDBWardrobeRepository.applicationStore()
    _model = State(initialValue: OOTDAppModel(repository: repository, wearEvents: repository, feedback: repository))
  }

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .tint(ThenPalette.ink)
        .preferredColorScheme(.light)
    }
  }
}
