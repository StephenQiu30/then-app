import SwiftUI
import Testing

@testable import ThenApp

@Suite("固定导航与本地权限中心")
struct NavigationAndProfileTests {
  @Test("发布信息只在版本和构建号完整时格式化")
  func releaseInformationFormatsOnlyCompleteMetadata() {
    let complete = AppReleaseInformation(
      appName: "  于是  ",
      shortVersion: " 0.1.0 ",
      buildNumber: " 42 "
    )
    let missingBuild = AppReleaseInformation(
      appName: nil,
      shortVersion: "0.1.0",
      buildNumber: "  "
    )
    let missingVersion = AppReleaseInformation(
      appName: "",
      shortVersion: nil,
      buildNumber: "42"
    )

    #expect(complete.appName == "于是")
    #expect(complete.versionAndBuild == "0.1.0 (42)")
    #expect(missingBuild.appName == "于是")
    #expect(missingBuild.versionAndBuild == nil)
    #expect(missingVersion.appName == "于是")
    #expect(missingVersion.versionAndBuild == nil)
  }

  @Test("一级导航固定为今天账本日程行程我的五项")
  func rootTabOrderIsStable() {
    #expect(RootTab.allCases == [.today, .ledger, .calendar, .travel, .profile])
  }

  @Test("离开前台时隐私遮罩策略隐藏敏感内容")
  func privacyCoverFollowsScenePhase() {
    #expect(!PrivacyCoverPolicy.hidesSensitiveContent(for: .active))
    #expect(PrivacyCoverPolicy.hidesSensitiveContent(for: .inactive))
    #expect(PrivacyCoverPolicy.hidesSensitiveContent(for: .background))
  }

  @MainActor
  @Test("权限中心只读展示适配器返回的当前状态")
  func profileLoadsCurrentPermissionStatus() async {
    let expected = DevicePermissionSnapshot(
      calendar: .allowed,
      notifications: .denied,
      location: .notRequested,
      camera: .restricted
    )
    let model = MyViewModel(
      permissionStatus: FixedPermissionStatusService(snapshot: expected),
      localData: FixedLocalDataService(),
      releaseInformation: AppReleaseInformation(
        appName: "于是",
        shortVersion: "0.1.0",
        buildNumber: "7"
      )
    )

    await model.load()

    #expect(model.permissions == expected)
    #expect(model.releaseInformation.versionAndBuild == "0.1.0 (7)")
    #expect(!model.isLoading)
  }

  @MainActor
  @Test("低存储导出失败提供脱敏重试提示")
  func insufficientStorageExportShowsRecoverableMessage() async {
    let model = MyViewModel(
      permissionStatus: FixedPermissionStatusService(
        snapshot: DevicePermissionSnapshot(
          calendar: .notRequested,
          notifications: .notRequested,
          location: .notRequested,
          camera: .notRequested
        )
      ),
      localData: FixedLocalDataService(exportError: .insufficientStorage)
    )

    await model.createExport()

    #expect(model.exportArtifact == nil)
    #expect(!model.isManagingData)
    #expect(model.dataError == "存储空间不足，请清理后重试；源数据没有改变。")
  }
}

private actor FixedLocalDataService: LocalDataManaging {
  private let exportError: LocalDataManagementError

  init(exportError: LocalDataManagementError = .exportWriteFailed) {
    self.exportError = exportError
  }

  func createExport() async throws -> LocalDataExportArtifact {
    throw exportError
  }

  func cleanupExport(_ artifact: LocalDataExportArtifact) async throws {}
  func clearCalendarCache() async throws {}
  func resetAllLocalData() async throws {}
}

private nonisolated struct FixedPermissionStatusService: PermissionStatusService {
  let snapshot: DevicePermissionSnapshot

  @MainActor
  func currentStatus() async -> DevicePermissionSnapshot {
    snapshot
  }
}
