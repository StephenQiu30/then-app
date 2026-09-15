import Foundation
import Observation

@MainActor @Observable
final class AvatarPhotoIntakeViewModel {
  typealias ImportPhoto = @Sendable () async throws -> AvatarPhotoInputHandle

  @ObservationIgnored private let useCase: any AvatarPhotoPreparing
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  private(set) var state: AvatarPhotoIntakeState = .disclosure

  init(useCase: any AvatarPhotoPreparing) {
    self.useCase = useCase
  }

  var isProcessing: Bool {
    switch state {
    case .importing, .sanitizing, .analyzing: true
    default: false
    }
  }

  func continueToPhotoSelection() {
    guard state == .disclosure else { return }
    state = .awaitingSelection
  }

  func prepare(importing importPhoto: @escaping ImportPhoto) {
    switch state {
    case .disclosure, .templateFallback:
      return
    default:
      break
    }
    let retainedPhoto = reviewPhoto
    let previous = supersede()
    let token = generation
    state = .importing
    operation = Task { [weak self, useCase] in
      _ = await previous?.result
      guard !Task.isCancelled else { return }
      do {
        if let retainedPhoto { try await useCase.discard(retainedPhoto) }
        try Task.checkCancellation()
        let result = try await useCase.execute(importing: importPhoto) { [weak self] stage in
          await self?.receive(stage, token: token)
        }
        guard !Task.isCancelled, let self, self.generation == token else {
          if case .review(let photo, _) = result { try await useCase.discard(photo) }
          return
        }
        apply(result)
        operation = nil
      } catch is CancellationError {
        if let self, self.generation == token { self.operation = nil }
      } catch {
        guard let self, self.generation == token else { return }
        self.state = .recoverableFailure(.analysisFailed)
        self.operation = nil
      }
    }
  }

  func cancelProcessing() {
    guard isProcessing else { return }
    transitionAndClean(to: .awaitingSelection)
  }

  func useTemplate() {
    transitionAndClean(to: .templateFallback)
  }

  func returnToDisclosure() {
    transitionAndClean(to: .disclosure)
  }

  func sceneBecameInactive() {
    transitionAndClean(to: .disclosure)
  }

  private var reviewPhoto: SanitizedAvatarPhotoHandle? {
    if case .review(let photo, _) = state { photo } else { nil }
  }

  private func supersede() -> Task<Void, Never>? {
    let previous = operation
    previous?.cancel()
    generation = UUID()
    operation = nil
    return previous
  }

  private func transitionAndClean(to next: AvatarPhotoIntakeState) {
    let retainedPhoto = reviewPhoto
    let previous = supersede()
    let token = generation
    state = next
    guard previous != nil || retainedPhoto != nil else { return }
    operation = Task { [weak self, useCase] in
      _ = await previous?.result
      do {
        if let retainedPhoto { try await useCase.discard(retainedPhoto) }
        if let self, self.generation == token { self.operation = nil }
      } catch {
        guard let self, self.generation == token else { return }
        self.state = .recoverableFailure(.analysisFailed)
        self.operation = nil
      }
    }
  }

  private func receive(_ stage: AvatarPhotoPreparationStage, token: UUID) {
    guard generation == token else { return }
    state = switch stage {
    case .importing: .importing
    case .sanitizing: .sanitizing
    case .analyzing: .analyzing
    }
  }

  private func apply(_ result: AvatarPhotoPreparationResult) {
    state = switch result {
    case .review(let photo, let assessment): .review(photo, assessment)
    case .replacement(let assessment): .replacement(assessment)
    case .unsupported(let assessment): .unsupported(assessment)
    }
  }
}
