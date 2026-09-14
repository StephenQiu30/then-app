import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

/// The SwiftUI picker owns presentation/selection; this adapter owns one selected item's transfer.
nonisolated struct SystemAvatarPhotoPicker: Sendable {
  nonisolated enum Failure: Error {
    case declarationRequired, sourceUnavailable, invalidTransferContext
    case unsupportedFormat, unsafeOrCorruptInput, resourceLimitExceeded, storageUnavailable, cleanupFailed
  }

  private let store: AvatarPhotoTemporarySessionStore
  private let limits: ImageIOAvatarPhotoSanitizer.Limits

  init(store: AvatarPhotoTemporarySessionStore, limits: ImageIOAvatarPhotoSanitizer.Limits) {
    self.store = store
    self.limits = limits
  }

  func load(_ item: PhotosPickerItem, confirmedAdultSelf: Bool) async throws -> AvatarPhotoInputHandle {
    try await load(using: SystemPhotoItemLoader(item: item), confirmedAdultSelf: confirmedAdultSelf)
  }

  func load(using loader: any AvatarPhotoTransferLoading,
            confirmedAdultSelf: Bool) async throws -> AvatarPhotoInputHandle {
    guard confirmedAdultSelf else { throw Failure.declarationRequired }
    try Task.checkCancellation()
    guard loader.contentTypes.contains(where: { AvatarPhotoInputFormat(rawValue: $0.identifier) != nil }) else {
      throw Failure.unsupportedFormat
    }
    let operation = AvatarPhotoTransferOperation(store: store, limits: limits)
    do {
      return try await withTaskCancellationHandler {
        guard let result = try await operation.receive(from: loader) else { throw Failure.sourceUnavailable }
        return try await operation.handOff(result)
      } onCancel: {
        operation.cancel()
      }
    } catch {
      operation.cancel()
      let copyError = try await operation.discard()
      if error is CancellationError { throw CancellationError() }
      throw Self.map(copyError ?? error)
    }
  }

  private static func map(_ error: any Error) -> Failure {
    if let failure = error as? Failure { return failure }
    guard let failure = error as? AvatarPhotoFileImporter.Failure else { return .sourceUnavailable }
    switch failure {
    case .declarationRequired: return .declarationRequired
    case .sourceUnavailable: return .sourceUnavailable
    case .unsupportedFormat: return .unsupportedFormat
    case .unsafeOrCorruptInput: return .unsafeOrCorruptInput
    case .resourceLimitExceeded: return .resourceLimitExceeded
    case .storageUnavailable: return .storageUnavailable
    case .cleanupFailed: return .cleanupFailed
    }
  }
}

nonisolated protocol AvatarPhotoTransferLoading: Sendable {
  var contentTypes: [UTType] { get }
  func start(operation: AvatarPhotoTransferOperation,
             completion: @escaping @Sendable (Result<AvatarPhotoTransferredFile?, any Error>) -> Void) -> Progress
}

nonisolated private struct SystemPhotoItemLoader: AvatarPhotoTransferLoading {
  let item: PhotosPickerItem
  var contentTypes: [UTType] { item.supportedContentTypes }

  func start(operation: AvatarPhotoTransferOperation,
             completion: @escaping @Sendable (Result<AvatarPhotoTransferredFile?, any Error>) -> Void) -> Progress {
    AvatarPhotoTransferScope.$current.withValue(operation) {
      item.loadTransferable(type: AvatarPhotoTransferredFile.self, completionHandler: completion)
    }
  }
}

// A factory binding scoped to start(), not a process-wide store or callback-time lookup.
nonisolated private enum AvatarPhotoTransferScope {
  @TaskLocal static var current: AvatarPhotoTransferOperation?
}

nonisolated struct AvatarPhotoTransferredFile: Transferable, Sendable {
  let operationID: UUID
  let input: AvatarPhotoInputHandle

  static var transferRepresentation: some TransferRepresentation {
    let operation = AvatarPhotoTransferScope.current
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

  private static func receive(_ received: ReceivedTransferredFile, format: AvatarPhotoInputFormat,
                              operation: AvatarPhotoTransferOperation?) async throws -> Self {
    guard let operation else { throw SystemAvatarPhotoPicker.Failure.invalidTransferContext }
    let input = try await operation.copy(from: received.file, format: format)
    return Self(operationID: operation.id, input: input)
  }
}

/// Owns the continuation, provider progress and at most one copy task until delivery or cleanup.
nonisolated final class AvatarPhotoTransferOperation: Sendable {
  let id = UUID()
  private let store: AvatarPhotoTemporarySessionStore
  private let importer: AvatarPhotoFileImporter
  private let state = Mutex(State())

  nonisolated private enum Phase { case loading, cancelled, delivered }
  nonisolated private struct State {
    var phase = Phase.loading
    var transferFinished = false
    var continuation: CheckedContinuation<AvatarPhotoTransferredFile?, any Error>?
    var progress: Progress?
    var copyTask: Task<AvatarPhotoInputHandle, any Error>?
  }

  init(store: AvatarPhotoTemporarySessionStore, limits: ImageIOAvatarPhotoSanitizer.Limits) {
    self.store = store
    importer = AvatarPhotoFileImporter(store: store, limits: limits)
  }

  func receive(from loader: any AvatarPhotoTransferLoading) async throws -> AvatarPhotoTransferredFile? {
    try await withCheckedThrowingContinuation { continuation in
      let start = state.withLock { state in
        guard state.phase == .loading else { return false }
        state.continuation = continuation
        return true
      }
      guard start else { continuation.resume(throwing: CancellationError()); return }
      let progress = loader.start(operation: self) { [self] result in complete(result) }
      let cancel = state.withLock { state in
        if state.phase == .cancelled { return true }
        // A synchronous callback may complete before start returns its Progress.
        // Keep it until handoff/error so cancellation still reaches the provider.
        if state.phase == .loading { state.progress = progress }
        return false
      }
      // Never invoke provider callbacks while holding our state lock.
      if cancel { progress.cancel() }
    }
  }

  func copy(from url: URL, format: AvatarPhotoInputFormat) async throws -> AvatarPhotoInputHandle {
    let task = try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
      guard !state.transferFinished else { throw SystemAvatarPhotoPicker.Failure.invalidTransferContext }
      guard state.copyTask == nil else { throw SystemAvatarPhotoPicker.Failure.invalidTransferContext }
      let task = Task { [importer] in
        try await importer.importFile(at: url, format: format, confirmedAdultSelf: true)
      }
      state.copyTask = task
      return task
    }
    // Keeps the system URL inside the file-representation callback's lifetime.
    return try await task.value
  }

  private func complete(_ result: Result<AvatarPhotoTransferredFile?, any Error>) {
    let continuation = state.withLock { state in
      guard !state.transferFinished else { return Optional<CheckedContinuation<AvatarPhotoTransferredFile?, any Error>>.none }
      state.transferFinished = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }

  func cancel() {
    let pending = state.withLock { state -> (CheckedContinuation<AvatarPhotoTransferredFile?, any Error>?, Progress?, Task<AvatarPhotoInputHandle, any Error>?) in
      guard state.phase != .delivered else { return (nil, nil, nil) }
      state.phase = .cancelled
      state.transferFinished = true
      let pending = (state.continuation, state.progress, state.copyTask)
      state.continuation = nil
      state.progress = nil
      return pending
    }
    pending.2?.cancel()
    pending.1?.cancel()
    pending.0?.resume(throwing: CancellationError())
  }

  func handOff(_ result: AvatarPhotoTransferredFile) async throws -> AvatarPhotoInputHandle {
    guard result.operationID == id else { throw SystemAvatarPhotoPicker.Failure.invalidTransferContext }
    let task = try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
      guard let task = state.copyTask else { throw SystemAvatarPhotoPicker.Failure.invalidTransferContext }
      return task
    }
    let ownedInput = try await task.value
    guard ownedInput == result.input else { throw SystemAvatarPhotoPicker.Failure.invalidTransferContext }
    try Task.checkCancellation()
    try state.withLock { state in
      guard state.phase == .loading else { throw CancellationError() }
      // Ownership changes at this point. A later cancellation cannot delete the caller's result.
      state.phase = .delivered
      state.progress = nil
      state.copyTask = nil
    }
    return ownedInput
  }

  func discard() async throws -> (any Error)? {
    let task = state.withLock { $0.copyTask }
    guard let task else { return nil }
    switch await task.result {
    case .success(let input):
      do { try await store.removeSession(input.sessionID) }
      catch { throw SystemAvatarPhotoPicker.Failure.cleanupFailed }
      return nil
    case .failure(let error):
      if let failure = error as? AvatarPhotoFileImporter.Failure, failure == .cleanupFailed {
        throw SystemAvatarPhotoPicker.Failure.cleanupFailed
      }
      return error
    }
  }
}
