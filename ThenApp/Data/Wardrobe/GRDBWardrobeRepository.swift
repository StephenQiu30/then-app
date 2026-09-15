import Foundation
import GRDB

/// Owns disk work off MainActor. UI receives only domain values and safe errors.
actor GRDBWardrobeRepository: WardrobeRepository, WardrobePhotoRepository, OutfitPlanRepository, WearEventRepository,
  OutfitFeedbackRepository {
  private let directory: URL
  private var pool: DatabasePool?

  init(directory: URL) {
    self.directory = directory
  }

  static func applicationStore() -> GRDBWardrobeRepository {
    GRDBWardrobeRepository(directory: URL.applicationSupportDirectory.appendingPathComponent("OOTD"))
  }

  func prepare() throws {
    try safely { _ = try connection() }
  }

  func list(_ filter: WardrobeFilter) throws -> [WardrobeItem] {
    try safely {
      let dbPool = try connection()
      return try dbPool.read { db in
        var clauses: [String] = []
        var arguments = StatementArguments()
        if let category = filter.category {
          clauses.append("category = ?")
          arguments += [category.rawValue]
        }
        if let availability = filter.availability {
          clauses.append("availability = ?")
          arguments += [availability.rawValue]
        }
        let search = filter.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
          // instr treats %, _ and quotes literally; this is not a user-supplied SQL pattern.
          clauses.append("instr(lower(name), lower(?)) > 0")
          arguments += [search]
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return try WardrobeRecord.fetchAll(
          db, sql: "SELECT * FROM wardrobe_items" + predicate + " ORDER BY createdAt DESC, id ASC",
          arguments: arguments
        ).map { try $0.domain() }
      }
    }
  }

  func create(id: UUID, input: WardrobeInput, source: WardrobeSource) throws -> WardrobeItem {
    try safely {
      let dbPool = try connection()
      return try dbPool.write { db in
        if let previous = try WardrobeRecord.fetchOne(db, key: id.uuidString) {
          let item = try previous.domain()
          guard item.input == input, item.source == source else { throw WardrobeError.conflict }
          return item
        }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        let item = WardrobeItem(id: id, input: input, source: source,
                                revision: 1, createdAt: now, updatedAt: now)
        try WardrobeRecord(item).insert(db)
        return item
      }
    }
  }

  func update(id: UUID, expectedRevision: Int, input: WardrobeInput) throws -> WardrobeItem {
    try safely {
      let dbPool = try connection()
      return try dbPool.write { db in
        guard let record = try WardrobeRecord.fetchOne(db, key: id.uuidString) else {
          throw WardrobeError.notFound
        }
        let old = try record.domain()
        guard old.revision == expectedRevision else { throw WardrobeError.conflict }
        guard old.revision < Int.max else { throw WardrobeError.invalidStoredData }
        let item = WardrobeItem(id: id, input: input, source: old.source,
                                revision: old.revision + 1, createdAt: old.createdAt,
                                updatedAt: max(Date(timeIntervalSince1970: Date().timeIntervalSince1970), old.updatedAt))
        try WardrobeRecord(item).update(db)
        return item
      }
    }
  }

  func deletionImpact(id: UUID) throws -> WardrobeDeletionImpact {
    try safely { try connection().read { try OutfitPlanPersistence.impact($0, itemID: id) } }
  }

  func listPlans(on date: OutfitLocalDate?, after cursor: OutfitPlanCursor?) throws -> OutfitPlanPage {
    try safely { try OutfitPlanPersistence(pool: connection()).list(on: date, after: cursor) }
  }

  func readPlan(id: UUID) throws -> OutfitPlan {
    try safely { try OutfitPlanPersistence(pool: connection()).read(id: id) }
  }

  func mutatePlan(_ command: OutfitPlanMutation) throws -> OutfitPlan? {
    try safely {
      let dbPool = try connection()
      let result = try OutfitPlanPersistence(pool: dbPool).mutate(command)
      if case .delete = command.action {
        do { try checkpoint(dbPool) } catch { throw WardrobeError.deletionCleanupPending }
      }
      return result
    }
  }

  func listWearEvents(on date: OutfitLocalDate?) throws -> [WearEvent] {
    try safely { try WearEventPersistence(pool: connection()).list(on: date) }
  }

  func readWearEvent(id: UUID) throws -> WearEvent {
    try safely { try WearEventPersistence(pool: connection()).read(id: id) }
  }

  func mutateWearEvent(_ command: WearEventMutation) throws -> WearEvent? {
    try safely {
      let dbPool = try connection()
      let result = try WearEventPersistence(pool: dbPool).mutate(command)
      if case .delete = command.action {
        do { try checkpoint(dbPool) } catch { throw WardrobeError.deletionCleanupPending }
      }
      return result
    }
  }

  func wearCount(itemID: UUID) throws -> Int {
    try safely { try WearEventPersistence(pool: connection()).wearCount(itemID: itemID) }
  }

  func listTimeline(after cursor: OutfitTimelineCursor?) throws -> OutfitTimelinePage {
    try safely { try WearEventPersistence(pool: connection()).timeline(after: cursor) }
  }

  func readFeedback(wearEventID: UUID) throws -> OutfitFeedback? {
    try safely { try OutfitFeedbackPersistence(pool: connection()).read(wearEventID: wearEventID) }
  }

  func mutateFeedback(_ command: OutfitFeedbackMutation) throws -> OutfitFeedback? {
    try safely { try OutfitFeedbackPersistence(pool: connection()).mutate(command) }
  }

  func rebuildPreferenceEvidence() throws -> [PreferenceEvidence] {
    try safely { try OutfitFeedbackPersistence(pool: connection()).rebuildEvidence() }
  }

  func delete(id: UUID, expectedRevision: Int, impact: WardrobeDeletionImpact, policy: WardrobeHistoryDeletionPolicy) throws {
    try safely {
      let dbPool = try connection()
      try dbPool.write { db in
        if let record = try WardrobeRecord.fetchOne(db, key: id.uuidString) {
          guard record.revision == expectedRevision else { throw WardrobeError.conflict }
          try OutfitPlanPersistence.deleteWardrobeReferences(db, itemID: id, expected: impact, policy: policy, now: Date())
          try WardrobePhotoPersistence.markForDeletion(db, itemID: id)
          _ = try record.delete(db)
        }
      }
      // The business deletion has committed. A busy reader must not be reported as an undo.
      do {
        try WardrobePhotoPersistence(pool: dbPool, directory: directory).recover()
        try checkpoint(dbPool)
      } catch {
        throw WardrobeError.deletionCleanupPending
      }
    }
  }

  func savePhoto(_ photo: WardrobePhotoWrite, itemID: UUID, expectedRevision: Int) throws -> WardrobePhotoSaveResult {
    try safely {
      try WardrobePhotoPersistence(pool: connection(), directory: directory)
        .save(photo, itemID: itemID, expectedRevision: expectedRevision)
    }
  }

  func saveItemWithPhoto(_ edit: WardrobeItemPhotoEdit, photo: WardrobePhotoWrite) throws -> WardrobeItemPhotoSaveResult {
    try safely {
      let dbPool = try connection()
      let saved = try WardrobePhotoPersistence(pool: dbPool, directory: directory)
        .save(photo, itemID: edit.id, expectedRevision: edit.expectedRevision, edit: edit)
      let item = try dbPool.read { db in
        guard let record = try WardrobeRecord.fetchOne(db, key: edit.id.uuidString) else { throw WardrobeError.notFound }
        return try record.domain()
      }
      return WardrobeItemPhotoSaveResult(item: item, photo: saved.metadata, cleanupPending: saved.cleanupPending)
    }
  }

  func readPhoto(itemID: UUID, purpose: WardrobePhotoPurpose, maximumBytes: Int) throws -> WardrobePhotoRead? {
    try safely {
      try WardrobePhotoPersistence(pool: connection(), directory: directory)
        .read(itemID: itemID, purpose: purpose, maximumBytes: maximumBytes)
    }
  }

  func photoMetadata(itemID: UUID) throws -> WardrobePhotoMetadata? {
    try safely { try WardrobePhotoPersistence(pool: connection(), directory: directory).metadata(itemID: itemID) }
  }

  func removePhoto(id: UUID, itemID: UUID, expectedRevision: Int) throws {
    try safely {
      try WardrobePhotoPersistence(pool: connection(), directory: directory)
        .remove(id: id, itemID: itemID, expectedRevision: expectedRevision)
    }
  }

  func hasPendingPhotoCleanup() throws -> Bool {
    try safely { try WardrobePhotoPersistence(pool: connection(), directory: directory).hasPendingCleanup() }
  }

  func retryPhotoCleanup() throws {
    try safely { try WardrobePhotoPersistence(pool: connection(), directory: directory).recover() }
  }

  /// Used when releasing this storage owner, including tests. Never deletes the database.
  func close() throws {
    try safely {
      try pool?.close()
      pool = nil
    }
  }

  private func connection() throws -> DatabasePool {
    try Task.checkCancellation()
    if let pool { return pool }
    let files = FileManager.default
    guard directory.isFileURL else { throw WardrobeError.storageUnavailable }
    if try WardrobePhotoPersistence.attributes(directory) == nil {
      try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.complete])
    }
    try WardrobePhotoPersistence.ensureDirectory(directory, create: false)
    try protectDatabaseFiles()
    var configuration = Configuration()
    configuration.busyMode = .timeout(1)
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA secure_delete = ON")
    }
    let candidate = try DatabasePool(path: directory.appendingPathComponent("wardrobe.sqlite").path,
                                     configuration: configuration)
    let migrator = OOTDSchema.migrator
    guard try !candidate.read(migrator.hasBeenSuperseded) else { throw WardrobeError.newerDatabase }
    try migrator.migrate(candidate)
    // Only SQLite files are ours here; media validates its own root and descendants.
    try protectDatabaseFiles()
    do { try WardrobePhotoPersistence(pool: candidate, directory: directory).recover() }
    catch WardrobeError.deletionCleanupPending {
      // Persistent intent keeps photos hidden/retryable while the structured wardrobe stays usable.
    }
    try checkpoint(candidate)
    pool = candidate
    return candidate
  }

  private func protectDatabaseFiles() throws {
    for name in ["wardrobe.sqlite", "wardrobe.sqlite-wal", "wardrobe.sqlite-shm"] {
      let url = directory.appendingPathComponent(name)
      if try WardrobePhotoPersistence.attributes(url) != nil {
        try WardrobePhotoPersistence.regular(url)
        try WardrobePhotoPersistence.protect(url)
      }
    }
  }

  private func checkpoint(_ dbPool: DatabasePool) throws {
    _ = try dbPool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
  }

  private func safely<T>(_ operation: () throws -> T) throws -> T {
    do {
      try Task.checkCancellation()
      return try operation()
    } catch let error as OutfitPlanError {
      throw error
    } catch let error as WearEventError {
      throw error
    } catch let error as OutfitFeedbackError {
      throw error
    } catch let error as WardrobeError {
      throw error
    } catch let error as WardrobePhotoInputError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Never expose SQL, file paths or personal fields through UI/logs.
      throw WardrobeError.storageUnavailable
    }
  }
}

nonisolated struct WardrobeRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "wardrobe_items"
  let id: String
  let name: String
  let category: String
  let availability: String
  let formalityBand: String?
  let warmthBand: String?
  let rainUse: String?
  let walkingUse: String?
  let source: String
  let revision: Int
  let createdAt: Double
  let updatedAt: Double

  init(_ item: WardrobeItem) {
    id = item.id.uuidString
    name = item.input.name
    category = item.input.category.rawValue
    availability = item.input.availability.rawValue
    formalityBand = item.input.attributes.formalityBand?.rawValue
    warmthBand = item.input.attributes.warmthBand?.rawValue
    rainUse = item.input.attributes.rainUse?.rawValue
    walkingUse = item.input.attributes.walkingUse?.rawValue
    source = item.source.rawValue
    revision = item.revision
    createdAt = item.createdAt.timeIntervalSince1970
    updatedAt = item.updatedAt.timeIntervalSince1970
  }

  func domain() throws -> WardrobeItem {
    guard let id = UUID(uuidString: id), let category = WardrobeCategory(rawValue: category),
          let availability = WardrobeAvailability(rawValue: availability),
          let source = WardrobeSource(rawValue: source), revision > 0,
          createdAt.isFinite, updatedAt.isFinite, updatedAt >= createdAt,
          formalityBand == nil || WardrobeFormalityBand(rawValue: formalityBand ?? "") != nil,
          warmthBand == nil || WardrobeWarmthBand(rawValue: warmthBand ?? "") != nil,
          rainUse == nil || WardrobeUseSuitability(rawValue: rainUse ?? "") != nil,
          walkingUse == nil || WardrobeUseSuitability(rawValue: walkingUse ?? "") != nil,
          let input = try? WardrobeInput(name: name, category: category, availability: availability,
            attributes: WardrobeAttributes(
              formalityBand: formalityBand.flatMap(WardrobeFormalityBand.init(rawValue:)),
              warmthBand: warmthBand.flatMap(WardrobeWarmthBand.init(rawValue:)),
              rainUse: rainUse.flatMap(WardrobeUseSuitability.init(rawValue:)),
              walkingUse: walkingUse.flatMap(WardrobeUseSuitability.init(rawValue:)))),
          input.name == name else { throw WardrobeError.invalidStoredData }
    return WardrobeItem(id: id, input: input, source: source, revision: revision,
                        createdAt: Date(timeIntervalSince1970: createdAt),
                        updatedAt: Date(timeIntervalSince1970: updatedAt))
  }

  /// Only called inside the final photo transaction, never during file staging.
  static func applyPhotoEdit(_ edit: WardrobeItemPhotoEdit, db: Database) throws {
    let previous = try fetchOne(db, key: edit.id.uuidString)?.domain()
    if let expected = edit.expectedRevision {
      guard let previous, previous.revision == expected, previous.source == edit.source,
            expected > 0, expected < Int.max else { throw WardrobeError.conflict }
    } else if previous != nil { throw WardrobeError.conflict }
    let now = Date()
    let item = WardrobeItem(id: edit.id, input: edit.input, source: edit.source,
      revision: (previous?.revision ?? 0) + 1, createdAt: previous?.createdAt ?? now,
      updatedAt: max(previous?.updatedAt ?? now, now))
    if previous == nil { try Self(item).insert(db) }
    else { try Self(item).update(db) }
  }
}
