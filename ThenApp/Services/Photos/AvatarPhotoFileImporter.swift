import Darwin
import Foundation

/// Used inside the system's file-representation callback, while its source URL is valid.
nonisolated struct AvatarPhotoFileImporter: Sendable {
  nonisolated enum Failure: Error {
    case declarationRequired, sourceUnavailable, unsupportedFormat, unsafeOrCorruptInput
    case resourceLimitExceeded, storageUnavailable, cleanupFailed
  }

  private let store: AvatarPhotoTemporarySessionStore
  private let validator: ImageIOAvatarPhotoSanitizer
  private let limits: ImageIOAvatarPhotoSanitizer.Limits

  init(store: AvatarPhotoTemporarySessionStore, limits: ImageIOAvatarPhotoSanitizer.Limits) {
    self.store = store
    self.validator = ImageIOAvatarPhotoSanitizer(store: store, limits: limits)
    self.limits = limits
  }

  @concurrent func importFile(
    at sourceURL: URL, format: AvatarPhotoInputFormat, confirmedAdultSelf: Bool
  ) async throws -> AvatarPhotoInputHandle {
    guard confirmedAdultSelf else { throw Failure.declarationRequired }
    try Task.checkCancellation()
    let deadline = ContinuousClock.now.advanced(by: limits.maximumDuration)
    var session: UUID?
    do {
      guard sourceURL.isFileURL else { throw Failure.unsafeOrCorruptInput }
      let sourceState = try inspectPath(sourceURL)
      try validator.validateInput(at: sourceURL, format: format)
      try check(deadline)
      let descriptor = sourceURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { throw Failure.sourceUnavailable }
      let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      // Explicit close on success; this defer also closes the descriptor on every failure.
      defer { try? source.close() }
      guard try inspectDescriptor(descriptor) == sourceState else { throw Failure.unsafeOrCorruptInput }

      let newSession = try await store.createSession()
      session = newSession
      let file = try await store.createFile(in: newSession, purpose: .originalImport)
      let destinationURL = try await store.fileURL(for: file)
      try copy(source, to: destinationURL, expectedBytes: sourceState.bytes, deadline: deadline)
      guard try inspectDescriptor(descriptor) == sourceState,
            try inspectPath(sourceURL) == sourceState else { throw Failure.unsafeOrCorruptInput }
      try source.close()
      try check(deadline)
      // Never publish a file based only on validation of the provider's earlier path.
      try validator.validateInput(at: destinationURL, format: format)
      try await store.finishWriting(file)
      try check(deadline)
      return AvatarPhotoInputHandle(sessionID: newSession, inputID: file.fileID, format: format)
    } catch {
      if let session {
        do { try await store.removeSession(session) }
        catch { throw Failure.cleanupFailed }
      }
      if error is CancellationError { throw CancellationError() }
      if let failure = error as? Failure { throw failure }
      if let failure = error as? ImageIOAvatarPhotoSanitizer.Failure {
        switch failure {
        case .unsupportedFormat: throw Failure.unsupportedFormat
        case .unsafeOrCorruptInput: throw Failure.unsafeOrCorruptInput
        case .resourceLimitExceeded: throw Failure.resourceLimitExceeded
        case .storageUnavailable: throw Failure.storageUnavailable
        case .cleanupFailed: throw Failure.cleanupFailed
        }
      }
      if let failure = error as? AvatarPhotoTemporarySessionStore.Failure, failure == .cleanupFailed {
        throw Failure.cleanupFailed
      }
      throw Failure.storageUnavailable
    }
  }

  private func copy(_ source: FileHandle, to destination: URL, expectedBytes: Int,
                    deadline: ContinuousClock.Instant) throws {
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var count = 0
    while true {
      try check(deadline)
      let bytes: Data
      do { bytes = try source.read(upToCount: 64 * 1024) ?? Data() }
      catch { throw Failure.sourceUnavailable }
      guard !bytes.isEmpty else { break }
      guard bytes.count <= limits.maximumInputBytes - count else { throw Failure.resourceLimitExceeded }
      try output.write(contentsOf: bytes)
      count += bytes.count
    }
    guard count == expectedBytes else { throw Failure.unsafeOrCorruptInput }
    try output.close()
  }

  nonisolated private struct SourceState: Equatable {
    let device: Int32
    let inode: UInt64
    let bytes: Int
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
  }

  private func inspectPath(_ url: URL) throws -> SourceState {
    var attributes = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &attributes)
    }
    guard result == 0 else { throw Failure.sourceUnavailable }
    return try inspect(attributes)
  }

  private func inspectDescriptor(_ descriptor: Int32) throws -> SourceState {
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0 else { throw Failure.sourceUnavailable }
    return try inspect(attributes)
  }

  private func inspect(_ attributes: stat) throws -> SourceState {
    guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1,
          attributes.st_size > 0 else { throw Failure.unsafeOrCorruptInput }
    guard attributes.st_size <= limits.maximumInputBytes else { throw Failure.resourceLimitExceeded }
    return SourceState(device: attributes.st_dev, inode: attributes.st_ino, bytes: Int(attributes.st_size),
      modifiedSeconds: attributes.st_mtimespec.tv_sec, modifiedNanos: attributes.st_mtimespec.tv_nsec,
      changedSeconds: attributes.st_ctimespec.tv_sec, changedNanos: attributes.st_ctimespec.tv_nsec)
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Failure.resourceLimitExceeded }
  }
}
