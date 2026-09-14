import Foundation
import GRDB
import Testing
@testable import ThenApp

@MainActor @Suite("衣物照片编辑状态")
struct WardrobePhotoEditingTests {
  private func candidate(people: Int = 0, faces: Int = 0) async throws -> WardrobePhotoCandidate {
    let folder = try #require(Bundle(for: EditingFixtureBundle.self).url(forResource: "AvatarPhotoIntake", withExtension: nil))
    let data = try Data(contentsOf: folder.appendingPathComponent("metadata-png.fixture"))
    let limits = try ImageIOWardrobePhotoPreparer.Limits(inputBytes: 1_000_000, sourcePixels: 4096,
      normalizedDimension: 32, thumbnailDimension: 8, rasterBytes: 4096, normalizedBytes: 100_000,
      thumbnailBytes: 100_000, duration: .seconds(5))
    return try await .init(photo: ImageIOWardrobePhotoPreparer(limits: limits).prepare(data, format: .png),
      observations: .init(people: people, faces: faces))
  }
  private func withModel(_ body: (WardrobeViewModel, GRDBWardrobeRepository, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = GRDBWardrobeRepository(directory: root)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Could not clean photo editor fixture") }
    }
    do {
      try await store.prepare()
      try await body(WardrobeViewModel(repository: store), store, root)
      try await store.close()
    } catch { try await store.close(); throw error }
  }
  private func draft(_ model: WardrobeViewModel) throws -> WardrobeEditorModel {
    model.beginAdding(source: .wardrobe)
    let draft = try #require(model.editor)
    draft.name = "synthetic edited shirt"
    draft.category = .top
    return draft
  }
  private func confirm(_ draft: WardrobeEditorModel) {
    draft.photoSubject = .singleGarment
    draft.photoOwned = true
    draft.photoNoPerson = true
    draft.photoComplete = true
    draft.confirmPhoto()
  }

  @Test("旧编辑收到衣物已删除时清空已存图和候选，终止保存与清理入口", arguments: [false, true])
  func externallyDeletedItemEndsEditing(withReplacement: Bool) async throws {
    let selected = try await candidate()
    try await withModel { model, store, _ in
      let initial = try draft(model)
      initial.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(initial); confirm(initial)
      initial.submit(.save); await model.perform(initial)
      let item = try #require(model.items.first)
      model.beginEditing(item)
      let stale = try #require(model.editor)
      await model.loadExistingPhoto(stale)
      #expect(stale.existingImage != nil && stale.existingPhoto != nil)
      stale.name = "synthetic unsaved private name"
      if withReplacement {
        stale.selectPhoto(ImmediateSelection(candidate: selected))
        await model.preparePhoto(stale); confirm(stale)
        #expect(stale.candidateImage != nil && stale.photoReview.phase == .confirmed)
      }
      let impact = try await store.deletionImpact(id: item.id)
      try await store.delete(id: item.id, expectedRevision: item.revision, impact: impact, policy: .redactSnapshots)
      stale.submit(.save); await model.perform(stale)
      #expect(stale.error == .notFound && stale.isDeleted && !stale.isWorking)
      #expect(!stale.canRetryDeletion && stale.deletionImpact == nil && stale.revision == nil)
      #expect(stale.name.isEmpty && stale.category == nil)
      #expect(stale.existingImage == nil && stale.existingPhoto == nil && stale.candidateImage == nil)
      #expect(stale.photoReview.phase == .empty && !stale.photoOwned && !stale.photoNoPerson && !stale.photoComplete)
      #expect(model.items.isEmpty)
      let request = stale.request
      for action in [WardrobeEditorModel.Action.save, .reviewDeletion, .delete, .removePhoto] { stale.submit(action) }
      #expect(stale.request == request)
      await model.loadExistingPhoto(stale)
      #expect(stale.existingImage == nil && stale.existingPhoto == nil)
      #expect(try await store.list(.init()).isEmpty)
      #expect(try await store.photoMetadata(itemID: item.id) == nil)
    }
  }

  @Test("分类网格沿用真实筛选且按参考顺序分组")
  func gridCategories() async throws {
    try await withModel { model, store, _ in
      for category in [WardrobeCategory.bottom, .outerwear, .top] {
        _ = try await store.create(id: UUID(), input: WardrobeInput(name: category.rawValue,
          category: category, availability: .wearable), source: .wardrobe)
      }
      _ = try await store.create(id: UUID(), input: WardrobeInput(name: "washing shoes",
        category: .shoes, availability: .laundry), source: .wardrobe)
      try await model.load()
      #expect(model.visibleCategories == [.top, .outerwear, .bottom])
      model.availability = nil
      #expect(model.visibleCategories == [.top, .outerwear, .bottom, .shoes])
      model.search = "washing"
      #expect(model.visibleCategories == [.shoes] && model.visibleItems.count == 1)
      model.category = .top
      #expect(model.visibleCategories.isEmpty && model.visibleItems.isEmpty)
    }
  }

  @Test("网格读取真实缩略图，清空与照片移除后不保留像素")
  func gridThumbnailLifecycle() async throws {
    let selected = try await candidate()
    try await withModel { model, store, _ in
      let draft = try draft(model)
      draft.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(draft)
      confirm(draft)
      draft.submit(.save)
      await model.perform(draft)
      let thumbnail = model.makeThumbnailModel()
      await thumbnail.load(itemID: draft.id, expectedAssetID: nil)
      #expect(thumbnail.image != nil)
      await thumbnail.load(itemID: draft.id, expectedAssetID: UUID())
      #expect(thumbnail.image == nil)
      thumbnail.clear()
      #expect(thumbnail.image == nil)
      await thumbnail.load(itemID: UUID(), expectedAssetID: nil)
      #expect(thumbnail.image == nil)
      await thumbnail.load(itemID: draft.id, expectedAssetID: nil)
      #expect(thumbnail.image != nil)
      let metadata = try #require(try await store.photoMetadata(itemID: draft.id))
      try await store.removePhoto(id: metadata.id, itemID: draft.id, expectedRevision: 1)
      await thumbnail.load(itemID: draft.id, expectedAssetID: nil)
      #expect(thumbnail.image == nil)
      #expect(try await store.list(.init()).count == 1)
    }
  }

  @Test("退出或取消后迟到的缩略图不得重新显示", arguments: [false, true])
  func lateGridThumbnail(_ cancelTask: Bool) async throws {
    let selected = try await candidate()
    try await withModel { model, store, _ in
      let draft = try draft(model)
      draft.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(draft)
      confirm(draft)
      draft.submit(.save)
      await model.perform(draft)
      let photo = try #require(try await store.readPhoto(itemID: draft.id, purpose: .thumbnail, maximumBytes: 512 * 1024))
      let delayed = DelayedThumbnail(photo: photo)
      let thumbnail = WardrobeThumbnailViewModel(repository: delayed)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await thumbnail.load(itemID: draft.id, expectedAssetID: nil) }
        await delayed.waitUntilStarted()
        if cancelTask { group.cancelAll() } else { thumbnail.clear() }
        await delayed.finish()
      }
      #expect(thumbnail.image == nil)
    }
  }

  @Test("候选未复核不写入，确认后一次保存衣物和真实 PNG")
  func confirmedSave() async throws {
    let selected = try await candidate()
    try await withModel { model, store, _ in
      let draft = try draft(model)
      draft.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(draft)
      #expect(draft.photoReview.phase == .needsConfirmation && draft.candidateImage != nil)
      draft.submit(.save)
      await model.perform(draft)
      #expect(draft.photoIssue == .confirmationRequired)
      #expect(try await store.list(.init()).isEmpty)
      confirm(draft)
      draft.submit(.save)
      await model.perform(draft)
      #expect(model.editor == nil && model.items.count == 1)
      #expect(model.items.first?.revision == 1)
      let read = try #require(try await store.readPhoto(itemID: draft.id, purpose: .normalized, maximumBytes: 100_000))
      #expect(read.bytes == selected.photo.normalized.bytes)
    }
  }

  @Test("人物与无法显示的候选不允许确认或保存", arguments: [false, true])
  func rejected(_ invalidPixels: Bool) async throws {
    var value = try await candidate(people: 1)
    if invalidPixels {
      let bad = try WardrobeEncodedImage(bytes: Data([1]), format: .png, width: 1, height: 1, maximumBytes: 1)
      value = try .init(photo: .init(normalized: bad, thumbnail: bad), observations: .init(people: 0, faces: 0))
    }
    let selected = value
    try await withModel { model, store, _ in
      let draft = try draft(model)
      draft.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(draft)
      #expect(!draft.canSavePhoto && draft.candidateImage == nil)
      #expect(draft.photoIssue == (invalidPixels ? .inputFailed : .personDetected))
      confirm(draft)
      #expect(draft.photoReview.phase != .confirmed)
      draft.cancelPhotoSelection()
      draft.submit(.save)
      await model.perform(draft)
      #expect(model.items.count == 1)
      #expect(try await store.photoMetadata(itemID: draft.id) == nil)
    }
  }

  @Test("迟到的旧选择不能拒绝或覆盖新图片")
  func lateSelection() async throws {
    let old = try await candidate(people: 1), current = try await candidate()
    try await withModel { model, _, _ in
      let draft = try draft(model)
      let delayed = DelayedSelection()
      draft.selectPhoto(delayed)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await model.preparePhoto(draft) }
        await delayed.waitUntilStarted()
        draft.selectPhoto(ImmediateSelection(candidate: current))
        await model.preparePhoto(draft)
        await delayed.finish(old)
      }
      #expect(draft.photoReview.phase == .needsConfirmation && draft.photoIssue == nil)
      #expect(draft.candidateImage != nil)
    }
  }

  @Test("退出清空候选并拒绝未响应取消的迟到结果")
  func cancelPendingSelection() async throws {
    let current = try await candidate()
    try await withModel { model, store, _ in
      let draft = try draft(model)
      let delayed = DelayedSelection()
      draft.selectPhoto(delayed)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await model.preparePhoto(draft) }
        await delayed.waitUntilStarted()
        draft.cancelPhotoSelection()
        group.cancelAll()
        await delayed.finish(current)
      }
      #expect(draft.photoReview.phase == .empty && draft.candidateImage == nil)
      #expect(draft.photoSubject == nil && !draft.photoOwned)
      #expect(try await store.list(.init()).isEmpty)
    }
  }

  @Test("保存失败保留照片命令和草稿，重试只有一件")
  func retryAtomicSave() async throws {
    let selected = try await candidate()
    try await withModel { model, store, root in
      let draft = try draft(model)
      draft.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(draft)
      confirm(draft)
      let selectionID = try #require(draft.photoReview.selectionID)
      let write = try draft.photoReview.write(for: selectionID)
      let database = try DatabaseQueue(path: root.appendingPathComponent("wardrobe.sqlite").path)
      try await database.write { try $0.execute(sql: "CREATE TRIGGER reject_save BEFORE INSERT ON wardrobe_items BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
      draft.submit(.save)
      await model.perform(draft)
      #expect(model.editor === draft && draft.error == .storageUnavailable)
      #expect(try draft.photoReview.write(for: selectionID) == write)
      #expect(try await store.list(.init()).isEmpty)
      try await database.write { try $0.execute(sql: "DROP TRIGGER reject_save") }
      try database.close()
      draft.submit(.save)
      await model.perform(draft)
      #expect(model.items.count == 1 && model.editor == nil)
    }
  }

  @Test("照片丢失或读取拒绝仍可移除，未保存字段不被 revision 回读覆盖", arguments: [false, true])
  func removeUnreadable(rejectedRead: Bool) async throws {
    let selected = try await candidate()
    try await withModel { model, store, root in
      let first = try draft(model)
      first.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(first)
      confirm(first)
      first.submit(.save)
      await model.perform(first)
      let item = try #require(model.items.first)
      let metadata = try #require(try await store.photoMetadata(itemID: item.id))
      model.beginEditing(item)
      let edit = try #require(model.editor)
      await model.loadExistingPhoto(edit)
      #expect(edit.existingImage != nil)
      let photoFile = root.appendingPathComponent("WardrobeMedia/photo-\(metadata.id.uuidString)/normalized.image")
      try FileManager.default.removeItem(at: photoFile)
      if rejectedRead { try FileManager.default.createDirectory(at: photoFile, withIntermediateDirectories: false) }
      await model.loadExistingPhoto(edit)
      #expect(edit.existingPhoto?.id == metadata.id && edit.existingImage == nil)
      #expect(edit.photoIssue == .unreadable)
      edit.name = "unsaved edit"
      edit.submit(.removePhoto)
      await model.perform(edit)
      if rejectedRead {
        #expect(edit.pendingPhotoRemoval == metadata.id && edit.photoIssue == .cleanupPending)
        try FileManager.default.removeItem(at: photoFile)
        edit.submit(.removePhoto)
        await model.perform(edit)
        #expect(edit.pendingPhotoRemoval == nil)
      }
      #expect(edit.existingPhoto == nil && edit.revision == item.revision + 1)
      #expect(edit.name == "unsaved edit")
      #expect(model.items.first?.input.name == item.input.name)
      #expect(try await store.photoMetadata(itemID: item.id) == nil)
    }
  }

  @Test("移除清理失败隐藏图片，可按原照片 ID 重试")
  func deletionCleanupRetry() async throws {
    let selected = try await candidate()
    try await withModel { model, store, root in
      let first = try draft(model)
      first.selectPhoto(ImmediateSelection(candidate: selected))
      await model.preparePhoto(first)
      confirm(first)
      first.submit(.save)
      await model.perform(first)
      let item = try #require(model.items.first)
      let photo = try #require(try await store.photoMetadata(itemID: item.id))
      let obstruction = root.appendingPathComponent("WardrobeMedia/photo-\(photo.id.uuidString)/unknown.fixture")
      try Data([1]).write(to: obstruction)
      model.beginEditing(item)
      let edit = try #require(model.editor)
      await model.loadExistingPhoto(edit)
      edit.submit(.removePhoto)
      await model.perform(edit)
      #expect(edit.photoIssue == .cleanupPending && edit.existingImage == nil && edit.existingPhoto == nil)
      #expect(edit.pendingPhotoRemoval == photo.id && model.photoCleanupPending)
      #expect(model.items.count == 1)
      try FileManager.default.removeItem(at: obstruction)
      edit.submit(.removePhoto)
      await model.perform(edit)
      #expect(edit.pendingPhotoRemoval == nil && !model.photoCleanupPending)
      #expect(try await store.hasPendingPhotoCleanup() == false)
    }
  }
}

nonisolated private struct ImmediateSelection: WardrobePhotoSelecting {
  let candidate: WardrobePhotoCandidate
  func load() async throws -> WardrobePhotoCandidate { candidate }
}
private actor DelayedSelection: WardrobePhotoSelecting {
  private var continuation: CheckedContinuation<WardrobePhotoCandidate, Never>?
  private var started: CheckedContinuation<Void, Never>?
  func load() async -> WardrobePhotoCandidate {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started?.resume()
      started = nil
    }
  }
  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish(_ value: WardrobePhotoCandidate) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}
private final class EditingFixtureBundle: NSObject {}

private actor DelayedThumbnail: WardrobePhotoRepository {
  private let photo: WardrobePhotoRead
  private var continuation: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  init(photo: WardrobePhotoRead) { self.photo = photo }
  func readPhoto(itemID: UUID, purpose: WardrobePhotoPurpose, maximumBytes: Int) async -> WardrobePhotoRead? {
    #expect(purpose == .thumbnail && maximumBytes == 512 * 1024)
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started?.resume()
      started = nil
    }
    return photo
  }
  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finish() { continuation?.resume(); continuation = nil }
  func photoMetadata(itemID: UUID) throws -> WardrobePhotoMetadata? { throw WardrobeError.storageUnavailable }
  func saveItemWithPhoto(_ edit: WardrobeItemPhotoEdit, photo: WardrobePhotoWrite) throws -> WardrobeItemPhotoSaveResult {
    throw WardrobeError.storageUnavailable
  }
  func savePhoto(_ photo: WardrobePhotoWrite, itemID: UUID, expectedRevision: Int) throws -> WardrobePhotoSaveResult {
    throw WardrobeError.storageUnavailable
  }
  func removePhoto(id: UUID, itemID: UUID, expectedRevision: Int) throws { throw WardrobeError.storageUnavailable }
  func hasPendingPhotoCleanup() -> Bool { false }
  func retryPhotoCleanup() throws { throw WardrobeError.storageUnavailable }
}
