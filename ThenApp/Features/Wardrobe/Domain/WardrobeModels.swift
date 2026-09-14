import Foundation

nonisolated enum WardrobeCategory: String, CaseIterable, Sendable {
  case top, bottom, onePiece, outerwear, shoes, bag, accessory
}

nonisolated enum WardrobeAvailability: String, CaseIterable, Sendable {
  case wearable, laundry, lentOut, packed
}

nonisolated enum WardrobeSource: String, Sendable {
  case wardrobe, quickAdd
}

nonisolated enum WardrobeError: Error, Equatable {
  case invalidName
  case conflict
  case notFound
  case invalidStoredData
  case newerDatabase
  case storageUnavailable
  case deletionCleanupPending
}

/// Only facts explicitly confirmed by the user. Unimplemented attributes remain unknown.
nonisolated struct WardrobeInput: Equatable, Sendable {
  let name: String
  let category: WardrobeCategory
  let availability: WardrobeAvailability

  init(name: String, category: WardrobeCategory, availability: WardrobeAvailability) throws {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(cleaned.count),
          !cleaned.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
      throw WardrobeError.invalidName
    }
    self.name = cleaned
    self.category = category
    self.availability = availability
  }
}

nonisolated struct WardrobeItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let input: WardrobeInput
  let source: WardrobeSource
  let revision: Int
  let createdAt: Date
  let updatedAt: Date
}

nonisolated struct WardrobeFilter: Sendable {
  var search = ""
  var category: WardrobeCategory?
  var availability: WardrobeAvailability? = .wearable
}

nonisolated protocol WardrobeRepository: Sendable {
  func prepare() async throws
  func list(_ filter: WardrobeFilter) async throws -> [WardrobeItem]
  func create(id: UUID, input: WardrobeInput, source: WardrobeSource) async throws -> WardrobeItem
  func update(id: UUID, expectedRevision: Int, input: WardrobeInput) async throws -> WardrobeItem
  func deletionImpact(id: UUID) async throws -> WardrobeDeletionImpact
  func delete(id: UUID, expectedRevision: Int, impact: WardrobeDeletionImpact, policy: WardrobeHistoryDeletionPolicy) async throws
}

nonisolated enum WardrobeHistoryDeletionPolicy: Sendable { case redactSnapshots, deleteAffectedPlans }

nonisolated struct WardrobeAffectedPlan: Equatable, Sendable {
  let id: UUID
  let revision: Int
}

nonisolated struct WardrobeDeletionImpact: Equatable, Sendable {
  let plans: [WardrobeAffectedPlan]
}
