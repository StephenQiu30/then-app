import CryptoKit
import Foundation
import GRDB

/// Shares the wardrobe owner's pool so garment versions, snapshots and deletion commit together.
nonisolated struct OutfitPlanPersistence {
  let pool: DatabasePool
  var now = Date()

  func read(id: UUID) throws -> OutfitPlan {
    try pool.read { try Self.read($0, id: id) }
  }

  func list(on date: OutfitLocalDate?, after cursor: OutfitPlanCursor?) throws -> OutfitPlanPage {
    try pool.read { db in
      var clauses = ["status != 'deleted'"]
      var arguments = StatementArguments()
      if let date { clauses.append("localDate = ?"); arguments += [date.value] }
      if let cursor {
        guard cursor.createdAt.timeIntervalSince1970.isFinite else { throw OutfitPlanError.invalidInput }
        clauses.append("(localDate < ? OR (localDate = ? AND createdAt < ?) OR (localDate = ? AND createdAt = ? AND id > ?))")
        arguments += [cursor.localDate.value, cursor.localDate.value, cursor.createdAt.timeIntervalSince1970,
                      cursor.localDate.value, cursor.createdAt.timeIntervalSince1970, cursor.id.uuidString]
      }
      let ids = try String.fetchAll(db, sql: "SELECT id FROM outfit_plans WHERE " + clauses.joined(separator: " AND ")
        + " ORDER BY localDate DESC, createdAt DESC, id ASC LIMIT 51", arguments: arguments)
      let plans = try ids.prefix(50).map { text in
        guard let id = UUID(uuidString: text) else { throw WardrobeError.invalidStoredData }
        return try Self.read(db, id: id)
      }
      let cursor = ids.count > 50 ? plans.last.map { OutfitPlanCursor(localDate: $0.localDate, createdAt: $0.createdAt, id: $0.id) } : nil
      return OutfitPlanPage(plans: plans, nextCursor: cursor)
    }
  }

  func mutate(_ command: OutfitPlanMutation) throws -> OutfitPlan? {
    let operation: String
    switch command.action {
    case .save(_, let expected):
      guard expected == nil || (expected ?? 0) > 0 else { throw OutfitPlanError.invalidInput }
      operation = "save"
    case .cancel(let expected):
      guard expected > 0 else { throw OutfitPlanError.invalidInput }
      operation = "cancel"
    case .delete(let expected):
      guard expected > 0 else { throw OutfitPlanError.invalidInput }
      operation = "delete"
    }
    let fingerprint = try Self.fingerprint(command)
    return try pool.write { db in
      let key = command.planID.uuidString
      let storedStatus = try String.fetchOne(db, sql: "SELECT status FROM outfit_plans WHERE id = ?", arguments: [key])
      let receipt = try Row.fetchOne(db, sql: "SELECT planID, operation, fingerprint FROM outfit_plan_mutations WHERE id = ?",
                                     arguments: [command.id.uuidString])
      if let receipt, (receipt["planID"] as String) != key || (receipt["operation"] as String) != operation { throw OutfitPlanError.conflict }
      if storedStatus == "deleted" {
        if case .delete = command.action {
          if receipt == nil {
            try db.execute(sql: "INSERT INTO outfit_plan_mutations(id, planID, operation, fingerprint) VALUES (?, ?, 'delete', NULL)",
                           arguments: [command.id.uuidString, key])
          }
          return nil
        }
        throw OutfitPlanError.notFound
      }
      if let receipt {
        guard (receipt["fingerprint"] as String?) == fingerprint else { throw OutfitPlanError.conflict }
        return try Self.read(db, id: command.planID)
      }
      switch command.action {
      case .save(let input, let expected):
        try save(db, id: command.planID, input: input, expected: expected, exists: storedStatus != nil)
      case .cancel(let expected):
        let plan = try Self.read(db, id: command.planID)
        guard expected > 0, plan.revision == expected, plan.status == .active else { throw OutfitPlanError.conflict }
        try db.execute(sql: "UPDATE outfit_plans SET status = 'cancelled', revision = ?, updatedAt = ? WHERE id = ?",
                       arguments: [try Self.nextRevision(plan.revision), max(now, plan.updatedAt).timeIntervalSince1970, key])
      case .delete(let expected):
        let plan = try Self.read(db, id: command.planID)
        guard expected > 0, plan.revision == expected else { throw OutfitPlanError.conflict }
        try Self.erase(db, id: command.planID)
      }
      let deleting: Bool
      if case .delete = command.action { deleting = true } else { deleting = false }
      try db.execute(sql: "INSERT INTO outfit_plan_mutations(id, planID, operation, fingerprint) VALUES (?, ?, ?, ?)",
                     arguments: [command.id.uuidString, key, operation, deleting ? nil : fingerprint])
      return deleting ? nil : try Self.read(db, id: command.planID)
    }
  }

  private func save(_ db: Database, id: UUID, input: OutfitPlanInput, expected: Int?, exists: Bool) throws {
    // Revalidate even a decoded or forged value before any write.
    _ = try OutfitPlanInput(localDate: input.localDate, timeZone: input.timeZone, contextSummary: input.contextSummary,
                            items: input.items, confirmedUnavailable: input.confirmedUnavailable)
    let old = exists ? try Self.read(db, id: id) : nil
    if let old {
      guard expected == old.revision, old.status == .active, input.timeZone == old.timeZone else { throw OutfitPlanError.conflict }
    } else if expected != nil { throw OutfitPlanError.notFound }
    let today = try OutfitLocalDate(instant: now, timeZone: input.timeZone)
    guard input.localDate >= today || input.localDate == old?.localDate else { throw OutfitPlanError.invalidDate }
    var items: [(WardrobeItem, String?)] = []
    for selected in input.items {
      guard let record = try WardrobeRecord.fetchOne(db, key: selected.itemID.uuidString) else { throw OutfitPlanError.conflict }
      let item = try record.domain()
      guard item.revision == selected.revision else { throw OutfitPlanError.conflict }
      if item.input.availability != .wearable && !input.confirmedUnavailable.contains(item.id) { throw OutfitPlanError.unavailableItems }
      let photo = try String.fetchOne(db, sql: "SELECT id FROM wardrobe_photos WHERE itemID = ? AND state = 'ready'",
                                     arguments: [item.id.uuidString])
      items.append((item, photo))
    }
    let revision = try old.map { try Self.nextRevision($0.revision) } ?? 1
    try db.execute(sql: """
      INSERT INTO outfit_plans(id, localDate, timeZone, contextSummary, sourceKind, status, revision, createdAt, updatedAt)
      VALUES (?, ?, ?, ?, 'manual', 'active', ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET localDate = excluded.localDate, contextSummary = excluded.contextSummary,
        revision = excluded.revision, updatedAt = excluded.updatedAt
      """, arguments: [id.uuidString, input.localDate.value, input.timeZone, input.contextSummary, revision,
                        (old?.createdAt ?? now).timeIntervalSince1970, max(now, old?.updatedAt ?? now).timeIntervalSince1970])
    try db.execute(sql: "DELETE FROM outfit_plan_items WHERE planID = ?", arguments: [id.uuidString])
    for (index, entry) in items.enumerated() {
      try db.execute(sql: """
        INSERT INTO outfit_plan_items(planID, ordinal, wardrobeItemID, itemRevision, name, category, availability,
          photoAssetID, redacted, formalityBand, warmthBand, rainUse, walkingUse)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
        """, arguments: [id.uuidString, index, entry.0.id.uuidString, entry.0.revision, entry.0.input.name,
                          entry.0.input.category.rawValue, entry.0.input.availability.rawValue, entry.1,
                          entry.0.input.attributes.formalityBand?.rawValue,
                          entry.0.input.attributes.warmthBand?.rawValue,
                          entry.0.input.attributes.rainUse?.rawValue,
                          entry.0.input.attributes.walkingUse?.rawValue])
    }
  }

  static func impact(_ db: Database, itemID: UUID) throws -> WardrobeDeletionImpact {
    let rows = try Row.fetchAll(db, sql: """
      SELECT p.id, p.revision FROM outfit_plans p JOIN outfit_plan_items i ON i.planID = p.id
      WHERE i.wardrobeItemID = ? AND p.status != 'deleted' ORDER BY p.id
      """, arguments: [itemID.uuidString])
    return WardrobeDeletionImpact(plans: try rows.map { row in
      guard let id = UUID(uuidString: row["id"]), let revision: Int = row["revision"], revision > 0 else {
        throw WardrobeError.invalidStoredData
      }
      return WardrobeAffectedPlan(id: id, revision: revision)
    })
  }

  static func deleteWardrobeReferences(_ db: Database, itemID: UUID, expected: WardrobeDeletionImpact,
                                       policy: WardrobeHistoryDeletionPolicy, now: Date) throws {
    let current = try impact(db, itemID: itemID)
    guard current == expected else { throw WardrobeError.conflict }
    for affected in current.plans {
      switch policy {
      case .deleteAffectedPlans: try erase(db, id: affected.id)
      case .redactSnapshots:
        try db.execute(sql: """
          UPDATE outfit_plan_items SET wardrobeItemID = NULL, itemRevision = NULL, name = NULL,
            category = NULL, availability = NULL, photoAssetID = NULL, formalityBand = NULL,
            warmthBand = NULL, rainUse = NULL, walkingUse = NULL, redacted = 1
          WHERE planID = ? AND wardrobeItemID = ?
          """, arguments: [affected.id.uuidString, itemID.uuidString])
        try db.execute(sql: "UPDATE outfit_plans SET revision = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                       arguments: [try nextRevision(affected.revision), now.timeIntervalSince1970, affected.id.uuidString])
      }
    }
  }

  private static func erase(_ db: Database, id: UUID) throws {
    try db.execute(sql: "DELETE FROM outfit_plan_items WHERE planID = ?", arguments: [id.uuidString])
    try db.execute(sql: "UPDATE outfit_plan_mutations SET fingerprint = NULL WHERE planID = ?", arguments: [id.uuidString])
    try db.execute(sql: """
      UPDATE outfit_plans SET localDate = NULL, timeZone = NULL, contextSummary = NULL, sourceKind = NULL,
        status = 'deleted', revision = NULL, createdAt = NULL, updatedAt = NULL WHERE id = ?
      """, arguments: [id.uuidString])
  }

  private static func nextRevision(_ value: Int) throws -> Int {
    guard value > 0, value < Int.max else { throw WardrobeError.invalidStoredData }
    return value + 1
  }

  private static func read(_ db: Database, id: UUID) throws -> OutfitPlan {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM outfit_plans WHERE id = ?", arguments: [id.uuidString]),
          (row["status"] as String) != "deleted" else { throw OutfitPlanError.notFound }
    guard let day: String = row["localDate"], let date = try? OutfitLocalDate(day),
          let zone: String = row["timeZone"], (try? OutfitLocalDate.zone(zone)) != nil,
          (row["sourceKind"] as String?) == "manual", let status = OutfitPlanStatus(rawValue: row["status"]),
          let revision: Int = row["revision"], revision > 0,
          let created: Double = row["createdAt"], let updated: Double = row["updatedAt"],
          created.isFinite, updated.isFinite, updated >= created else { throw WardrobeError.invalidStoredData }
    let summary: String? = row["contextSummary"]
    guard summary.map({ !$0.isEmpty && $0.count <= 120 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
      && !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }) != false else {
      throw WardrobeError.invalidStoredData
    }
    let rows = try Row.fetchAll(db, sql: "SELECT * FROM outfit_plan_items WHERE planID = ? ORDER BY ordinal", arguments: [id.uuidString])
    guard (1...20).contains(rows.count) else { throw WardrobeError.invalidStoredData }
    let items = try rows.enumerated().map { index, item -> OutfitPlanItemSnapshot in
      guard (item["ordinal"] as Int) == index else { throw WardrobeError.invalidStoredData }
      let redacted: Int = item["redacted"]
      if redacted == 1 {
        guard ["wardrobeItemID", "itemRevision", "name", "category", "availability", "photoAssetID",
               "formalityBand", "warmthBand", "rainUse", "walkingUse"]
          .allSatisfy({ item[$0] == DatabaseValue.null }) else {
          throw WardrobeError.invalidStoredData
        }
        return OutfitPlanItemSnapshot(ordinal: index, content: nil)
      }
      guard redacted == 0, let key: String = item["wardrobeItemID"], let itemID = UUID(uuidString: key),
            let version: Int = item["itemRevision"], version > 0,
            let name: String = item["name"], let categoryText: String = item["category"], let category = WardrobeCategory(rawValue: categoryText),
            let stateText: String = item["availability"], let state = WardrobeAvailability(rawValue: stateText),
            let formalityText: String? = item["formalityBand"],
            let warmthText: String? = item["warmthBand"],
            let rainText: String? = item["rainUse"], let walkingText: String? = item["walkingUse"],
            formalityText == nil || WardrobeFormalityBand(rawValue: formalityText ?? "") != nil,
            warmthText == nil || WardrobeWarmthBand(rawValue: warmthText ?? "") != nil,
            rainText == nil || WardrobeUseSuitability(rawValue: rainText ?? "") != nil,
            walkingText == nil || WardrobeUseSuitability(rawValue: walkingText ?? "") != nil,
            let input = try? WardrobeInput(name: name, category: category, availability: state,
              attributes: WardrobeAttributes(
                formalityBand: formalityText.flatMap(WardrobeFormalityBand.init(rawValue:)),
                warmthBand: warmthText.flatMap(WardrobeWarmthBand.init(rawValue:)),
                rainUse: rainText.flatMap(WardrobeUseSuitability.init(rawValue:)),
                walkingUse: walkingText.flatMap(WardrobeUseSuitability.init(rawValue:)))),
            input.name == name else {
        throw WardrobeError.invalidStoredData
      }
      let photoText: String? = item["photoAssetID"]
      guard photoText == nil || UUID(uuidString: photoText ?? "") != nil else { throw WardrobeError.invalidStoredData }
      return OutfitPlanItemSnapshot(ordinal: index, content: OutfitItemContent(itemID: itemID, revision: version,
        input: input, photoAssetID: photoText.flatMap(UUID.init(uuidString:))))
    }
    return OutfitPlan(id: id, localDate: date, timeZone: zone, contextSummary: summary, status: status, revision: revision,
                      createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated), items: items)
  }

  private static func fingerprint(_ command: OutfitPlanMutation) throws -> String {
    // Canonical fields only; no clothing snapshots, paths or original image bytes.
    struct Payload: Encodable {
      let planID: UUID
      let operation: String
      let expected: Int?
      var localDate: OutfitLocalDate?
      var timeZone: String?
      var summary: String?
      var items: [OutfitSelection]?
      var unavailable: [String]?
    }
    let payload: Payload
    switch command.action {
    case .save(let input, let expected):
      payload = Payload(planID: command.planID, operation: "save", expected: expected, localDate: input.localDate,
                        timeZone: input.timeZone, summary: input.contextSummary, items: input.items,
                        unavailable: input.confirmedUnavailable.map(\.uuidString).sorted())
    case .cancel(let expected): payload = Payload(planID: command.planID, operation: "cancel", expected: expected)
    case .delete(let expected): payload = Payload(planID: command.planID, operation: "delete", expected: expected)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
  }
}
