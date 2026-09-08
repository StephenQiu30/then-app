import Foundation

nonisolated struct LocalDataExportArtifact: Identifiable, Sendable, Equatable {
  let id: UUID
  let fileURL: URL

  init(id: UUID = UUID(), fileURL: URL) {
    self.id = id
    self.fileURL = fileURL
  }
}

nonisolated struct LocalDataExportDocument: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let exportedAt: Date
  let appName: String
  let profile: Profile
  let accounts: [Account]
  let transactions: [Transaction]
  let postings: [Posting]
  let tripPlans: [TripPlan]
  let journeys: [Journey]
  let transactionJourneyLinks: [TransactionJourneyLink]

  struct Profile: Codable, Sendable, Equatable {
    let baseCurrencyCode: String
    let baseCurrencyState: String
  }

  struct Account: Codable, Sendable, Equatable {
    let id: String
    let parentID: String?
    let kind: String
    let subtype: String
    let name: String
    let nativeCurrencyCode: String
    let configurationState: String
    let status: String
    let systemKey: String?
    let displayOrder: Int
    let createdAt: Date
    let updatedAt: Date
  }

  struct Transaction: Codable, Sendable, Equatable {
    let id: String
    let canonicalRootID: String
    let kind: String
    let status: String
    let source: String
    let occurredAt: Date
    let timezoneIdentifier: String
    let payee: String?
    let note: String?
    let refundOfID: String?
    let reversalOfID: String?
    let replacementForID: String?
    let createdAt: Date
  }

  struct Posting: Codable, Sendable, Equatable {
    let transactionID: String
    let ledgerAccountID: String
    let direction: String
    let amountMinor: Int64
    let currencyCode: String
    let memo: String?
  }

  struct TripPlan: Codable, Sendable, Equatable {
    let id: String
    let displayName: String?
    let originName: String?
    let originAddress: String?
    let destinationName: String
    let destinationAddress: String?
    let transportMode: String
    let targetArrivalAt: Date
    let plannedDepartureAt: Date?
    let timezoneIdentifier: String
    let preparationBufferSeconds: Int
    let status: String
    let createdAt: Date
    let updatedAt: Date
  }

  struct Journey: Codable, Sendable, Equatable {
    let id: String
    let tripPlanID: String?
    let status: String
    let transportMode: String
    let startedAt: Date
    let endedAt: Date?
    let distanceMeters: Double?
    let durationSeconds: Double?
    let captureCompleteness: String
    let terminationReason: String?
  }

  struct TransactionJourneyLink: Codable, Sendable, Equatable {
    let transactionRootID: String
    let journeyID: String
    let role: String
    let confirmedAt: Date
  }
}

nonisolated enum LocalDataManagementError: Error, Sendable, Equatable {
  case profileNotFound
  case insufficientStorage
  case exportWriteFailed
  case exportCleanupFailed
  case localDataResetFailed
}

nonisolated protocol LocalDataManaging: Sendable {
  func createExport() async throws -> LocalDataExportArtifact
  func cleanupExport(_ artifact: LocalDataExportArtifact) async throws
  func clearCalendarCache() async throws
  func resetAllLocalData() async throws
}
