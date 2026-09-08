import CryptoKit
import EventKit
import Foundation
import Security

nonisolated struct CalendarIdentityKeyStore: Sendable {
  private let service = "com.stephenqiu.then.calendar-identity"
  private let account = "hmac-key-v1"

  func loadOrCreateKey() throws -> Data {
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    var readQuery = baseQuery
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
    if readStatus == errSecSuccess, let data = result as? Data, data.count == 32 {
      return data
    }
    guard readStatus == errSecItemNotFound else {
      throw CalendarDomainError.identityKeyUnavailable
    }

    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CalendarDomainError.identityKeyUnavailable
    }
    let keyData = Data(bytes)
    var addQuery = baseQuery
    addQuery[kSecValueData as String] = keyData
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess {
      return keyData
    }
    if addStatus == errSecDuplicateItem {
      var duplicateResult: CFTypeRef?
      guard SecItemCopyMatching(readQuery as CFDictionary, &duplicateResult) == errSecSuccess,
        let duplicateData = duplicateResult as? Data,
        duplicateData.count == 32
      else {
        throw CalendarDomainError.identityKeyUnavailable
      }
      return duplicateData
    }
    throw CalendarDomainError.identityKeyUnavailable
  }
}

actor EventKitCalendarService: CalendarService {
  private final class NotificationToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(value: any NSObjectProtocol) {
      self.value = value
    }
  }

  private let eventStore: EKEventStore
  private let keyStore: CalendarIdentityKeyStore
  private var cachedKeyData: Data?

  init(
    eventStore: EKEventStore = EKEventStore(),
    keyStore: CalendarIdentityKeyStore = CalendarIdentityKeyStore()
  ) {
    self.eventStore = eventStore
    self.keyStore = keyStore
  }

  func authorizationState() -> CalendarAuthorizationState {
    Self.authorizationState(from: EKEventStore.authorizationStatus(for: .event))
  }

  func requestFullAccess() async throws -> CalendarAuthorizationState {
    let granted = try await eventStore.requestFullAccessToEvents()
    let state = authorizationState()
    if granted, state == .fullAccess { return .fullAccess }
    return state
  }

  func availableSources() throws -> [SystemCalendarSourceSnapshot] {
    guard authorizationState() == .fullAccess else {
      throw authorizationError(for: authorizationState())
    }
    return try eventStore.calendars(for: .event)
      .map { calendar in
        SystemCalendarSourceSnapshot(
          externalIdentityHMAC: try digest(["calendar", calendar.calendarIdentifier]),
          title: normalizedOptional(calendar.title) ?? "未命名日历",
          kind: Self.sourceKind(calendar.type),
          isSubscribed: calendar.type == .subscription,
          allowsContentModifications: calendar.allowsContentModifications
        )
      }
      .sorted { left, right in
        left.title.localizedStandardCompare(right.title) == .orderedAscending
      }
  }

  func occurrences(
    selectedSourceIdentityHMACs: Set<Data>,
    matchingFrom startDate: Date,
    through endDate: Date
  ) throws -> [SystemCalendarOccurrenceSnapshot] {
    guard authorizationState() == .fullAccess else {
      throw authorizationError(for: authorizationState())
    }
    let calendars = try eventStore.calendars(for: .event).filter { calendar in
      selectedSourceIdentityHMACs.contains(
        try digest(["calendar", calendar.calendarIdentifier])
      )
    }
    guard calendars.count == selectedSourceIdentityHMACs.count else {
      throw CalendarDomainError.selectedSourceUnavailable
    }
    guard startDate < endDate else { throw CalendarDomainError.invalidScanWindow }

    let predicate = eventStore.predicateForEvents(
      withStart: startDate,
      end: endDate,
      calendars: calendars
    )
    return try eventStore.events(matching: predicate).compactMap { event in
      guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate,
        end > start
      else {
        return nil
      }
      let sourceIdentity = try digest(["calendar", calendar.calendarIdentifier])
      let seriesIdentifier = event.calendarItemIdentifier
      let occurrenceIdentifier =
        event.eventIdentifier ?? "\(seriesIdentifier)|\(start.timeIntervalSince1970)"
      let timeZone = event.timeZone ?? TimeZone.current
      let localStartDate = Self.localDate(start, timeZone: timeZone)
      let localEndDate = Self.localDate(end, timeZone: timeZone)
      let title = normalizedOptional(event.title)
      let location = normalizedOptional(event.location)
      return SystemCalendarOccurrenceSnapshot(
        sourceExternalIdentityHMAC: sourceIdentity,
        seriesExternalIdentityHMAC: try digest([
          "series", calendar.calendarIdentifier, seriesIdentifier,
        ]),
        occurrenceExternalIdentityHMAC: try digest([
          "occurrence", calendar.calendarIdentifier, occurrenceIdentifier,
        ]),
        matchKeyHMAC: try digest([
          "match", seriesIdentifier, String(start.timeIntervalSince1970),
        ]),
        sourceFingerprint: try digest([
          "fingerprint",
          title ?? "",
          location ?? "",
          String(start.timeIntervalSince1970),
          String(end.timeIntervalSince1970),
          timeZone.identifier,
          event.isAllDay ? "1" : "0",
          event.status == .canceled ? "1" : "0",
        ]),
        hasRecurrence: !(event.recurrenceRules?.isEmpty ?? true),
        isCancelled: event.status == .canceled,
        isAllDay: event.isAllDay,
        startsAt: start,
        endsAt: end,
        localStartDate: localStartDate,
        localEndDateExclusive: localEndDate,
        timeZoneIdentifier: timeZone.identifier,
        title: title,
        locationText: location
      )
    }
  }

  nonisolated func eventStoreChanges() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let token = NotificationToken(
        value: NotificationCenter.default.addObserver(
          forName: .EKEventStoreChanged,
          object: nil,
          queue: .main
        ) { _ in
          continuation.yield()
        }
      )
      continuation.onTermination = { @Sendable _ in
        NotificationCenter.default.removeObserver(token.value)
      }
    }
  }

  private func digest(_ components: [String]) throws -> Data {
    let keyData: Data
    if let cachedKeyData {
      keyData = cachedKeyData
    } else {
      let loaded = try keyStore.loadOrCreateKey()
      cachedKeyData = loaded
      keyData = loaded
    }
    var payload = Data()
    for component in components {
      let bytes = Data(component.utf8)
      var length = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
      payload.append(bytes)
    }
    return Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: keyData)))
  }

  private func normalizedOptional(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return String(value.prefix(500))
  }

  private func authorizationError(for state: CalendarAuthorizationState) -> CalendarDomainError {
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

  private nonisolated static func authorizationState(
    from status: EKAuthorizationStatus
  ) -> CalendarAuthorizationState {
    switch status {
    case .notDetermined:
      .notDetermined
    case .fullAccess:
      .fullAccess
    case .writeOnly:
      .writeOnly
    case .denied:
      .denied
    case .restricted:
      .restricted
    case .authorized:
      .fullAccess
    @unknown default:
      .restricted
    }
  }

  private nonisolated static func sourceKind(_ type: EKCalendarType) -> CalendarSourceKind {
    switch type {
    case .local:
      .local
    case .exchange:
      .exchange
    case .calDAV:
      .caldav
    case .subscription:
      .subscribed
    case .birthday:
      .birthdays
    @unknown default:
      .unknown
    }
  }

  private nonisolated static func localDate(_ date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }
}
