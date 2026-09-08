import AVFoundation
import CoreLocation
import EventKit
import UserNotifications

nonisolated struct SystemPermissionStatusService: PermissionStatusService {
  @MainActor
  func currentStatus() async -> DevicePermissionSnapshot {
    let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
    let locationManager = CLLocationManager()
    return DevicePermissionSnapshot(
      calendar: calendarStatus(),
      notifications: Self.notificationStatus(notificationSettings.authorizationStatus),
      location: Self.locationStatus(locationManager.authorizationStatus),
      camera: Self.cameraStatus(AVCaptureDevice.authorizationStatus(for: .video))
    )
  }

  private func calendarStatus() -> DevicePermissionState {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined:
      .notRequested
    case .fullAccess:
      .allowed
    case .writeOnly:
      .limited
    case .denied:
      .denied
    case .restricted:
      .restricted
    @unknown default:
      .unavailable
    }
  }

  private static func notificationStatus(
    _ status: UNAuthorizationStatus
  ) -> DevicePermissionState {
    switch status {
    case .notDetermined:
      .notRequested
    case .authorized, .provisional, .ephemeral:
      .allowed
    case .denied:
      .denied
    @unknown default:
      .unavailable
    }
  }

  private static func locationStatus(
    _ status: CLAuthorizationStatus
  ) -> DevicePermissionState {
    switch status {
    case .notDetermined:
      .notRequested
    case .authorizedWhenInUse, .authorizedAlways:
      .allowed
    case .denied:
      .denied
    case .restricted:
      .restricted
    @unknown default:
      .unavailable
    }
  }

  private static func cameraStatus(
    _ status: AVAuthorizationStatus
  ) -> DevicePermissionState {
    switch status {
    case .notDetermined:
      .notRequested
    case .authorized:
      .allowed
    case .denied:
      .denied
    case .restricted:
      .restricted
    @unknown default:
      .unavailable
    }
  }
}
