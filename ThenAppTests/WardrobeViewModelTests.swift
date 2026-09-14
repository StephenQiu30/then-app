import Foundation
import Testing
@testable import ThenApp

@MainActor
struct WardrobeViewModelTests {
  @Test func bootFailurePreservesRepositoryAndRetryLoadsSavedItems() async throws {
    let repository = Stub()
    await repository.failPreparationOnce()
    let model = OOTDAppModel(repository: repository)
    await model.start()
    #expect(model.phase == .failed)
    #expect(model.error == .storageUnavailable)
    model.requestRetry()
    await model.start()
    #expect(model.phase == .ready)
    #expect(model.error == nil)
    #expect(await repository.preparations == 2)
  }

  @Test func validationDoesNotWriteAndCancelDropsOnlyDraft() async throws {
    let repository = Stub()
    let model = WardrobeViewModel(repository: repository)
    model.beginAdding(source: .quickAdd)
    let draft = try #require(model.editor)
    draft.submit(.save)
    await model.perform(draft)
    #expect(draft.needsCategory)
    #expect(await repository.creations == 0)
    draft.category = .top
    draft.submit(.save)
    await model.perform(draft)
    #expect(draft.error == .invalidName)
    #expect(await repository.creations == 0)
    model.editor = nil
    #expect(model.items.isEmpty)
  }

  @Test func failedSaveKeepsDraftIdentityAndRetryCommitsOnce() async throws {
    let repository = Stub()
    await repository.failCreationOnce()
    let model = WardrobeViewModel(repository: repository)
    model.beginAdding(source: .wardrobe)
    let draft = try #require(model.editor)
    draft.name = "白色 T 恤"
    draft.category = .top
    draft.availability = .laundry
    let id = draft.id
    draft.submit(.save)
    draft.submit(.save)
    #expect(draft.request == 1)
    await model.perform(draft)
    #expect(draft.error == .storageUnavailable)
    #expect(draft.name == "白色 T 恤" && draft.id == id)
    #expect(model.editor === draft)
    draft.submit(.save)
    await model.perform(draft)
    #expect(model.editor == nil)
    #expect(model.items.count == 1)
    #expect(model.visibleItems.first?.id == id)
    #expect(model.availability == .laundry)
  }

  @Test func pendingDeletionRemovesVisiblePrivateContentAndCanRetry() async throws {
    let repository = Stub()
    let input = try WardrobeInput(name: "要删除的衣物", category: .top, availability: .wearable)
    let saved = try await repository.create(id: UUID(), input: input, source: .wardrobe)
    let model = WardrobeViewModel(repository: repository)
    try await model.load()
    model.beginEditing(saved)
    let draft = try #require(model.editor)
    await repository.failCleanupOnce()
    draft.submit(.reviewDeletion)
    await model.perform(draft)
    draft.submit(.delete)
    await model.perform(draft)
    #expect(model.items.isEmpty)
    #expect(draft.isDeleted && draft.name.isEmpty && draft.category == nil)
    #expect(draft.canRetryDeletion)
    #expect(draft.error == .deletionCleanupPending)
    let request = draft.request
    draft.submit(.save)
    #expect(draft.request == request)
    draft.submit(.delete)
    await model.perform(draft)
    #expect(model.editor == nil)
  }

  private actor Stub: WardrobeRepository, WardrobePhotoRepository, OutfitPlanRepository {
    func listPlans(on: OutfitLocalDate?, after: OutfitPlanCursor?) async throws -> OutfitPlanPage { .init(plans: [], nextCursor: nil) }
    func readPlan(id: UUID) async throws -> OutfitPlan { throw OutfitPlanError.notFound }
    func mutatePlan(_ command: OutfitPlanMutation) async throws -> OutfitPlan? { throw OutfitPlanError.storageUnavailable }

    func saveItemWithPhoto(_ edit: WardrobeItemPhotoEdit, photo: WardrobePhotoWrite) throws -> WardrobeItemPhotoSaveResult { throw WardrobeError.storageUnavailable }
    func savePhoto(_ photo: WardrobePhotoWrite, itemID: UUID, expectedRevision: Int) throws -> WardrobePhotoSaveResult { throw WardrobeError.storageUnavailable }
    func photoMetadata(itemID: UUID) -> WardrobePhotoMetadata? { nil }
    func readPhoto(itemID: UUID, purpose: WardrobePhotoPurpose, maximumBytes: Int) -> WardrobePhotoRead? { nil }
    func removePhoto(id: UUID, itemID: UUID, expectedRevision: Int) throws { throw WardrobeError.storageUnavailable }
    func hasPendingPhotoCleanup() -> Bool { false }
    func retryPhotoCleanup() {}
    var preparations = 0
    var creations = 0
    private var failsPreparation = false
    private var failsCreation = false
    private var failsCleanup = false
    private var items: [WardrobeItem] = []
    func failPreparationOnce() { failsPreparation = true }
    func failCreationOnce() { failsCreation = true }
    func failCleanupOnce() { failsCleanup = true }
    func prepare() throws {
      preparations += 1
      if failsPreparation { failsPreparation = false; throw WardrobeError.storageUnavailable }
    }
    func list(_ filter: WardrobeFilter) -> [WardrobeItem] { items }
    func create(id: UUID, input: WardrobeInput, source: WardrobeSource) throws -> WardrobeItem {
      creations += 1
      if failsCreation { failsCreation = false; throw WardrobeError.storageUnavailable }
      let item = WardrobeItem(id: id, input: input, source: source, revision: 1,
                              createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))
      items.append(item)
      return item
    }
    func update(id: UUID, expectedRevision: Int, input: WardrobeInput) throws -> WardrobeItem {
      throw WardrobeError.conflict
    }
    func deletionImpact(id: UUID) -> WardrobeDeletionImpact { .init(plans: []) }
    func delete(id: UUID, expectedRevision: Int, impact: WardrobeDeletionImpact, policy: WardrobeHistoryDeletionPolicy) throws {
      items.removeAll { $0.id == id }
      if failsCleanup { failsCleanup = false; throw WardrobeError.deletionCleanupPending }
    }
  }
}
