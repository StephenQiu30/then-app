import CryptoKit
import Foundation
import GRDB

nonisolated struct OutfitFeedbackPersistence {
  let pool: DatabasePool
  var now = Date()

  func read(wearEventID: UUID) throws -> OutfitFeedback? {
    try pool.read { try Self.read($0, wearEventID: wearEventID) }
  }

  func mutate(_ command: OutfitFeedbackMutation) throws -> OutfitFeedback? {
    let operation: String
    switch command.action {
    case .save(_, let expected):
      guard expected == nil || (expected ?? 0) > 0 else { throw OutfitFeedbackError.invalidInput }
      operation = "save"
    case .delete(let expected):
      guard expected > 0 else { throw OutfitFeedbackError.invalidInput }
      operation = "delete"
    }
    let fingerprint = try Self.fingerprint(command)
    return try pool.write { db in
      guard try String.fetchOne(db, sql: "SELECT status FROM wear_events WHERE id = ?",
        arguments: [command.wearEventID.uuidString]) == "live" else { throw OutfitFeedbackError.notFound }
      let receipt = try Row.fetchOne(db, sql: """
        SELECT feedbackID, wearEventID, operation, fingerprint FROM outfit_feedback_mutations WHERE id = ?
        """, arguments: [command.id.uuidString])
      if let receipt {
        guard (receipt["feedbackID"] as String) == command.feedbackID.uuidString,
              (receipt["wearEventID"] as String) == command.wearEventID.uuidString,
              (receipt["operation"] as String) == operation,
              (receipt["fingerprint"] as String) == fingerprint else { throw OutfitFeedbackError.conflict }
        return operation == "delete" ? nil : try Self.read(db, wearEventID: command.wearEventID)
      }

      let existing = try Self.read(db, wearEventID: command.wearEventID)
      let result: OutfitFeedback?
      switch command.action {
      case .save(let input, let expected):
        _ = try OutfitFeedbackInput(thermalComfort: input.thermalComfort,
          activityComfort: input.activityComfort, occasionFit: input.occasionFit,
          repeatIntent: input.repeatIntent, issueTags: input.issueTags, note: input.note)
        if let existing {
          guard existing.id == command.feedbackID, existing.revision == expected else {
            throw OutfitFeedbackError.conflict
          }
        } else {
          guard expected == nil else { throw OutfitFeedbackError.notFound }
        }
        let revision = try existing.map { try Self.nextRevision($0.revision) } ?? 1
        let createdAt = existing?.createdAt ?? now
        let updatedAt = max(now, existing?.updatedAt ?? now)
        try db.execute(sql: """
          INSERT INTO outfit_feedback(id, wearEventID, thermalComfort, activityComfort, occasionFit,
            repeatIntent, note, revision, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET thermalComfort = excluded.thermalComfort,
            activityComfort = excluded.activityComfort, occasionFit = excluded.occasionFit,
            repeatIntent = excluded.repeatIntent, note = excluded.note,
            revision = excluded.revision, updatedAt = excluded.updatedAt
          """, arguments: [command.feedbackID.uuidString, command.wearEventID.uuidString,
            input.thermalComfort?.rawValue, input.activityComfort?.rawValue,
            input.occasionFit?.rawValue, input.repeatIntent?.rawValue, input.note,
            revision, createdAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970])
        try db.execute(sql: "DELETE FROM outfit_feedback_issue_tags WHERE feedbackID = ?",
          arguments: [command.feedbackID.uuidString])
        for tag in input.issueTags.sorted(by: { $0.rawValue < $1.rawValue }) {
          try db.execute(sql: "INSERT INTO outfit_feedback_issue_tags(feedbackID, tag) VALUES (?, ?)",
            arguments: [command.feedbackID.uuidString, tag.rawValue])
        }
        result = try Self.read(db, wearEventID: command.wearEventID)
      case .delete(let expected):
        guard let existing, existing.id == command.feedbackID else { throw OutfitFeedbackError.notFound }
        guard existing.revision == expected else { throw OutfitFeedbackError.conflict }
        try db.execute(sql: "DELETE FROM outfit_feedback WHERE id = ?", arguments: [command.feedbackID.uuidString])
        result = nil
      }
      try db.execute(sql: """
        INSERT INTO outfit_feedback_mutations(id, feedbackID, wearEventID, operation, fingerprint)
        VALUES (?, ?, ?, ?, ?)
        """, arguments: [command.id.uuidString, command.feedbackID.uuidString,
          command.wearEventID.uuidString, operation, fingerprint])
      return result
    }
  }

  func rebuildEvidence() throws -> [PreferenceEvidence] {
    try pool.read { db in
      let rows = try Row.fetchAll(db, sql: """
        SELECT f.wearEventID, f.thermalComfort, f.activityComfort, f.occasionFit,
          f.repeatIntent, f.updatedAt
        FROM outfit_feedback f JOIN wear_events e ON e.id = f.wearEventID
        WHERE e.status = 'live' ORDER BY f.wearEventID
        """)
      struct Bucket: Hashable { let itemIDs: [UUID]; let dimension: PreferenceEvidenceDimension }
      var values: [Bucket: [String: (count: Int, updatedAt: Date)]] = [:]
      for row in rows {
        guard let eventText: String = row["wearEventID"],
              let eventID = UUID(uuidString: eventText), let updated: Double = row["updatedAt"],
              updated.isFinite else { throw WardrobeError.invalidStoredData }
        let itemIDs = try String.fetchAll(db, sql: """
          SELECT wardrobeItemID FROM wear_event_items
          WHERE eventID = ? AND wardrobeItemID IS NOT NULL ORDER BY wardrobeItemID
          """, arguments: [eventID.uuidString]).map {
            guard let id = UUID(uuidString: $0) else { throw WardrobeError.invalidStoredData }
            return id
          }
        guard !itemIDs.isEmpty else { continue }
        let dimensions: [(PreferenceEvidenceDimension, String?)] = [
          (.thermalComfort, row["thermalComfort"]), (.activityComfort, row["activityComfort"]),
          (.occasionFit, row["occasionFit"]), (.repeatIntent, row["repeatIntent"])
        ]
        for (dimension, value) in dimensions {
          guard let value else { continue }
          let key = Bucket(itemIDs: itemIDs, dimension: dimension)
          var counts = values[key, default: [:]]
          let previous = counts[value] ?? (0, .distantPast)
          counts[value] = (previous.count + 1, max(previous.updatedAt, Date(timeIntervalSince1970: updated)))
          values[key] = counts
        }
      }
      return values.compactMap { key, counts -> PreferenceEvidence? in
        let ranked = counts.sorted { left, right in
          left.value.count == right.value.count ? left.key < right.key : left.value.count > right.value.count
        }
        guard let winner = ranked.first, winner.value.count >= 2,
              ranked.dropFirst().first?.value.count != winner.value.count else { return nil }
        return PreferenceEvidence(itemIDs: key.itemIDs, dimension: key.dimension, value: winner.key,
          winningSampleCount: winner.value.count, totalSampleCount: counts.values.reduce(0) { $0 + $1.count },
          updatedAt: counts.values.map(\.updatedAt).max() ?? winner.value.updatedAt)
      }.sorted {
        if $0.itemIDs != $1.itemIDs { return $0.itemIDs.map(\.uuidString).joined() < $1.itemIDs.map(\.uuidString).joined() }
        return $0.dimension.rawValue < $1.dimension.rawValue
      }
    }
  }

  static func eraseForEvent(_ db: Database, wearEventID: UUID) throws {
    try db.execute(sql: "DELETE FROM outfit_feedback_mutations WHERE wearEventID = ?",
      arguments: [wearEventID.uuidString])
    try db.execute(sql: "DELETE FROM outfit_feedback WHERE wearEventID = ?",
      arguments: [wearEventID.uuidString])
  }

  static func read(_ db: Database, wearEventID: UUID) throws -> OutfitFeedback? {
    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM outfit_feedback WHERE wearEventID = ?",
      arguments: [wearEventID.uuidString]) else { return nil }
    guard let idText: String = row["id"], let id = UUID(uuidString: idText),
          let eventText: String = row["wearEventID"], let eventID = UUID(uuidString: eventText),
          let revision: Int = row["revision"], revision > 0,
          let created: Double = row["createdAt"], let updated: Double = row["updatedAt"],
          created.isFinite, updated.isFinite, updated >= created else { throw WardrobeError.invalidStoredData }
    let thermalText: String? = row["thermalComfort"]
    let activityText: String? = row["activityComfort"]
    let occasionText: String? = row["occasionFit"]
    let repeatText: String? = row["repeatIntent"]
    guard thermalText == nil || ThermalComfort(rawValue: thermalText ?? "") != nil,
          activityText == nil || ActivityComfort(rawValue: activityText ?? "") != nil,
          occasionText == nil || OccasionFit(rawValue: occasionText ?? "") != nil,
          repeatText == nil || RepeatIntent(rawValue: repeatText ?? "") != nil else {
      throw WardrobeError.invalidStoredData
    }
    let tags = try Set(String.fetchAll(db, sql: "SELECT tag FROM outfit_feedback_issue_tags WHERE feedbackID = ?",
      arguments: [id.uuidString]).map {
        guard let tag = OutfitFeedbackIssueTag(rawValue: $0) else { throw WardrobeError.invalidStoredData }
        return tag
      })
    let input = try OutfitFeedbackInput(thermalComfort: thermalText.flatMap(ThermalComfort.init(rawValue:)),
      activityComfort: activityText.flatMap(ActivityComfort.init(rawValue:)),
      occasionFit: occasionText.flatMap(OccasionFit.init(rawValue:)),
      repeatIntent: repeatText.flatMap(RepeatIntent.init(rawValue:)), issueTags: tags, note: row["note"])
    return OutfitFeedback(id: id, wearEventID: eventID, input: input, revision: revision,
      createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated))
  }

  private static func fingerprint(_ command: OutfitFeedbackMutation) throws -> String {
    struct Input: Encodable {
      let thermalComfort: String?
      let activityComfort: String?
      let occasionFit: String?
      let repeatIntent: String?
      let issueTags: [String]
      let note: String?

      init(_ input: OutfitFeedbackInput) {
        thermalComfort = input.thermalComfort?.rawValue
        activityComfort = input.activityComfort?.rawValue
        occasionFit = input.occasionFit?.rawValue
        repeatIntent = input.repeatIntent?.rawValue
        issueTags = input.issueTags.map(\.rawValue).sorted()
        note = input.note
      }
    }
    struct Payload: Encodable {
      let feedbackID: UUID
      let wearEventID: UUID
      let operation: String
      let input: Input?
      let expectedRevision: Int?
    }
    let payload: Payload
    switch command.action {
    case .save(let input, let expected):
      payload = Payload(feedbackID: command.feedbackID, wearEventID: command.wearEventID,
        operation: "save", input: Input(input), expectedRevision: expected)
    case .delete(let expected):
      payload = Payload(feedbackID: command.feedbackID, wearEventID: command.wearEventID,
        operation: "delete", input: nil, expectedRevision: expected)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
  }

  private static func nextRevision(_ value: Int) throws -> Int {
    guard value > 0, value < Int.max else { throw WardrobeError.invalidStoredData }
    return value + 1
  }
}
