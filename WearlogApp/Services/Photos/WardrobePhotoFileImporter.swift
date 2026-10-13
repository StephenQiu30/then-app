import Darwin
import Foundation

/// Runs inside the provider file callback. Owns a descriptor and bounded memory, never the source file.
nonisolated struct WardrobePhotoFileImporter: Sendable {
  enum Failure: Error { case sourceUnavailable, unsafeInput, resourceLimitExceeded }
  let limits: ImageIOWardrobePhotoPreparer.Limits

  @concurrent func prepare(fromFile url: URL, format: WardrobePhotoSourceFormat) async throws -> WardrobePreparedPhoto {
    try Task.checkCancellation()
    let deadline = ContinuousClock.now.advanced(by: limits.duration)
    let bytes = try read(url, deadline: deadline)
    try check(deadline)
    let result = try await ImageIOWardrobePhotoPreparer(limits: limits).prepare(bytes, format: format)
    try check(deadline)
    return result
  }

  private func read(_ url: URL, deadline: ContinuousClock.Instant) throws -> Data {
    guard url.isFileURL else { throw Failure.unsafeInput }
    let before = try inspectPath(url)
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw Failure.sourceUnavailable }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    guard try inspectDescriptor(descriptor) == before else { throw Failure.unsafeInput }
    var bytes = Data()
    while true {
      try check(deadline)
      let block: Data
      do { block = try file.read(upToCount: min(64 * 1024, max(1, limits.inputBytes - bytes.count))) ?? Data() }
      catch { throw Failure.sourceUnavailable }
      guard !block.isEmpty else { break }
      guard block.count <= limits.inputBytes - bytes.count else { throw Failure.resourceLimitExceeded }
      bytes.append(block)
    }
    guard bytes.count == before.bytes, try inspectDescriptor(descriptor) == before,
          try inspectPath(url) == before else { throw Failure.unsafeInput }
    do { try file.close() } catch { throw Failure.sourceUnavailable }
    return bytes
  }

  private struct Identity: Equatable {
    let device: Int32
    let inode: UInt64
    let bytes: Int
    let mtimeSeconds: Int
    let mtimeNanos: Int
    let ctimeSeconds: Int
    let ctimeNanos: Int
  }

  private func inspectPath(_ url: URL) throws -> Identity {
    var value = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &value)
    }
    guard status == 0 else { throw Failure.sourceUnavailable }
    return try inspect(value)
  }

  private func inspectDescriptor(_ descriptor: Int32) throws -> Identity {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw Failure.sourceUnavailable }
    return try inspect(value)
  }

  private func inspect(_ value: stat) throws -> Identity {
    guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1, value.st_size > 0 else {
      throw Failure.unsafeInput
    }
    guard value.st_size <= limits.inputBytes else { throw Failure.resourceLimitExceeded }
    return Identity(device: value.st_dev, inode: value.st_ino, bytes: Int(value.st_size),
      mtimeSeconds: value.st_mtimespec.tv_sec, mtimeNanos: value.st_mtimespec.tv_nsec,
      ctimeSeconds: value.st_ctimespec.tv_sec, ctimeNanos: value.st_ctimespec.tv_nsec)
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Failure.resourceLimitExceeded }
  }
}
