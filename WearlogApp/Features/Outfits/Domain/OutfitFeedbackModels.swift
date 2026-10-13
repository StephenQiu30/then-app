import Foundation

nonisolated enum OutfitFeedbackError: Error, Equatable {
  case invalidInput
  case conflict
  case notFound
}

nonisolated enum ThermalComfort: String, Codable, CaseIterable, Sendable {
  case cold, comfortable, hot
}

nonisolated enum ActivityComfort: String, Codable, CaseIterable, Sendable {
  case uncomfortable, okay, comfortable
}

nonisolated enum OccasionFit: String, Codable, CaseIterable, Sendable {
  case tooCasual, right, tooFormal
}

nonisolated enum RepeatIntent: String, Codable, CaseIterable, Sendable {
  case yes, unsure, no
}

nonisolated enum OutfitFeedbackIssueTag: String, Codable, CaseIterable, Sendable {
  case shoeDiscomfort
  case awkwardLayering
  case rainUnsuitable
  case insufficientPockets
  case maintenanceNeeded
}

nonisolated struct OutfitFeedbackInput: Equatable, Codable, Sendable {
  let thermalComfort: ThermalComfort?
  let activityComfort: ActivityComfort?
  let occasionFit: OccasionFit?
  let repeatIntent: RepeatIntent?
  let issueTags: Set<OutfitFeedbackIssueTag>
  let note: String?

  init(thermalComfort: ThermalComfort? = nil, activityComfort: ActivityComfort? = nil,
       occasionFit: OccasionFit? = nil, repeatIntent: RepeatIntent? = nil,
       issueTags: Set<OutfitFeedbackIssueTag> = [], note: String? = nil) throws {
    let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard issueTags.count <= 5, (normalized?.count ?? 0) <= 240,
          normalized?.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) != true,
          thermalComfort != nil || activityComfort != nil || occasionFit != nil || repeatIntent != nil
            || !issueTags.isEmpty || normalized?.isEmpty == false else {
      throw OutfitFeedbackError.invalidInput
    }
    self.thermalComfort = thermalComfort
    self.activityComfort = activityComfort
    self.occasionFit = occasionFit
    self.repeatIntent = repeatIntent
    self.issueTags = issueTags
    self.note = normalized?.isEmpty == true ? nil : normalized
  }
}

nonisolated struct OutfitFeedback: Identifiable, Equatable, Sendable {
  let id: UUID
  let wearEventID: UUID
  let input: OutfitFeedbackInput
  let revision: Int
  let createdAt: Date
  let updatedAt: Date
}

nonisolated struct OutfitFeedbackMutation: Sendable {
  enum Action: Sendable {
    case save(OutfitFeedbackInput, expectedRevision: Int?)
    case delete(expectedRevision: Int)
  }

  let id: UUID
  let feedbackID: UUID
  let wearEventID: UUID
  let action: Action
}

nonisolated enum PreferenceEvidenceDimension: String, Codable, CaseIterable, Sendable {
  case thermalComfort, activityComfort, occasionFit, repeatIntent
}

nonisolated struct PreferenceEvidence: Equatable, Sendable {
  let itemIDs: [UUID]
  let dimension: PreferenceEvidenceDimension
  let value: String
  let winningSampleCount: Int
  let totalSampleCount: Int
  let updatedAt: Date
}

nonisolated protocol OutfitFeedbackRepository: Sendable {
  func readFeedback(wearEventID: UUID) async throws -> OutfitFeedback?
  func mutateFeedback(_ command: OutfitFeedbackMutation) async throws -> OutfitFeedback?
  func rebuildPreferenceEvidence() async throws -> [PreferenceEvidence]
}
