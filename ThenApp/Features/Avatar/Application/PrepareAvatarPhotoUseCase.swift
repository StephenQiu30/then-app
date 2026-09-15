import Foundation

nonisolated protocol AvatarPhotoPreparing: Sendable {
  func execute(
    importing importPhoto: @Sendable () async throws -> AvatarPhotoInputHandle,
    progress: @escaping @Sendable (AvatarPhotoPreparationStage) async -> Void
  ) async throws -> AvatarPhotoPreparationResult
  func discard(_ photo: SanitizedAvatarPhotoHandle) async throws
}

/// Owns an imported session until it either returns a reviewable photo or removes the session.
nonisolated struct PrepareAvatarPhotoUseCase: AvatarPhotoPreparing {
  nonisolated enum Failure: Error, Equatable {
    case invalidSessionOwnership
    case cleanupFailed
  }

  private let sanitizer: any AvatarPhotoSanitizing
  private let analyzer: any AvatarPhotoAnalyzing
  private let policy: AvatarPhotoQualityPolicy
  private let sessionCleaner: any AvatarPhotoSessionCleaning

  init(
    sanitizer: any AvatarPhotoSanitizing,
    analyzer: any AvatarPhotoAnalyzing,
    policy: AvatarPhotoQualityPolicy,
    sessionCleaner: any AvatarPhotoSessionCleaning
  ) {
    self.sanitizer = sanitizer
    self.analyzer = analyzer
    self.policy = policy
    self.sessionCleaner = sessionCleaner
  }

  func execute(
    importing importPhoto: @Sendable () async throws -> AvatarPhotoInputHandle,
    progress: @escaping @Sendable (AvatarPhotoPreparationStage) async -> Void = { _ in }
  ) async throws -> AvatarPhotoPreparationResult {
    await progress(.importing)
    try Task.checkCancellation()
    let input = try await importPhoto()
    let prepared: (photo: SanitizedAvatarPhotoHandle, assessment: AvatarPhotoQualityAssessment)
    do {
      try Task.checkCancellation()
      await progress(.sanitizing)
      try Task.checkCancellation()
      let photo = try await sanitizer.sanitize(input)
      guard photo.sessionID == input.sessionID else {
        throw Failure.invalidSessionOwnership
      }
      try Task.checkCancellation()
      await progress(.analyzing)
      try Task.checkCancellation()
      let signals = try await analyzer.analyze(photo)
      try Task.checkCancellation()
      prepared = (photo, policy.assess(signals))
    } catch {
      do { try await cleanup(input.sessionID) }
      catch { throw Failure.cleanupFailed }
      if error is CancellationError { throw CancellationError() }
      throw error
    }

    switch prepared.assessment.outcome {
    case .pass, .passWithWarning:
      return .review(prepared.photo, prepared.assessment)
    case .needsReplacement:
      try await cleanup(input.sessionID)
      return .replacement(prepared.assessment)
    case .unsupported:
      try await cleanup(input.sessionID)
      return .unsupported(prepared.assessment)
    }
  }

  /// The caller owns a successful review handle and uses this method when replacing or leaving it.
  func discard(_ photo: SanitizedAvatarPhotoHandle) async throws {
    try await cleanup(photo.sessionID)
  }

  private func cleanup(_ sessionID: UUID) async throws {
    do { try await sessionCleaner.removeSession(sessionID) }
    catch { throw Failure.cleanupFailed }
  }
}

extension AvatarPhotoTemporarySessionStore: AvatarPhotoSessionCleaning {}
