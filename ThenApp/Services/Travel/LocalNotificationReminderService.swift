import Foundation
import UserNotifications

actor LocalNotificationReminderService: ReminderService {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func authorizationState() async -> ReminderAuthorizationState {
    let settings = await center.notificationSettings()
    return Self.mapAuthorization(settings.authorizationStatus)
  }

  func requestAuthorization() async throws -> ReminderAuthorizationState {
    _ = try await center.requestAuthorization(options: [.alert, .sound])
    return await authorizationState()
  }

  func schedule(_ request: ReminderScheduleRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = "出发提醒"
    content.body = "该准备出发了。"
    content.sound = .default

    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: request.fireAt
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    try await center.add(
      UNNotificationRequest(
        identifier: request.requestIdentifier,
        content: content,
        trigger: trigger
      )
    )
  }

  func cancel(requestIdentifier: String) async {
    center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
  }

  private nonisolated static func mapAuthorization(
    _ status: UNAuthorizationStatus
  ) -> ReminderAuthorizationState {
    switch status {
    case .notDetermined:
      .notDetermined
    case .denied:
      .denied
    case .authorized:
      .authorized
    case .provisional:
      .provisional
    case .ephemeral:
      .ephemeral
    @unknown default:
      .denied
    }
  }
}
