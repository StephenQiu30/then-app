import Foundation

nonisolated enum WearEventError: Error, Equatable {
  case invalidInput
  case invalidDate
  case conflict
  case notFound
  case unavailableItems
  case duplicateConfirmationRequired([WearEventCandidate])
  case storageUnavailable
}

nonisolated enum WearEventCompleteness: String, Sendable, Codable, CaseIterable {
  case partial
  case complete
}

nonisolated enum WearEventSourceKind: String, Sendable, Codable {
  case followedPlan
  case changedPlan
  case differentOutfit
  case unplanned
}

nonisolated struct WearEventCandidate: Equatable, Hashable, Sendable, Codable {
  let id: UUID
  let revision: Int
}

nonisolated struct WearEventInput: Equatable, Sendable, Codable {
  let localDate: OutfitLocalDate
  let timeZone: String
  let completeness: WearEventCompleteness
  let contextSummary: String?
  let items: [OutfitSelection]
  let laundryItemIDs: Set<UUID>
  let confirmedUnavailable: Set<UUID>
  let sourcePlanID: UUID?
  let sourcePlanRevision: Int?
  let sourceKind: WearEventSourceKind
  let duplicateConfirmation: Set<WearEventCandidate>

  init(
    localDate: OutfitLocalDate,
    timeZone: String,
    completeness: WearEventCompleteness = .partial,
    contextSummary: String? = nil,
    items: [OutfitSelection],
    laundryItemIDs: Set<UUID> = [],
    confirmedUnavailable: Set<UUID> = [],
    sourcePlanID: UUID? = nil,
    sourcePlanRevision: Int? = nil,
    sourceKind: WearEventSourceKind = .unplanned,
    duplicateConfirmation: Set<WearEventCandidate> = []
  ) throws {
    _ = try OutfitLocalDate.zone(timeZone)
    let summary = contextSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    let itemIDs = Set(items.map(\.itemID))
    guard (1...20).contains(items.count), itemIDs.count == items.count,
          items.allSatisfy({ $0.revision > 0 }),
          laundryItemIDs.isSubset(of: itemIDs), confirmedUnavailable.isSubset(of: itemIDs),
          (summary?.count ?? 0) <= 120,
          summary?.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) != true,
          (sourcePlanID == nil) == (sourcePlanRevision == nil),
          sourcePlanRevision == nil || (sourcePlanRevision ?? 0) > 0,
          sourceKind == .unplanned || sourcePlanID != nil,
          sourcePlanID != nil || sourceKind == .unplanned,
          duplicateConfirmation.allSatisfy({ $0.revision > 0 })
    else { throw WearEventError.invalidInput }
    self.localDate = localDate
    self.timeZone = timeZone
    self.completeness = completeness
    self.contextSummary = summary?.isEmpty == true ? nil : summary
    self.items = items
    self.laundryItemIDs = laundryItemIDs
    self.confirmedUnavailable = confirmedUnavailable
    self.sourcePlanID = sourcePlanID
    self.sourcePlanRevision = sourcePlanRevision
    self.sourceKind = sourceKind
    self.duplicateConfirmation = duplicateConfirmation
  }
}

nonisolated struct WearEvent: Identifiable, Equatable, Sendable {
  let id: UUID
  let localDate: OutfitLocalDate
  let timeZone: String
  let completeness: WearEventCompleteness
  let contextSummary: String?
  let sourcePlanID: UUID?
  let sourcePlanRevision: Int?
  let sourceKind: WearEventSourceKind
  let revision: Int
  let createdAt: Date
  let updatedAt: Date
  let items: [OutfitPlanItemSnapshot]
}

nonisolated struct WearEventMutation: Sendable {
  enum Action: Sendable {
    case save(WearEventInput, expectedRevision: Int?)
    case delete(expectedRevision: Int)
  }

  let id: UUID
  let eventID: UUID
  let action: Action
}

nonisolated enum OutfitTimelineEntry: Identifiable, Equatable, Sendable {
  case plan(OutfitPlan)
  case wear(WearEvent)

  var entityID: UUID {
    switch self {
    case .plan(let plan): plan.id
    case .wear(let event): event.id
    }
  }

  var id: String {
    switch self {
    case .plan: "plan:\(entityID.uuidString)"
    case .wear: "wear:\(entityID.uuidString)"
    }
  }

  var localDate: OutfitLocalDate {
    switch self {
    case .plan(let plan): plan.localDate
    case .wear(let event): event.localDate
    }
  }

  var createdAt: Date {
    switch self {
    case .plan(let plan): plan.createdAt
    case .wear(let event): event.createdAt
    }
  }
}

nonisolated struct OutfitTimelineCursor: Equatable, Sendable {
  let localDate: OutfitLocalDate
  let createdAt: Date
  let kind: String
  let id: UUID
}

nonisolated struct OutfitTimelinePage: Sendable {
  let entries: [OutfitTimelineEntry]
  let nextCursor: OutfitTimelineCursor?
}

nonisolated protocol WearEventRepository: Sendable {
  func listWearEvents(on date: OutfitLocalDate?) async throws -> [WearEvent]
  func readWearEvent(id: UUID) async throws -> WearEvent
  func mutateWearEvent(_ command: WearEventMutation) async throws -> WearEvent?
  func wearCount(itemID: UUID) async throws -> Int
  func listTimeline(after cursor: OutfitTimelineCursor?) async throws -> OutfitTimelinePage
}
