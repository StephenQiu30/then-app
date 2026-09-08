import Testing

@testable import ThenApp

@Suite("启动模式")
struct AppLaunchModeTests {
  @Test("P0 本地模式不依赖账号和网络")
  func localModeHasNoRemoteDependency() {
    #expect(AppLaunchMode.local.requiresAccount == false)
    #expect(AppLaunchMode.local.requiresNetwork == false)
  }
}
