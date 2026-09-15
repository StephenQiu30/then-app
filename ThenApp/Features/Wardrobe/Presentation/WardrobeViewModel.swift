import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class WardrobeViewModel {
  private let repository: any WardrobeRepository & WardrobePhotoRepository
  private(set) var items: [WardrobeItem] = []
  var search = ""
  var category: WardrobeCategory?
  var availability: WardrobeAvailability? = .wearable
  var editor: WardrobeEditorModel?
  private(set) var photoCleanupPending = false
  private(set) var cleanupRequest = 0
  private(set) var isCleaningPhotos = false

  func requestPhotoCleanup() {
    guard !isCleaningPhotos else { return }
    isCleaningPhotos = true
    cleanupRequest += 1
  }

  func retryPhotoCleanup() async {
    defer { isCleaningPhotos = false }
    do {
      try await repository.retryPhotoCleanup()
      photoCleanupPending = try await repository.hasPendingPhotoCleanup()
    } catch { photoCleanupPending = true }
  }

  func preparePhoto(_ draft: WardrobeEditorModel) async {
    guard !Task.isCancelled, let selection = draft.photoSelection, let id = draft.photoReview.selectionID else { return }
    do {
      let candidate = try await selection.load()
      try Task.checkCancellation()
      guard !draft.isDeleted else { return }
      try draft.photoReview.receive(candidate.photo, for: id)
      if candidate.observations.people == 0 && candidate.observations.faces == 0 {
        guard let image = WardrobePhotoImage.decode(candidate.photo.normalized.bytes) else {
          try draft.photoReview.failAnalysis(for: id)
          draft.photoSelection = nil
          draft.photoIssue = .inputFailed
          return
        }
        draft.candidateImage = image
      }
      try draft.photoReview.analyze(candidate.observations, for: id)
      draft.photoSelection = nil
      if draft.photoReview.phase != .needsConfirmation { draft.photoIssue = .personDetected }
    } catch is CancellationError {
      if draft.photoReview.selectionID == id { draft.cancelPhotoSelection() }
    } catch {
      guard draft.photoReview.selectionID == id else { return }
      try? draft.photoReview.failInput(for: id)
      draft.photoSelection = nil
      draft.candidateImage = nil
      draft.photoIssue = .inputFailed
    }
  }

  func loadExistingPhoto(_ draft: WardrobeEditorModel) async {
    guard draft.revision != nil, !draft.isDeleted else { return }
    let generation = draft.photoMutation
    do {
      let metadata = try await repository.photoMetadata(itemID: draft.id)
      try Task.checkCancellation()
      guard generation == draft.photoMutation, !draft.isDeleted else { return }
      // Deletion identity comes from the validated record, even when reading its bytes throws.
      draft.existingPhoto = metadata
      draft.existingImage = nil
      let photo = try await repository.readPhoto(itemID: draft.id, purpose: .normalized, maximumBytes: 4 * 1024 * 1024)
      try Task.checkCancellation()
      guard generation == draft.photoMutation, !draft.isDeleted else { return }
      draft.existingImage = photo?.metadata.id == metadata?.id ? photo.flatMap { WardrobePhotoImage.decode($0.bytes) } : nil
      if metadata != nil && draft.existingImage == nil && draft.photoReview.phase == .empty { draft.photoIssue = .unreadable }
    } catch is CancellationError {} catch {
      if generation == draft.photoMutation && draft.photoReview.phase == .empty { draft.photoIssue = .unreadable }
    }
  }

  init(repository: any WardrobeRepository & WardrobePhotoRepository) { self.repository = repository }

  var visibleItems: [WardrobeItem] {
    items.filter {
      (category == nil || $0.input.category == category) &&
      (availability == nil || $0.input.availability == availability) &&
      (search.isEmpty || $0.input.name.localizedStandardContains(search))
    }
  }

  var visibleCategories: [WardrobeCategory] {
    let order: [WardrobeCategory] = [.top, .outerwear, .bottom, .onePiece, .shoes, .bag, .accessory]
    let present = Set(visibleItems.map { $0.input.category })
    return order.filter { present.contains($0) }
  }

  func makeThumbnailModel() -> WardrobeThumbnailViewModel {
    WardrobeThumbnailViewModel(repository: repository)
  }

  func load() async throws {
    let loaded = try await repository.list(WardrobeFilter(availability: nil))
    try Task.checkCancellation()
    items = loaded
    photoCleanupPending = try await repository.hasPendingPhotoCleanup()
  }

  func beginAdding(source: WardrobeSource) {
    guard editor == nil else { return }
    editor = WardrobeEditorModel(source: source)
  }

  func beginEditing(_ item: WardrobeItem) {
    guard editor == nil else { return }
    editor = WardrobeEditorModel(item: item)
  }

  /// Called by the sheet's owned .task. Database commit is independent of sheet lifetime.
  func perform(_ draft: WardrobeEditorModel) async {
    guard draft.isWorking, let action = draft.action else { return }
    defer { draft.isWorking = false }
    draft.error = nil
    do {
      switch action {
      case .save:
        guard !draft.isDeleted, let category = draft.category else {
          draft.needsCategory = true
          return
        }
        guard draft.canSavePhoto else { draft.photoIssue = .confirmationRequired; return }
        if draft.photoReview.phase == .confirmed, draft.photoSubject == .pairOfShoes, category != .shoes {
          draft.photoIssue = .shoeCategoryRequired
          return
        }
        let input = try WardrobeInput(name: draft.name, category: category,
          availability: draft.availability, attributes: draft.attributes)
        let saved: WardrobeItem
        if let selectionID = draft.photoReview.selectionID, draft.photoReview.phase == .confirmed {
          let result = try await repository.saveItemWithPhoto(
            WardrobeItemPhotoEdit(id: draft.id, input: input, source: draft.source, expectedRevision: draft.revision),
            photo: draft.photoReview.write(for: selectionID))
          saved = result.item
          photoCleanupPending = photoCleanupPending || result.cleanupPending
        } else if let revision = draft.revision {
          saved = try await repository.update(id: draft.id, expectedRevision: revision, input: input)
        } else {
          saved = try await repository.create(id: draft.id, input: input, source: draft.source)
        }
        items.removeAll { $0.id == saved.id }
        items.append(saved)
        availability = saved.input.availability
        self.category = nil
        search = ""
        items.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        if editor === draft { editor = nil }
      case .removePhoto:
        guard let revision = draft.revision,
              let id = draft.pendingPhotoRemoval ?? draft.existingPhoto?.id else { return }
        do {
          try await repository.removePhoto(id: id, itemID: draft.id, expectedRevision: revision)
          draft.pendingPhotoRemoval = nil
        } catch WardrobeError.deletionCleanupPending {
          draft.pendingPhotoRemoval = id
          draft.photoIssue = .cleanupPending
          photoCleanupPending = true
        }
        draft.photoMutation += 1
        draft.existingPhoto = nil
        draft.existingImage = nil
        draft.cancelPhotoSelection()
        if draft.pendingPhotoRemoval != nil { draft.photoIssue = .cleanupPending }
        let loaded = try await repository.list(.init(availability: nil))
        items = loaded
        if let item = loaded.first(where: { $0.id == draft.id }) { draft.revision = item.revision }
        photoCleanupPending = try await repository.hasPendingPhotoCleanup()
      case .reviewDeletion:
        guard !draft.isDeleted else { return }
        let impact = try await repository.deletionImpact(id: draft.id)
        try Task.checkCancellation()
        guard editor === draft, !draft.isDeleted else { return }
        draft.deletionImpact = impact
        draft.confirmsDeletion = true
      case .delete:
        guard let revision = draft.revision, let impact = draft.deletionImpact else { return }
        do {
          try await repository.delete(id: draft.id, expectedRevision: revision, impact: impact, policy: draft.historyDeletionPolicy)
        } catch WardrobeError.deletionCleanupPending {
          removeDeletedContent(draft)
          throw WardrobeError.deletionCleanupPending
        }
        removeDeletedContent(draft)
        if editor === draft { editor = nil }
      }
    } catch is CancellationError {
      // The next load reconciles any write already committed; never roll back by deleting data.
    } catch WardrobeError.notFound {
      // This error identifies a missing garment, unlike an absent or unreadable photo.
      removeDeletedContent(draft)
      draft.revision = nil; draft.deletionImpact = nil; draft.pendingPhotoRemoval = nil
      draft.confirmsDeletion = false
      draft.error = .notFound
    } catch {
      draft.error = error as? WardrobeError ?? .storageUnavailable
    }
  }

  private func removeDeletedContent(_ draft: WardrobeEditorModel) {
    items.removeAll { $0.id == draft.id }
    draft.isDeleted = true
    draft.cancelPhotoSelection()
    draft.existingImage = nil
    draft.existingPhoto = nil
    draft.photoMutation += 1
    draft.name = ""
    draft.category = nil
    draft.attributes = .init()
  }
}

@MainActor @Observable
final class WardrobeEditorModel: Identifiable {
  enum Action { case save, reviewDeletion, delete, removePhoto }
  var confirmsDeletion = false
  fileprivate(set) var deletionImpact: WardrobeDeletionImpact?
  var historyDeletionPolicy: WardrobeHistoryDeletionPolicy = .redactSnapshots
  enum PhotoIssue { case personDetected, inputFailed, confirmationRequired, shoeCategoryRequired, unreadable, cleanupPending }
  var photoIssue: PhotoIssue?
  var photoReview = WardrobePhotoReview()
  fileprivate var photoSelection: (any WardrobePhotoSelecting)?
  fileprivate var photoMutation = 0
  fileprivate(set) var existingPhoto: WardrobePhotoMetadata?
  fileprivate(set) var existingImage: Image?
  fileprivate(set) var candidateImage: Image?
  fileprivate(set) var pendingPhotoRemoval: UUID?
  private(set) var photoRequest = 0
  var photoSubject: WardrobePhotoConfirmation.Subject?
  var photoOwned = false
  var photoNoPerson = false
  var photoComplete = false

  var canSavePhoto: Bool { photoReview.phase == .empty || photoReview.phase == .confirmed }
  var isProcessingPhoto: Bool { photoReview.phase == .loading || photoReview.phase == .analyzing }

  func selectPhoto(_ selection: any WardrobePhotoSelecting) {
    guard !isWorking, !isDeleted else { return }
    cancelPhotoSelection()
    photoSelection = selection
    photoReview.beginSelection()
    photoRequest += 1
  }

  func confirmPhoto() {
    guard let id = photoReview.selectionID else { return }
    do {
      try photoReview.confirm(.init(subject: photoSubject, ownedByUser: photoOwned,
        noPersonInImage: photoNoPerson, mainItemIsComplete: photoComplete), for: id)
      photoIssue = nil
    } catch { photoIssue = .confirmationRequired }
  }

  func cancelPhotoSelection() {
    photoSelection = nil
    photoReview.cancel()
    candidateImage = nil
    photoSubject = nil
    photoOwned = false
    photoNoPerson = false
    photoComplete = false
    photoIssue = nil
    photoRequest += 1
  }
  let id: UUID
  let source: WardrobeSource
  fileprivate(set) var revision: Int?
  var name: String
  var category: WardrobeCategory?
  var availability: WardrobeAvailability
  var attributes: WardrobeAttributes
  var error: WardrobeError?
  var needsCategory = false
  var isWorking = false
  var isDeleted = false
  var canRetryDeletion: Bool { isDeleted && revision != nil && deletionImpact != nil }
  private(set) var action: Action?
  private(set) var request = 0

  init(source: WardrobeSource) {
    id = UUID()
    self.source = source
    revision = nil
    name = ""
    availability = .wearable
    attributes = .init()
  }

  init(item: WardrobeItem) {
    id = item.id
    source = item.source
    revision = item.revision
    name = item.input.name
    category = item.input.category
    availability = item.input.availability
    attributes = item.input.attributes
  }

  func submit(_ action: Action) {
    guard !isWorking, !isDeleted || (action == .delete && canRetryDeletion) else { return }
    self.action = action
    isWorking = true
    needsCategory = false
    request += 1
  }
}

/// Each visible card owns a bounded, disposable decoded thumbnail, never an original photo.
@MainActor @Observable
final class WardrobeThumbnailViewModel {
  private let repository: any WardrobePhotoRepository
  private var generation = UUID()
  private(set) var image: Image?

  init(repository: any WardrobePhotoRepository) { self.repository = repository }

  func clear() {
    generation = UUID()
    image = nil
  }

  func load(itemID: UUID, expectedAssetID: UUID?) async {
    clear()
    let request = generation
    do {
      let photo = try await repository.readPhoto(itemID: itemID, purpose: .thumbnail, maximumBytes: 512 * 1024)
      try Task.checkCancellation()
      guard request == generation, let photo, photo.purpose == .thumbnail,
            expectedAssetID == nil || photo.metadata.id == expectedAssetID else { return }
      image = WardrobePhotoImage.decode(photo.bytes)
    } catch {
      // Missing, corrupt and canceled reads leave the garment editable without stale pixels.
      if request == generation { image = nil }
    }
  }
}
