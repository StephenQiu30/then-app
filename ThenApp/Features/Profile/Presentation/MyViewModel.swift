import Foundation
import Observation

@MainActor
@Observable
final class MyViewModel {
  private let permissionStatus: any PermissionStatusService
  private let localData: any LocalDataManaging

  let releaseInformation: AppReleaseInformation
  var permissions: DevicePermissionSnapshot?
  var exportArtifact: LocalDataExportArtifact?
  var isLoading = false
  var isManagingData = false
  var dataMessage: LocalizedStringResource?
  var dataError: LocalizedStringResource?

  init(
    permissionStatus: any PermissionStatusService,
    localData: any LocalDataManaging,
    releaseInformation: AppReleaseInformation = .current()
  ) {
    self.permissionStatus = permissionStatus
    self.localData = localData
    self.releaseInformation = releaseInformation
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    permissions = await permissionStatus.currentStatus()
  }

  func createExport() async {
    guard !isManagingData, exportArtifact == nil else { return }
    isManagingData = true
    dataMessage = nil
    dataError = nil
    defer { isManagingData = false }
    do {
      exportArtifact = try await localData.createExport()
    } catch LocalDataManagementError.insufficientStorage {
      dataError = "存储空间不足，请清理后重试；源数据没有改变。"
    } catch {
      dataError = "无法生成导出文件；源数据没有改变。"
    }
  }

  func finishSharing() async {
    guard let exportArtifact else { return }
    self.exportArtifact = nil
    do {
      try await localData.cleanupExport(exportArtifact)
    } catch {
      dataError = "分享已结束，但临时导出文件清理失败，请重试导出后再关闭。"
    }
  }

  func clearCalendarCache() async {
    guard !isManagingData, exportArtifact == nil else { return }
    isManagingData = true
    dataMessage = nil
    dataError = nil
    defer { isManagingData = false }
    do {
      try await localData.clearCalendarCache()
      dataMessage = "已清理日历缓存；出行计划、行程和账务仍然保留。"
    } catch {
      dataError = "无法清理日历缓存；没有宣称删除完成。"
    }
  }

  func resetAllLocalData() async -> Bool {
    guard !isManagingData, exportArtifact == nil else { return false }
    isManagingData = true
    dataMessage = nil
    dataError = nil
    defer { isManagingData = false }
    do {
      try await localData.resetAllLocalData()
      return true
    } catch {
      dataError = "无法删除全部本地数据；数据库变更已回滚。"
      return false
    }
  }
}
