import Foundation
import GRDB
import Testing
@testable import ThenApp

struct OutfitFeedbackRepositoryTests {
  private struct Fixture {
    let root: URL
    let store: GRDBWardrobeRepository

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      store = GRDBWardrobeRepository(directory: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private func garment(_ store: GRDBWardrobeRepository) async throws -> WardrobeItem {
    try await store.create(id: UUID(), input: WardrobeInput(name: "证据测试上衣", category: .top,
      availability: .wearable, attributes: .init()), source: .wardrobe)
  }

  private func event(_ store: GRDBWardrobeRepository, garment: WardrobeItem) async throws -> WearEvent {
    let day = try OutfitLocalDate(instant: Date(), timeZone: "Asia/Shanghai")
    let existing = try await store.listWearEvents(on: day)
    let input = try WearEventInput(localDate: day, timeZone: "Asia/Shanghai",
      items: [.init(itemID: garment.id, revision: garment.revision)],
      duplicateConfirmation: Set(existing.map { .init(id: $0.id, revision: $0.revision) }))
    return try #require(try await store.mutateWearEvent(.init(id: UUID(), eventID: UUID(),
      action: .save(input, expectedRevision: nil))))
  }

  private func save(_ store: GRDBWardrobeRepository, event: WearEvent,
                    input: OutfitFeedbackInput, feedback: OutfitFeedback? = nil,
                    mutationID: UUID = UUID()) async throws -> OutfitFeedback {
    try #require(try await store.mutateFeedback(.init(id: mutationID,
      feedbackID: feedback?.id ?? UUID(), wearEventID: event.id,
      action: .save(input, expectedRevision: feedback?.revision))))
  }

  @Test func inputRequiresExplicitFactAndNormalizesLocalNote() throws {
    #expect(throws: OutfitFeedbackError.invalidInput) { try OutfitFeedbackInput() }
    #expect(throws: OutfitFeedbackError.invalidInput) { try OutfitFeedbackInput(note: "   ") }
    #expect(throws: OutfitFeedbackError.invalidInput) { try OutfitFeedbackInput(note: String(repeating: "字", count: 241)) }
    #expect(throws: OutfitFeedbackError.invalidInput) { try OutfitFeedbackInput(note: "a\u{0000}b") }
    let input = try OutfitFeedbackInput(issueTags: [.shoeDiscomfort], note: "  本地备注  ")
    #expect(input.note == "本地备注")
  }

  @Test func saveUpdateDeleteAreRevisionedAndIdempotent() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let item = try await garment(fixture.store)
    let wear = try await event(fixture.store, garment: item)
    let mutationID = UUID(), feedbackID = UUID()
    let firstInput = try OutfitFeedbackInput(thermalComfort: .cold, issueTags: [.rainUnsuitable], note: "偏冷")
    let command = OutfitFeedbackMutation(id: mutationID, feedbackID: feedbackID, wearEventID: wear.id,
      action: .save(firstInput, expectedRevision: nil))
    let first = try #require(try await fixture.store.mutateFeedback(command))
    #expect(try await fixture.store.mutateFeedback(command) == first)
    await #expect(throws: OutfitFeedbackError.conflict) {
      try await fixture.store.mutateFeedback(.init(id: mutationID, feedbackID: feedbackID,
        wearEventID: wear.id, action: .save(try OutfitFeedbackInput(thermalComfort: .hot), expectedRevision: nil)))
    }
    let updated = try await save(fixture.store, event: wear,
      input: OutfitFeedbackInput(activityComfort: .comfortable), feedback: first)
    #expect(updated.revision == 2 && updated.input.thermalComfort == nil)
    let deletion = OutfitFeedbackMutation(id: UUID(), feedbackID: updated.id, wearEventID: wear.id,
      action: .delete(expectedRevision: updated.revision))
    #expect(try await fixture.store.mutateFeedback(deletion) == nil)
    #expect(try await fixture.store.mutateFeedback(deletion) == nil)
    #expect(try await fixture.store.readFeedback(wearEventID: wear.id) == nil)
    let recreated = try await save(fixture.store, event: wear,
      input: OutfitFeedbackInput(repeatIntent: .yes))
    #expect(recreated.revision == 1)
    try await fixture.store.close()
  }

  @Test func evidenceRebuildHandlesCorrectionWithdrawalAndIgnoresNoteAndTags() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let item = try await garment(fixture.store)
    let firstEvent = try await event(fixture.store, garment: item)
    let secondEvent = try await event(fixture.store, garment: item)
    let first = try await save(fixture.store, event: firstEvent,
      input: OutfitFeedbackInput(thermalComfort: .cold, issueTags: [.shoeDiscomfort], note: "自由文本"))
    let second = try await save(fixture.store, event: secondEvent,
      input: OutfitFeedbackInput(thermalComfort: .cold))
    let cold = try #require(try await fixture.store.rebuildPreferenceEvidence().first)
    #expect(cold.dimension == .thermalComfort && cold.value == "cold")
    #expect(cold.winningSampleCount == 2 && cold.totalSampleCount == 2)

    _ = try await save(fixture.store, event: firstEvent,
      input: OutfitFeedbackInput(thermalComfort: .comfortable, issueTags: [.maintenanceNeeded], note: "已修改"),
      feedback: first)
    #expect(try await fixture.store.rebuildPreferenceEvidence().isEmpty)
    _ = try await fixture.store.mutateFeedback(.init(id: UUID(), feedbackID: second.id,
      wearEventID: secondEvent.id, action: .delete(expectedRevision: second.revision)))
    #expect(try await fixture.store.rebuildPreferenceEvidence().isEmpty)
    try await fixture.store.close()
  }

  @Test func eventDeletionCleansFeedbackAndRedactionRemovesItsEvidenceBucket() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let item = try await garment(fixture.store)
    let firstEvent = try await event(fixture.store, garment: item)
    let secondEvent = try await event(fixture.store, garment: item)
    _ = try await save(fixture.store, event: firstEvent, input: OutfitFeedbackInput(repeatIntent: .yes))
    _ = try await save(fixture.store, event: secondEvent, input: OutfitFeedbackInput(repeatIntent: .yes))
    #expect(try await fixture.store.rebuildPreferenceEvidence().count == 1)

    _ = try await fixture.store.mutateWearEvent(.init(id: UUID(), eventID: firstEvent.id,
      action: .delete(expectedRevision: firstEvent.revision)))
    #expect(try await fixture.store.readFeedback(wearEventID: firstEvent.id) == nil)
    #expect(try await fixture.store.rebuildPreferenceEvidence().isEmpty)

    let impact = try await fixture.store.deletionImpact(id: item.id)
    try await fixture.store.delete(id: item.id, expectedRevision: item.revision,
      impact: impact, policy: .redactSnapshots)
    #expect(try await fixture.store.readFeedback(wearEventID: secondEvent.id) != nil)
    #expect(try await fixture.store.rebuildPreferenceEvidence().isEmpty)
    let database = try DatabaseQueue(path: fixture.root.appendingPathComponent("wardrobe.sqlite").path)
    let violations = try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1
    }
    #expect(violations == 0)
    try database.close(); try await fixture.store.close()
  }
}
