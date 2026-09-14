import SwiftUI

@main
struct ThenApp: App {
  @State private var model = OOTDAppModel(repository: GRDBWardrobeRepository.applicationStore())

  var body: some Scene {
    WindowGroup { RootView(model: model) }
  }
}
