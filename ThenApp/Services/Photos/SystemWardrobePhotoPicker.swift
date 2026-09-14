import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// Receives one explicit selection; only prepared pixels cross into the review use case.
nonisolated struct SystemWardrobePhotoPicker: Sendable {
  nonisolated enum Failure: Error {
    case unsupportedFormat, sourceUnavailable, invalidTransferContext, timedOut
    case unsafeOrCorruptInput, resourceLimitExceeded
  }

  private let limits: ImageIOWardrobePhotoPreparer.Limits
  private let transferTimeout: Duration

  init(limits: ImageIOWardrobePhotoPreparer.Limits, transferTimeout: Duration) throws {
    guard transferTimeout > .zero else { throw Failure.resourceLimitExceeded }
    self.limits = limits
    self.transferTimeout = transferTimeout
  }

  func load(_ item: PhotosPickerItem) async throws -> WardrobePreparedPhoto {
    try await load(using: SystemWardrobeItemLoader(item: item))
  }

  func load(using loader: any WardrobePhotoTransferLoading) async throws -> WardrobePreparedPhoto {
    try Task.checkCancellation()
    guard loader.contentTypes.contains(where: { WardrobePhotoSourceFormat(rawValue: $0.identifier) != nil }) else {
      throw Failure.unsupportedFormat
    }
    let operation = WardrobePhotoTransferOperation(limits: limits)
    return try await withTaskCancellationHandler {
      do {
        return try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
          group.addTask {
            guard let token = try await operation.receive(from: loader) else { throw Failure.sourceUnavailable }
            return try await operation.handOff(token)
          }
          group.addTask {
            try await Task.sleep(for: transferTimeout)
            throw Failure.timedOut
          }
          do {
            guard let result = try await group.next() else { throw Failure.sourceUnavailable }
            group.cancelAll()
            return result
          } catch {
            // Resume the provider continuation before the task group waits for its child.
            operation.cancel()
            group.cancelAll()
            throw error
          }
        }
      } catch {
        operation.cancel()
        let preparationError = await operation.discard()
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        if let failure = error as? Failure, failure == .timedOut { throw failure }
        throw Self.map(preparationError ?? error)
      }
    } onCancel: { operation.cancel() }
  }

  private static func map(_ error: any Error) -> Failure {
    if let error = error as? Failure { return error }
    if let error = error as? WardrobePhotoFileImporter.Failure {
      return switch error {
      case .sourceUnavailable: .sourceUnavailable
      case .unsafeInput: .unsafeOrCorruptInput
      case .resourceLimitExceeded: .resourceLimitExceeded
      }
    }
    if let error = error as? ImageIOWardrobePhotoPreparer.Failure {
      return switch error {
      case .resourceLimitExceeded: .resourceLimitExceeded
      default: .unsafeOrCorruptInput
      }
    }
    return .sourceUnavailable
  }
}

nonisolated protocol WardrobePhotoTransferLoading: Sendable {
  var contentTypes: [UTType] { get }
  func start(operation: WardrobePhotoTransferOperation,
             completion: @escaping @Sendable (Result<WardrobePhotoTransferredFile?, any Error>) -> Void) -> Progress
}

nonisolated private struct SystemWardrobeItemLoader: WardrobePhotoTransferLoading {
  let item: PhotosPickerItem
  var contentTypes: [UTType] { item.supportedContentTypes }
  func start(operation: WardrobePhotoTransferOperation,
             completion: @escaping @Sendable (Result<WardrobePhotoTransferredFile?, any Error>) -> Void) -> Progress {
    WardrobePhotoTransferScope.$current.withValue(operation) {
      item.loadTransferable(type: WardrobePhotoTransferredFile.self, completionHandler: completion)
    }
  }
}

// Captured when the representation is constructed, never looked up from a late callback.
nonisolated enum WardrobePhotoTransferScope {
  @TaskLocal static var current: WardrobePhotoTransferOperation?
}

nonisolated struct WardrobePhotoTransferredFile: Transferable, Sendable {
  let operationID: UUID

  static var transferRepresentation: some TransferRepresentation {
    let operation = WardrobePhotoTransferScope.current
    FileRepresentation(importedContentType: .heic) { received in
      try await receive(received, format: .heic, operation: operation)
    }
    FileRepresentation(importedContentType: .jpeg) { received in
      try await receive(received, format: .jpeg, operation: operation)
    }
    FileRepresentation(importedContentType: .png) { received in
      try await receive(received, format: .png, operation: operation)
    }
  }

  private static func receive(_ received: ReceivedTransferredFile, format: WardrobePhotoSourceFormat,
                              operation: WardrobePhotoTransferOperation?) async throws -> Self {
    guard let operation else { throw SystemWardrobePhotoPicker.Failure.invalidTransferContext }
    return try await operation.prepare(from: received.file, format: format)
  }
}

/// One operation owns one preparation task until it is delivered or cancelled and drained.
nonisolated final class WardrobePhotoTransferOperation: Sendable {
  let id = UUID()
  private let importer: WardrobePhotoFileImporter
  private let state = Mutex(State())
  nonisolated private enum Phase { case loading, cancelled, delivered }
  nonisolated private struct State {
    var phase = Phase.loading
    var finished = false
    var continuation: CheckedContinuation<WardrobePhotoTransferredFile?, any Error>?
    var progress: Progress?
    var preparation: Task<WardrobePreparedPhoto, any Error>?
  }

  init(limits: ImageIOWardrobePhotoPreparer.Limits) { importer = .init(limits: limits) }

  func receive(from loader: any WardrobePhotoTransferLoading) async throws -> WardrobePhotoTransferredFile? {
    try await withCheckedThrowingContinuation { continuation in
      let start = state.withLock { state in
        guard state.phase == .loading, state.continuation == nil, !state.finished else { return false }
        state.continuation = continuation
        return true
      }
      guard start else { continuation.resume(throwing: CancellationError()); return }
      let progress = loader.start(operation: self) { [self] in complete($0) }
      let cancel = state.withLock { state in
        // Synchronous completion may precede this return. Keep Progress until handoff/error
        // takes ownership, so a failed completion can still cancel provider work.
        guard state.phase == .loading else { return state.phase == .cancelled }
        state.progress = progress
        return false
      }
      if cancel { progress.cancel() }
    }
  }

  func prepare(from url: URL, format: WardrobePhotoSourceFormat) async throws -> WardrobePhotoTransferredFile {
    let task = try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
      guard !state.finished, state.preparation == nil else {
        throw SystemWardrobePhotoPicker.Failure.invalidTransferContext
      }
      let task = Task { [importer] in try await importer.prepare(fromFile: url, format: format) }
      state.preparation = task
      return task
    }
    _ = try await task.value
    try Task.checkCancellation()
    try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
    }
    return WardrobePhotoTransferredFile(operationID: id)
  }

  private func complete(_ result: Result<WardrobePhotoTransferredFile?, any Error>) {
    let continuation = state.withLock { state in
      guard !state.finished else { return Optional<CheckedContinuation<WardrobePhotoTransferredFile?, any Error>>.none }
      state.finished = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }

  func cancel() {
    let pending = state.withLock { state -> (CheckedContinuation<WardrobePhotoTransferredFile?, any Error>?, Progress?, Task<WardrobePreparedPhoto, any Error>?) in
      guard state.phase != .delivered else { return (nil, nil, nil) }
      state.phase = .cancelled
      state.finished = true
      let pending = (state.continuation, state.progress, state.preparation)
      state.continuation = nil
      state.progress = nil
      return pending
    }
    pending.2?.cancel()
    pending.1?.cancel()
    pending.0?.resume(throwing: CancellationError())
  }

  func handOff(_ token: WardrobePhotoTransferredFile) async throws -> WardrobePreparedPhoto {
    guard token.operationID == id else { throw SystemWardrobePhotoPicker.Failure.invalidTransferContext }
    let task = try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
      guard let task = state.preparation else { throw SystemWardrobePhotoPicker.Failure.invalidTransferContext }
      return task
    }
    let result = try await task.value
    try Task.checkCancellation()
    try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
      state.phase = .delivered
      state.progress = nil
      state.preparation = nil
    }
    return result
  }

  func discard() async -> (any Error)? {
    let task = state.withLock { $0.preparation }
    guard let task else { return nil }
    let result = await task.result
    state.withLock { $0.preparation = nil }
    if case .failure(let error) = result, !(error is CancellationError) { return error }
    return nil
  }
}
