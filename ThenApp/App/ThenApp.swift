import SwiftUI

@main
struct ThenApp: App {
  private enum StartupState {
    case ready(AppEnvironment)
    case failed
  }

  @State private var startupState: StartupState

  init() {
    do {
      _startupState = State(initialValue: .ready(try AppEnvironment.bootstrap()))
    } catch {
      _startupState = State(initialValue: .failed)
    }
  }

  var body: some Scene {
    WindowGroup {
      switch startupState {
      case .ready(let environment):
        RootView(environment: environment) {
          do {
            startupState = .ready(try AppEnvironment.bootstrap())
          } catch {
            startupState = .failed
          }
        }
      case .failed:
        ContentUnavailableView {
          Label("无法打开本地数据", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
          Text("于是没有重建或删除现有数据。请重新启动 App 后再试。")
        }
      }
    }
  }
}
