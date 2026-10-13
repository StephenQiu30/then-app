import Foundation

nonisolated enum OutfitPlanError: Error, Equatable {
  case invalidInput, invalidDate, invalidTimeZone, conflict, notFound, unavailableItems, storageUnavailable
}

/// A calendar day, never an instant at UTC midnight.
nonisolated struct OutfitLocalDate: Hashable, Comparable, Sendable, Codable {
  let value: String

  init(_ value: String) throws {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard value.utf8.count == 10, parts.count == 3,
          parts[0].utf8.count == 4, parts[1].utf8.count == 2, parts[2].utf8.count == 2,
          parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          (1...9999).contains(year) else { throw OutfitPlanError.invalidDate }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components),
          calendar.dateComponents([.year, .month, .day], from: date) == components else {
      throw OutfitPlanError.invalidDate
    }
    self.value = value
  }

  init(instant: Date, timeZone: String) throws {
    guard instant.timeIntervalSince1970.isFinite else { throw OutfitPlanError.invalidDate }
    let zone = try Self.zone(timeZone)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let components = calendar.dateComponents([.year, .month, .day], from: instant)
    guard let year = components.year, let month = components.month, let day = components.day else {
      throw OutfitPlanError.invalidDate
    }
    try self.init(String(format: "%04d-%02d-%02d", year, month, day))
  }

  static func zone(_ identifier: String) throws -> TimeZone {
    guard identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier),
          let zone = TimeZone(identifier: identifier) else { throw OutfitPlanError.invalidTimeZone }
    return zone
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

  init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

nonisolated struct OutfitSelection: Equatable, Sendable, Codable {
  let itemID: UUID
  let revision: Int
}

nonisolated struct OutfitPlanInput: Equatable, Sendable, Codable {
  let localDate: OutfitLocalDate
  let timeZone: String
  let contextSummary: String?
  let items: [OutfitSelection]
  let confirmedUnavailable: Set<UUID>

  init(localDate: OutfitLocalDate, timeZone: String, contextSummary: String?, items: [OutfitSelection],
       confirmedUnavailable: Set<UUID> = []) throws {
    _ = try OutfitLocalDate.zone(timeZone)
    let summary = contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...20).contains(items.count), Set(items.map(\.itemID)).count == items.count,
          items.allSatisfy({ $0.revision > 0 }), confirmedUnavailable.isSubset(of: Set(items.map(\.itemID))),
          (summary?.count ?? 0) <= 120,
          summary?.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) != true else {
      throw OutfitPlanError.invalidInput
    }
    self.localDate = localDate
    self.timeZone = timeZone
    self.contextSummary = summary?.isEmpty == true ? nil : summary
    self.items = items
    self.confirmedUnavailable = confirmedUnavailable
  }
}

nonisolated enum OutfitPlanStatus: String, Sendable { case active, completed, notWorn, cancelled }

nonisolated struct OutfitItemContent: Equatable, Sendable {
  let itemID: UUID
  let revision: Int
  let input: WardrobeInput
  let photoAssetID: UUID?
}

nonisolated struct OutfitPlanItemSnapshot: Identifiable, Equatable, Sendable {
  let ordinal: Int
  /// nil means deliberately redacted, not a missing query or an unknown garment.
  let content: OutfitItemContent?
  var id: Int { ordinal }
}

nonisolated struct OutfitPlan: Identifiable, Equatable, Sendable {
  let id: UUID
  let localDate: OutfitLocalDate
  let timeZone: String
  let contextSummary: String?
  let status: OutfitPlanStatus
  let revision: Int
  let createdAt: Date
  let updatedAt: Date
  let items: [OutfitPlanItemSnapshot]
}

nonisolated struct OutfitPlanMutation: Sendable {
  enum Action: Sendable {
    case save(OutfitPlanInput, expectedRevision: Int?)
    case cancel(expectedRevision: Int)
    case markNotWorn(expectedRevision: Int)
    case restoreActive(expectedRevision: Int)
    case delete(expectedRevision: Int)
  }
  let id: UUID
  let planID: UUID
  let action: Action
}

nonisolated struct OutfitPlanCursor: Equatable, Sendable {
  let localDate: OutfitLocalDate
  let createdAt: Date
  let id: UUID
}

nonisolated struct OutfitPlanPage: Sendable {
  let plans: [OutfitPlan]
  let nextCursor: OutfitPlanCursor?
}

nonisolated protocol OutfitPlanRepository: Sendable {
  func listPlans(on date: OutfitLocalDate?, after cursor: OutfitPlanCursor?) async throws -> OutfitPlanPage
  func readPlan(id: UUID) async throws -> OutfitPlan
  /// nil is a confirmed permanent deletion. Other mutations return the committed plan.
  func mutatePlan(_ command: OutfitPlanMutation) async throws -> OutfitPlan?
}
