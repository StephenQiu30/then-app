import Foundation
import Observation

@MainActor
@Observable
final class CalendarViewModel {
  private let calendarImport: CalendarImportService

  var authorizationState: CalendarAuthorizationState = .notDetermined
  var sources: [CalendarSourceSummary] = []
  var occurrences: [CalendarOccurrenceSummary] = []
  var isLoading = false
  var isRequestingAccess = false
  var isScanning = false
  var errorMessage: LocalizedStringResource?
  var scanMessage: LocalizedStringResource?

  init(calendarImport: CalendarImportService) {
    self.calendarImport = calendarImport
  }

  var hasSelectedSources: Bool {
    sources.contains { $0.isSelected && $0.accessState == .selected }
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    authorizationState = await calendarImport.authorizationState()
    do {
      sources = try await calendarImport.refreshSources()
      occurrences = try await calendarImport.visibleOccurrences()
    } catch {
      errorMessage = Self.userMessage(for: error)
      sources = (try? await calendarImport.sources()) ?? []
      occurrences = (try? await calendarImport.visibleOccurrences()) ?? []
    }
  }

  func requestAccess() async {
    guard !isRequestingAccess else { return }
    isRequestingAccess = true
    errorMessage = nil
    scanMessage = nil
    defer { isRequestingAccess = false }
    do {
      authorizationState = try await calendarImport.requestFullAccess()
      sources = try await calendarImport.sources()
      occurrences = try await calendarImport.visibleOccurrences()
      if authorizationState != .fullAccess {
        errorMessage = Self.userMessage(for: Self.authorizationError(authorizationState))
      }
    } catch {
      authorizationState = await calendarImport.authorizationState()
      errorMessage = Self.userMessage(for: error)
    }
  }

  func setSourceSelection(_ source: CalendarSourceSummary, isSelected: Bool) async {
    guard source.isAvailable else { return }
    errorMessage = nil
    scanMessage = nil
    do {
      try await calendarImport.setSourceSelection(
        sourceID: source.id,
        isSelected: isSelected
      )
      sources = try await calendarImport.sources()
      if !isSelected {
        occurrences = try await calendarImport.visibleOccurrences()
      }
    } catch {
      errorMessage = Self.userMessage(for: error)
      sources = (try? await calendarImport.sources()) ?? sources
    }
  }

  func scan() async {
    guard !isScanning, authorizationState == .fullAccess else { return }
    isScanning = true
    errorMessage = nil
    scanMessage = nil
    defer { isScanning = false }
    do {
      guard let result = try await calendarImport.scan() else {
        sources = try await calendarImport.sources()
        occurrences = try await calendarImport.visibleOccurrences()
        scanMessage = "请先选择至少一个日历来源。"
        return
      }
      sources = try await calendarImport.sources()
      occurrences = try await calendarImport.visibleOccurrences()
      scanMessage = "已更新 \(result.activeCount) 个窗口内事件。"
    } catch is CancellationError {
      return
    } catch {
      authorizationState = await calendarImport.authorizationState()
      errorMessage = Self.userMessage(for: error)
      sources = (try? await calendarImport.sources()) ?? sources
      occurrences = (try? await calendarImport.visibleOccurrences()) ?? occurrences
    }
  }

  func observeEventStoreChanges() async {
    let changes = await calendarImport.eventStoreChanges()
    for await _ in changes {
      guard !Task.isCancelled else { return }
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      authorizationState = await calendarImport.authorizationState()
      if authorizationState == .fullAccess, hasSelectedSources {
        await scan()
      } else {
        await load()
      }
    }
  }

  private static func userMessage(for error: Error) -> LocalizedStringResource {
    switch error {
    case CalendarDomainError.calendarPermissionDenied:
      "未获得日历完整访问，记账仍可使用；可稍后在系统设置中开启。"
    case CalendarDomainError.calendarPermissionRestricted:
      "当前设备限制了日历访问，记账仍可使用。"
    case CalendarDomainError.calendarWriteOnlyAccess:
      "当前只有写入权限，无法读取日程；需要完整访问才能同步选定日历。"
    case CalendarDomainError.identityKeyUnavailable:
      "无法安全建立本地日历身份，未读取或缓存事件。"
    case CalendarDomainError.selectedSourceUnavailable:
      "选中的日历暂时不可用，已有缓存没有被判定为删除。"
    default:
      "日程更新失败，已有缓存保持不变，请稍后重试。"
    }
  }

  private static func authorizationError(
    _ state: CalendarAuthorizationState
  ) -> CalendarDomainError {
    switch state {
    case .restricted:
      .calendarPermissionRestricted
    case .writeOnly:
      .calendarWriteOnlyAccess
    case .notDetermined, .denied:
      .calendarPermissionDenied
    case .fullAccess:
      .eventQueryFailed
    }
  }
}
