import CryptoKit
import Foundation
import GRDB

/// Owns actual-wear writes inside the same pool as plans, wardrobe facts and media references.
nonisolated struct WearEventPersistence {
  let pool: DatabasePool
  var now = Date()

  func read(id: UUID) throws -> WearEvent {
    try pool.read { try Self.read($0, id: id) }
  }

  func list(on date: OutfitLocalDate?) throws -> [WearEvent] {
    try pool.read { db in
      let rows: [String]
      if let date {
        rows = try String.fetchAll(db, sql: """
          SELECT id FROM wear_events WHERE status = 'live' AND localDate = ?
          ORDER BY createdAt DESC, id ASC
          """, arguments: [date.value])
      } else {
        rows = try String.fetchAll(db, sql: """
          SELECT id FROM wear_events WHERE status = 'live'
          ORDER BY localDate DESC, createdAt DESC, id ASC
          """)
      }
      return try rows.map {
        guard let id = UUID(uuidString: $0) else { throw WardrobeError.invalidStoredData }
        return try Self.read(db, id: id)
      }
    }
  }

  func wearCount(itemID: UUID) throws -> Int {
    try pool.read { db in
      try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM wear_event_items i JOIN wear_events e ON e.id = i.eventID
        WHERE e.status = 'live' AND i.wardrobeItemID = ?
        """, arguments: [itemID.uuidString]) ?? 0
    }
  }

  func timeline(after cursor: OutfitTimelineCursor?) throws -> OutfitTimelinePage {
    try pool.read { db in
      var predicate = ""
      var arguments = StatementArguments()
      if let cursor {
        guard cursor.createdAt.timeIntervalSince1970.isFinite,
              cursor.kind == "plan" || cursor.kind == "wear" else { throw WearEventError.invalidInput }
        predicate = """
          WHERE localDate < ? OR (localDate = ? AND createdAt < ?)
            OR (localDate = ? AND createdAt = ? AND kind > ?)
            OR (localDate = ? AND createdAt = ? AND kind = ? AND id > ?)
          """
        arguments += [cursor.localDate.value, cursor.localDate.value, cursor.createdAt.timeIntervalSince1970,
          cursor.localDate.value, cursor.createdAt.timeIntervalSince1970, cursor.kind,
          cursor.localDate.value, cursor.createdAt.timeIntervalSince1970, cursor.kind, cursor.id.uuidString]
      }
      let rows = try Row.fetchAll(db, sql: """
        SELECT * FROM (
          SELECT id, localDate, createdAt, 'plan' AS kind FROM outfit_plans WHERE status != 'deleted'
          UNION ALL
          SELECT id, localDate, createdAt, 'wear' AS kind FROM wear_events WHERE status = 'live'
        ) \(predicate)
        ORDER BY localDate DESC, createdAt DESC, kind ASC, id ASC LIMIT 31
        """, arguments: arguments)
      let entries = try rows.prefix(30).map { row -> OutfitTimelineEntry in
        guard let text: String = row["id"], let id = UUID(uuidString: text),
              let kind: String = row["kind"] else { throw WardrobeError.invalidStoredData }
        switch kind {
        case "plan": return .plan(try OutfitPlanPersistence.read(db, id: id))
        case "wear": return .wear(try Self.read(db, id: id))
        default: throw WardrobeError.invalidStoredData
        }
      }
      let next = rows.count > 30 ? entries.last.map {
        OutfitTimelineCursor(localDate: $0.localDate, createdAt: $0.createdAt,
          kind: { if case .plan = $0 { "plan" } else { "wear" } }($0), id: $0.entityID)
      } : nil
      return OutfitTimelinePage(entries: entries, nextCursor: next)
    }
  }

  func mutate(_ command: WearEventMutation) throws -> WearEvent? {
    let operation: String
    switch command.action {
    case .save(_, let expected):
      guard expected == nil || (expected ?? 0) > 0 else { throw WearEventError.invalidInput }
      operation = "save"
    case .delete(let expected):
      guard expected > 0 else { throw WearEventError.invalidInput }
      operation = "delete"
    }
    let fingerprint = try Self.fingerprint(command)
    return try pool.write { db in
      let key = command.eventID.uuidString
      let storedStatus = try String.fetchOne(db, sql: "SELECT status FROM wear_events WHERE id = ?", arguments: [key])
      let receipt = try Row.fetchOne(db, sql: """
        SELECT eventID, operation, fingerprint, resultRevision FROM wear_event_mutations WHERE id = ?
        """, arguments: [command.id.uuidString])
      if let receipt,
         (receipt["eventID"] as String) != key || (receipt["operation"] as String) != operation {
        throw WearEventError.conflict
      }
      if storedStatus == "deleted" {
        if case .delete = command.action {
          if receipt == nil {
            try db.execute(sql: """
              INSERT INTO wear_event_mutations(id, eventID, operation, fingerprint, resultRevision)
              VALUES (?, ?, 'delete', NULL, NULL)
              """, arguments: [command.id.uuidString, key])
          }
          return nil
        }
        throw WearEventError.notFound
      }
      if let receipt {
        guard (receipt["fingerprint"] as String?) == fingerprint else { throw WearEventError.conflict }
        return operation == "delete" ? nil : try Self.read(db, id: command.eventID)
      }

      let result: WearEvent?
      switch command.action {
      case .save(let input, let expected):
        try save(db, id: command.eventID, input: input, expected: expected, exists: storedStatus != nil)
        result = try Self.read(db, id: command.eventID)
      case .delete(let expected):
        let event = try Self.read(db, id: command.eventID)
        guard event.revision == expected else { throw WearEventError.conflict }
        try Self.erase(db, event: event, now: now)
        result = nil
      }
      try db.execute(sql: """
        INSERT INTO wear_event_mutations(id, eventID, operation, fingerprint, resultRevision)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [command.id.uuidString, key, operation, result == nil ? nil : fingerprint, result?.revision])
      return result
    }
  }

  private func save(_ db: Database, id: UUID, input: WearEventInput, expected: Int?, exists: Bool) throws {
    _ = try WearEventInput(localDate: input.localDate, timeZone: input.timeZone,
      completeness: input.completeness, contextSummary: input.contextSummary, items: input.items,
      laundryItemIDs: input.laundryItemIDs, confirmedUnavailable: input.confirmedUnavailable,
      sourcePlanID: input.sourcePlanID, sourcePlanRevision: input.sourcePlanRevision,
      sourceKind: input.sourceKind, duplicateConfirmation: input.duplicateConfirmation)
    let old = exists ? try Self.read(db, id: id) : nil
    if let old {
      guard expected == old.revision, input.timeZone == old.timeZone else { throw WearEventError.conflict }
    } else if expected != nil { throw WearEventError.notFound }
    let today = try OutfitLocalDate(instant: now, timeZone: input.timeZone)
    guard input.localDate <= today else { throw WearEventError.invalidDate }

    let candidates = try Self.duplicateCandidates(db, eventID: id, date: input.localDate,
      selectedIDs: Set(input.items.map(\.itemID)))
    guard Set(candidates) == input.duplicateConfirmation else {
      throw WearEventError.duplicateConfirmationRequired(candidates)
    }

    var sourcePlan: OutfitPlan?
    if let planID = input.sourcePlanID, let sourceRevision = input.sourcePlanRevision {
      sourcePlan = try OutfitPlanPersistence.read(db, id: planID)
      let preservesExistingSource = old?.sourcePlanID == planID && old?.sourcePlanRevision == sourceRevision
      guard (preservesExistingSource || sourcePlan?.revision == sourceRevision),
            sourcePlan?.status == .active || sourcePlan?.status == .completed else {
        throw WearEventError.conflict
      }
    }

    let oldByID = Dictionary(uniqueKeysWithValues: (old?.items ?? []).compactMap { snapshot in
      snapshot.content.map { ($0.itemID, $0) }
    })
    var snapshots: [OutfitItemContent] = []
    var currentItems: [WardrobeItem] = []
    for selected in input.items {
      if let historical = oldByID[selected.itemID], historical.revision == selected.revision {
        snapshots.append(historical)
        if input.laundryItemIDs.contains(selected.itemID) {
          guard let record = try WardrobeRecord.fetchOne(db, key: selected.itemID.uuidString) else {
            throw WearEventError.conflict
          }
          let current = try record.domain()
          guard current.revision == selected.revision else { throw WearEventError.conflict }
          currentItems.append(current)
        }
        continue
      }
      guard let record = try WardrobeRecord.fetchOne(db, key: selected.itemID.uuidString) else {
        throw WearEventError.conflict
      }
      let item = try record.domain()
      guard item.revision == selected.revision else { throw WearEventError.conflict }
      if item.input.availability != .wearable && !input.confirmedUnavailable.contains(item.id) {
        throw WearEventError.unavailableItems
      }
      let photo = try String.fetchOne(db, sql: """
        SELECT id FROM wardrobe_photos WHERE itemID = ? AND state = 'ready'
        """, arguments: [item.id.uuidString]).flatMap(UUID.init(uuidString:))
      snapshots.append(OutfitItemContent(itemID: item.id, revision: item.revision,
        input: item.input, photoAssetID: photo))
      if input.laundryItemIDs.contains(item.id) { currentItems.append(item) }
    }

    let oldSource = old?.sourcePlanID
    let revision = try old.map { try Self.nextRevision($0.revision) } ?? 1
    try db.execute(sql: """
      INSERT INTO wear_events(id, sourcePlanID, sourcePlanRevision, sourceKind, localDate, timeZone,
        completeness, contextSummary, status, revision, createdAt, updatedAt)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'live', ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET sourcePlanID = excluded.sourcePlanID,
        sourcePlanRevision = excluded.sourcePlanRevision, sourceKind = excluded.sourceKind,
        localDate = excluded.localDate, completeness = excluded.completeness,
        contextSummary = excluded.contextSummary, revision = excluded.revision, updatedAt = excluded.updatedAt
      """, arguments: [id.uuidString, input.sourcePlanID?.uuidString, input.sourcePlanRevision,
        input.sourceKind.rawValue, input.localDate.value, input.timeZone, input.completeness.rawValue,
        input.contextSummary, revision, (old?.createdAt ?? now).timeIntervalSince1970,
        max(now, old?.updatedAt ?? now).timeIntervalSince1970])
    try db.execute(sql: "DELETE FROM wear_event_items WHERE eventID = ?", arguments: [id.uuidString])
    for (index, content) in snapshots.enumerated() {
      try db.execute(sql: """
        INSERT INTO wear_event_items(eventID, ordinal, wardrobeItemID, itemRevision, name, category,
          availability, photoAssetID, redacted, formalityBand, warmthBand, rainUse, walkingUse)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
        """, arguments: [id.uuidString, index, content.itemID.uuidString, content.revision,
          content.input.name, content.input.category.rawValue, content.input.availability.rawValue,
          content.photoAssetID?.uuidString, content.input.attributes.formalityBand?.rawValue,
          content.input.attributes.warmthBand?.rawValue, content.input.attributes.rainUse?.rawValue,
          content.input.attributes.walkingUse?.rawValue])
    }
    for item in currentItems where item.input.availability != .laundry {
      let updated = WardrobeItem(id: item.id,
        input: try WardrobeInput(name: item.input.name, category: item.input.category,
          availability: .laundry, attributes: item.input.attributes), source: item.source,
        revision: try Self.nextRevision(item.revision), createdAt: item.createdAt,
        updatedAt: max(now, item.updatedAt))
      try WardrobeRecord(updated).update(db)
    }
    for planID in Set([oldSource, sourcePlan?.id].compactMap { $0 }) {
      try Self.recomputePlan(db, id: planID, now: now)
    }
  }

  static func duplicateCandidates(_ db: Database, eventID: UUID, date: OutfitLocalDate,
                                  selectedIDs: Set<UUID>) throws -> [WearEventCandidate] {
    guard !selectedIDs.isEmpty else { return [] }
    let rows = try Row.fetchAll(db, sql: """
      SELECT id, revision FROM wear_events
      WHERE status = 'live' AND localDate = ? AND id != ? ORDER BY id
      """, arguments: [date.value, eventID.uuidString])
    var result: [WearEventCandidate] = []
    for row in rows {
      guard let text: String = row["id"], let id = UUID(uuidString: text),
            let revision: Int = row["revision"], revision > 0 else { throw WardrobeError.invalidStoredData }
      let itemTexts = try String.fetchAll(db, sql: """
        SELECT wardrobeItemID FROM wear_event_items WHERE eventID = ? AND wardrobeItemID IS NOT NULL
        """, arguments: [text])
      let other = Set(try itemTexts.map {
        guard let id = UUID(uuidString: $0) else { throw WardrobeError.invalidStoredData }
        return id
      })
      let union = selectedIDs.union(other).count
      let intersection = selectedIDs.intersection(other).count
      if union > 0, Double(intersection) / Double(union) >= 0.8 {
        result.append(WearEventCandidate(id: id, revision: revision))
      }
    }
    return result
  }

  static func impact(_ db: Database, itemID: UUID) throws -> [WardrobeAffectedWearEvent] {
    try Row.fetchAll(db, sql: """
      SELECT e.id, e.revision FROM wear_events e JOIN wear_event_items i ON i.eventID = e.id
      WHERE i.wardrobeItemID = ? AND e.status = 'live' ORDER BY e.id
      """, arguments: [itemID.uuidString]).map { row in
      guard let text: String = row["id"], let id = UUID(uuidString: text),
            let revision: Int = row["revision"], revision > 0 else { throw WardrobeError.invalidStoredData }
      return WardrobeAffectedWearEvent(id: id, revision: revision)
    }
  }

  static func deleteWardrobeReferences(_ db: Database, itemID: UUID,
                                       expected: [WardrobeAffectedWearEvent],
                                       policy: WardrobeHistoryDeletionPolicy, now: Date) throws {
    let current = try impact(db, itemID: itemID)
    guard current == expected else { throw WardrobeError.conflict }
    for affected in current {
      let event = try read(db, id: affected.id)
      switch policy {
      case .deleteAffectedHistory:
        try erase(db, event: event, now: now)
      case .redactSnapshots:
        try db.execute(sql: """
          UPDATE wear_event_items SET wardrobeItemID = NULL, itemRevision = NULL, name = NULL,
            category = NULL, availability = NULL, photoAssetID = NULL, formalityBand = NULL,
            warmthBand = NULL, rainUse = NULL, walkingUse = NULL, redacted = 1
          WHERE eventID = ? AND wardrobeItemID = ?
          """, arguments: [affected.id.uuidString, itemID.uuidString])
        try db.execute(sql: "UPDATE wear_events SET revision = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ?",
          arguments: [try nextRevision(affected.revision), now.timeIntervalSince1970, affected.id.uuidString])
      }
    }
  }

  private static func erase(_ db: Database, event: WearEvent, now: Date) throws {
    try db.execute(sql: "DELETE FROM wear_event_items WHERE eventID = ?", arguments: [event.id.uuidString])
    try db.execute(sql: "UPDATE wear_event_mutations SET fingerprint = NULL, resultRevision = NULL WHERE eventID = ?",
      arguments: [event.id.uuidString])
    try db.execute(sql: """
      UPDATE wear_events SET sourcePlanID = NULL, sourcePlanRevision = NULL, sourceKind = NULL,
        localDate = NULL, timeZone = NULL, completeness = NULL, contextSummary = NULL,
        status = 'deleted', revision = NULL, createdAt = NULL, updatedAt = NULL WHERE id = ?
      """, arguments: [event.id.uuidString])
    if let planID = event.sourcePlanID { try recomputePlan(db, id: planID, now: now) }
  }

  static func recomputePlan(_ db: Database, id: UUID, now: Date) throws {
    guard let row = try Row.fetchOne(db, sql: "SELECT status, revision, updatedAt FROM outfit_plans WHERE id = ?",
      arguments: [id.uuidString]), let statusText: String = row["status"], statusText != "deleted",
      let status = OutfitPlanStatus(rawValue: statusText), let revision: Int = row["revision"],
      let updatedAt: Double = row["updatedAt"] else { return }
    guard status != .cancelled && status != .notWorn else { return }
    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wear_events WHERE status = 'live' AND sourcePlanID = ?",
      arguments: [id.uuidString]) ?? 0
    let desired: OutfitPlanStatus = count > 0 ? .completed : .active
    guard desired != status else { return }
    try db.execute(sql: "UPDATE outfit_plans SET status = ?, revision = ?, updatedAt = ? WHERE id = ?",
      arguments: [desired.rawValue, try nextRevision(revision), max(now.timeIntervalSince1970, updatedAt), id.uuidString])
  }

  static func unlinkPlan(_ db: Database, id: UUID, now: Date) throws {
    let rows = try Row.fetchAll(db, sql: "SELECT id, revision, updatedAt FROM wear_events WHERE status = 'live' AND sourcePlanID = ?",
      arguments: [id.uuidString])
    for row in rows {
      guard let text: String = row["id"], let revision: Int = row["revision"],
            let updatedAt: Double = row["updatedAt"] else { throw WardrobeError.invalidStoredData }
      try db.execute(sql: """
        UPDATE wear_events SET sourcePlanID = NULL, sourcePlanRevision = NULL, sourceKind = 'unplanned',
          revision = ?, updatedAt = ? WHERE id = ?
        """, arguments: [try nextRevision(revision), max(now.timeIntervalSince1970, updatedAt), text])
    }
  }

  static func read(_ db: Database, id: UUID) throws -> WearEvent {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM wear_events WHERE id = ?", arguments: [id.uuidString]),
          (row["status"] as String) != "deleted" else { throw WearEventError.notFound }
    guard let day: String = row["localDate"], let date = try? OutfitLocalDate(day),
          let zone: String = row["timeZone"], (try? OutfitLocalDate.zone(zone)) != nil,
          let completenessText: String = row["completeness"],
          let completeness = WearEventCompleteness(rawValue: completenessText),
          let sourceText: String = row["sourceKind"], let source = WearEventSourceKind(rawValue: sourceText),
          let revision: Int = row["revision"], revision > 0,
          let created: Double = row["createdAt"], let updated: Double = row["updatedAt"],
          created.isFinite, updated.isFinite, updated >= created else { throw WardrobeError.invalidStoredData }
    let planText: String? = row["sourcePlanID"]
    let planRevision: Int? = row["sourcePlanRevision"]
    guard (planText == nil) == (planRevision == nil),
          planText == nil || UUID(uuidString: planText ?? "") != nil,
          planRevision == nil || (planRevision ?? 0) > 0,
          source == .unplanned ? planText == nil : planText != nil else { throw WardrobeError.invalidStoredData }
    let summary: String? = row["contextSummary"]
    guard summary.map({ !$0.isEmpty && $0.count <= 120 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
      && !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }) != false else {
      throw WardrobeError.invalidStoredData
    }
    let rows = try Row.fetchAll(db, sql: "SELECT * FROM wear_event_items WHERE eventID = ? ORDER BY ordinal",
      arguments: [id.uuidString])
    guard (1...20).contains(rows.count) else { throw WardrobeError.invalidStoredData }
    let items = try rows.enumerated().map { index, item -> OutfitPlanItemSnapshot in
      guard (item["ordinal"] as Int) == index else { throw WardrobeError.invalidStoredData }
      if (item["redacted"] as Int) == 1 { return OutfitPlanItemSnapshot(ordinal: index, content: nil) }
      guard let key: String = item["wardrobeItemID"], let itemID = UUID(uuidString: key),
            let version: Int = item["itemRevision"], version > 0,
            let name: String = item["name"], let categoryText: String = item["category"],
            let category = WardrobeCategory(rawValue: categoryText),
            let availabilityText: String = item["availability"],
            let availability = WardrobeAvailability(rawValue: availabilityText) else {
        throw WardrobeError.invalidStoredData
      }
      let formalityText: String? = item["formalityBand"]
      let warmthText: String? = item["warmthBand"]
      let rainText: String? = item["rainUse"]
      let walkingText: String? = item["walkingUse"]
      guard formalityText == nil || WardrobeFormalityBand(rawValue: formalityText ?? "") != nil,
            warmthText == nil || WardrobeWarmthBand(rawValue: warmthText ?? "") != nil,
            rainText == nil || WardrobeUseSuitability(rawValue: rainText ?? "") != nil,
            walkingText == nil || WardrobeUseSuitability(rawValue: walkingText ?? "") != nil,
            let input = try? WardrobeInput(name: name, category: category, availability: availability,
              attributes: WardrobeAttributes(
                formalityBand: formalityText.flatMap(WardrobeFormalityBand.init(rawValue:)),
                warmthBand: warmthText.flatMap(WardrobeWarmthBand.init(rawValue:)),
                rainUse: rainText.flatMap(WardrobeUseSuitability.init(rawValue:)),
                walkingUse: walkingText.flatMap(WardrobeUseSuitability.init(rawValue:)))) else {
        throw WardrobeError.invalidStoredData
      }
      let photoText: String? = item["photoAssetID"]
      guard photoText == nil || UUID(uuidString: photoText ?? "") != nil else { throw WardrobeError.invalidStoredData }
      return OutfitPlanItemSnapshot(ordinal: index, content: OutfitItemContent(itemID: itemID,
        revision: version, input: input, photoAssetID: photoText.flatMap(UUID.init(uuidString:))))
    }
    return WearEvent(id: id, localDate: date, timeZone: zone, completeness: completeness,
      contextSummary: summary, sourcePlanID: planText.flatMap(UUID.init(uuidString:)),
      sourcePlanRevision: planRevision, sourceKind: source, revision: revision,
      createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated), items: items)
  }

  private static func nextRevision(_ value: Int) throws -> Int {
    guard value > 0, value < Int.max else { throw WardrobeError.invalidStoredData }
    return value + 1
  }

  private static func fingerprint(_ command: WearEventMutation) throws -> String {
    struct Payload: Encodable {
      let eventID: UUID
      let operation: String
      let expected: Int?
      var input: WearEventInput?
    }
    let payload: Payload
    switch command.action {
    case .save(let input, let expected):
      payload = Payload(eventID: command.eventID, operation: "save", expected: expected, input: input)
    case .delete(let expected):
      payload = Payload(eventID: command.eventID, operation: "delete", expected: expected, input: nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
  }
}
