import CoreLocation
import Foundation
import Security

nonisolated struct JourneyDeviceIdentityStore: Sendable {
  private let service = "com.stephenqiu.then.journey-device"
  private let account = "recording-device-id-v1"

  func loadOrCreateID() throws -> UUID {
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
    if readStatus == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8),
      let identifier = UUID(uuidString: value)
    {
      return identifier
    }
    guard readStatus == errSecItemNotFound else {
      throw JourneyRecordingError.corruptedStoredJourney
    }

    let identifier = UUID()
    var addQuery = baseQuery
    addQuery[kSecValueData as String] = Data(identifier.uuidString.lowercased().utf8)
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess { return identifier }
    if addStatus == errSecDuplicateItem {
      var duplicateResult: CFTypeRef?
      guard SecItemCopyMatching(readQuery as CFDictionary, &duplicateResult) == errSecSuccess,
        let duplicateData = duplicateResult as? Data,
        let duplicateValue = String(data: duplicateData, encoding: .utf8),
        let duplicateIdentifier = UUID(uuidString: duplicateValue)
      else {
        throw JourneyRecordingError.corruptedStoredJourney
      }
      return duplicateIdentifier
    }
    throw JourneyRecordingError.corruptedStoredJourney
  }
}

actor CoreLocationJourneyDriver: JourneyLocationDriver {
  private var serviceSession: CLServiceSession?
  private var backgroundActivitySession: CLBackgroundActivitySession?
  private var updateTask: Task<Void, Never>?

  func start(
    transportMode: TripTransportMode,
    handler: @escaping @Sendable (JourneyLocationEvent) async -> Void
  ) async throws {
    stopSessions()
    serviceSession = CLServiceSession(authorization: .whenInUse)
    backgroundActivitySession = CLBackgroundActivitySession()
    let configuration: CLLocationUpdate.LiveConfiguration =
      switch transportMode {
      case .driving: .automotiveNavigation
      case .walking: .fitness
      case .transit: .otherNavigation
      }
    updateTask = Task { [weak self] in
      do {
        for try await update in CLLocationUpdate.liveUpdates(configuration) {
          guard !Task.isCancelled else { return }
          if let interruption = Self.interruption(from: update) {
            await handler(.interrupted(interruption))
            return
          }
          guard let location = update.location else { continue }
          let sample = JourneyLocationSample(
            id: UUID(),
            recordedAt: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
            courseDegrees: location.course >= 0 ? location.course : nil
          )
          await handler(.sample(sample))
        }
      } catch is CancellationError {
        return
      } catch {
        await handler(.interrupted(.systemInterruption))
      }
      await self?.clearFinishedTask()
    }
  }

  func stop() async {
    stopSessions()
  }

  private func clearFinishedTask() {
    updateTask = nil
  }

  private func stopSessions() {
    updateTask?.cancel()
    updateTask = nil
    backgroundActivitySession?.invalidate()
    backgroundActivitySession = nil
    serviceSession?.invalidate()
    serviceSession = nil
  }

  private nonisolated static func interruption(
    from update: CLLocationUpdate
  ) -> JourneyInterruptionReason? {
    if update.authorizationDenied { return .permissionDenied }
    if update.authorizationDeniedGlobally { return .locationServicesDisabled }
    if update.authorizationRestricted { return .authorizationRestricted }
    if update.insufficientlyInUse { return .insufficientlyInUse }
    if update.locationUnavailable { return .locationUnavailable }
    if update.accuracyLimited { return .accuracyLimited }
    return nil
  }
}
