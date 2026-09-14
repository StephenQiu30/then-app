import Foundation

nonisolated struct WardrobePhotoPersonObservations: Sendable {
  let people: Int
  let faces: Int

  init(people: Int, faces: Int) throws {
    guard people >= 0, faces >= 0 else { throw WardrobePhotoReview.Failure.invalidObservations }
    self.people = people
    self.faces = faces
  }
}

nonisolated struct WardrobePhotoConfirmation: Sendable {
  enum Subject: Hashable, Sendable { case singleGarment, pairOfShoes }
  let subject: Subject?
  let ownedByUser: Bool
  let noPersonInImage: Bool
  let mainItemIsComplete: Bool
}

/// Selection identity gates every result and confirmation. No side effects or automatic approval.
nonisolated struct WardrobePhotoReview: Sendable {
  enum Phase: Equatable, Sendable {
    case empty, loading, analyzing, needsConfirmation, confirmed
    case rejected(Rejection)
  }
  enum Rejection: Equatable, Sendable { case personDetected, analysisUnavailable, inputUnavailable }
  enum Failure: Error { case staleSelection, notReady, confirmationRequired, invalidObservations }

  private(set) var phase: Phase = .empty
  private(set) var selectionID: UUID?
  private(set) var preview: WardrobePreparedPhoto?
  private var confirmedWrite: WardrobePhotoWrite?

  @discardableResult
  mutating func beginSelection() -> UUID {
    let id = UUID()
    selectionID = id
    preview = nil
    confirmedWrite = nil
    phase = .loading
    return id
  }

  mutating func receive(_ photo: WardrobePreparedPhoto, for id: UUID) throws {
    try requireCurrent(id)
    guard phase == .loading else { throw Failure.notReady }
    preview = photo
    phase = .analyzing
  }

  mutating func analyze(_ observations: WardrobePhotoPersonObservations, for id: UUID) throws {
    try requireCurrent(id)
    guard phase == .analyzing else { throw Failure.notReady }
    if observations.people > 0 || observations.faces > 0 {
      reject(.personDetected)
    } else {
      phase = .needsConfirmation
    }
  }

  mutating func failInput(for id: UUID) throws {
    try requireCurrent(id)
    guard phase == .loading else { throw Failure.notReady }
    reject(.inputUnavailable)
  }

  mutating func failAnalysis(for id: UUID) throws {
    try requireCurrent(id)
    guard phase == .analyzing else { throw Failure.notReady }
    reject(.analysisUnavailable)
  }

  mutating func confirm(_ confirmation: WardrobePhotoConfirmation, for id: UUID) throws {
    try requireCurrent(id)
    guard phase == .needsConfirmation, let preview else { throw Failure.notReady }
    guard confirmation.subject != nil, confirmation.ownedByUser, confirmation.noPersonInImage,
          confirmation.mainItemIsComplete else { throw Failure.confirmationRequired }
    confirmedWrite = try WardrobePhotoWrite(id: UUID(), thumbnailID: UUID(), normalized: preview.normalized,
                                          thumbnail: preview.thumbnail, quality: .catalogReady)
    phase = .confirmed
  }

  /// The same confirmed selection retains its command IDs across repository retries.
  func write(for id: UUID) throws -> WardrobePhotoWrite {
    try requireCurrent(id)
    guard phase == .confirmed, let confirmedWrite else { throw Failure.notReady }
    return confirmedWrite
  }

  mutating func cancel() {
    selectionID = nil
    preview = nil
    confirmedWrite = nil
    phase = .empty
  }

  private func requireCurrent(_ id: UUID) throws {
    guard selectionID == id else { throw Failure.staleSelection }
  }

  private mutating func reject(_ reason: Rejection) {
    preview = nil
    confirmedWrite = nil
    phase = .rejected(reason)
  }
}

nonisolated protocol WardrobePhotoPersonAnalyzing: Sendable {
  func analyze(_ image: WardrobeEncodedImage) async throws -> WardrobePhotoPersonObservations
}

nonisolated struct WardrobePhotoCandidate: Sendable {
  let photo: WardrobePreparedPhoto
  let observations: WardrobePhotoPersonObservations
}

nonisolated protocol WardrobePhotoSelecting: Sendable {
  func load() async throws -> WardrobePhotoCandidate
}
