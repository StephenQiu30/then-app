import Foundation

nonisolated enum DevicePermissionState: String, Sendable, Equatable {
  case notRequested = "not_requested"
  case allowed
  case denied
  case restricted
  case limited
  case unavailable
}

nonisolated struct DevicePermissionSnapshot: Sendable, Equatable {
  let calendar: DevicePermissionState
  let notifications: DevicePermissionState
  let location: DevicePermissionState
  let camera: DevicePermissionState
}

nonisolated struct AppReleaseInformation: Sendable, Equatable {
  let appName: String
  let shortVersion: String?
  let buildNumber: String?

  init(
    appName: String?,
    shortVersion: String?,
    buildNumber: String?
  ) {
    self.appName = Self.normalized(appName) ?? "于是"
    self.shortVersion = Self.normalized(shortVersion)
    self.buildNumber = Self.normalized(buildNumber)
  }

  var versionAndBuild: String? {
    guard let shortVersion, let buildNumber else { return nil }
    return "\(shortVersion) (\(buildNumber))"
  }

  static func current(bundle: Bundle = .main) -> AppReleaseInformation {
    AppReleaseInformation(
      appName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
      shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    )
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

nonisolated protocol PermissionStatusService: Sendable {
  @MainActor
  func currentStatus() async -> DevicePermissionSnapshot
}
