import Foundation

nonisolated enum AvatarPhotoSessionEntryKind: Sendable {
  case missing, directory, regularFile, unsafe
}

nonisolated protocol AvatarPhotoSessionFileSystem: Sendable {
  func kind(at url: URL) throws -> AvatarPhotoSessionEntryKind
  func createProtectedDirectory(at url: URL) throws
  func createProtectedFile(at url: URL) throws
  func applyProtection(at url: URL) throws
  func children(at url: URL) throws -> [URL]
  func remove(at url: URL) throws
}

nonisolated struct FoundationAvatarPhotoSessionFileSystem: AvatarPhotoSessionFileSystem {
  private var manager: FileManager { FileManager() }

  func kind(at url: URL) throws -> AvatarPhotoSessionEntryKind {
    let attributes: [FileAttributeKey: Any]
    do { attributes = try manager.attributesOfItem(atPath: url.path) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
      return .missing
    }
    switch attributes[.type] as? FileAttributeType {
    case .typeDirectory: return .directory
    case .typeRegular:
      // A linked file could let an imaging adapter overwrite bytes outside this session.
      return (attributes[.referenceCount] as? NSNumber)?.intValue == 1 ? .regularFile : .unsafe
    default: return .unsafe
    }
  }

  func createProtectedDirectory(at url: URL) throws {
    try manager.createDirectory(
      at: url, withIntermediateDirectories: false,
      attributes: [.protectionKey: FileProtectionType.complete]
    )
    try excludeFromBackup(url)
  }

  func applyProtection(at url: URL) throws {
    try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    try excludeFromBackup(url)
  }

  func createProtectedFile(at url: URL) throws {
    try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtection])
    try excludeFromBackup(url)
  }

  func children(at url: URL) throws -> [URL] {
    try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }

  func remove(at url: URL) throws { try manager.removeItem(at: url) }

  private func excludeFromBackup(_ url: URL) throws {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)
  }
}

/// One instance is owned by the POC host. Callers never supply a path to a deletion method.
actor AvatarPhotoTemporarySessionStore {
  nonisolated static let directoryName = "ThenAvatarPhotoIntakePOC"

  nonisolated enum Failure: Error {
    case unsafePath, unknownSession, unknownFile, sessionsInUse
    case storageUnavailable, cleanupFailed
  }

  nonisolated enum Purpose: String, Sendable {
    case originalImport = "original_import"
    case sanitizedPreview = "sanitized_preview"
  }

  /// A reserved, initially empty file; this is not a successfully sanitized photo.
  nonisolated struct FileReference: Sendable, Hashable {
    let sessionID: UUID
    let fileID: UUID
    let purpose: Purpose
  }

  private let container: URL
  private let root: URL
  private let fileSystem: any AvatarPhotoSessionFileSystem
  private var sessions: Set<UUID> = []
  private var files: Set<FileReference> = []
  private var prepared = false

  // Only the host/test composition supplies the trusted private container, never a View or input URL.
  init(
    container: URL = FileManager.default.temporaryDirectory,
    fileSystem: any AvatarPhotoSessionFileSystem = FoundationAvatarPhotoSessionFileSystem()
  ) throws {
    guard container.isFileURL else { throw Failure.unsafePath }
    self.container = container.standardizedFileURL.resolvingSymlinksInPath()
    root = self.container.appendingPathComponent(Self.directoryName, isDirectory: true)
    self.fileSystem = fileSystem
  }

  func prepareForUse() throws {
    guard sessions.isEmpty else { throw Failure.sessionsInUse }
    prepared = false
    do {
      try validateContainer()
      switch try entryKind(at: root) {
      case .missing: try fileSystem.createProtectedDirectory(at: root)
      case .directory:
        try validateDirectory(root)
        try fileSystem.applyProtection(at: root)
      default: throw Failure.unsafePath
      }
      for child in try fileSystem.children(at: root) {
        guard child.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
          throw Failure.unsafePath
        }
        try validateContainedPath(child)
        guard try entryKind(at: child) != .unsafe else { throw Failure.unsafePath }
        try fileSystem.remove(at: child)
      }
      prepared = true
    } catch let error as Failure { throw error }
    catch { throw Failure.cleanupFailed }
  }

  func createSession() throws -> UUID {
    if !prepared { try prepareForUse() }
    try validateDirectory(root)
    let id = UUID()
    let directory = sessionURL(id)
    guard try entryKind(at: directory) == .missing else { throw Failure.unsafePath }
    do { try fileSystem.createProtectedDirectory(at: directory) }
    catch {
      prepared = false
      do { try removeDirectoryIfPresent(directory) }
      catch { throw Failure.cleanupFailed }
      throw Failure.storageUnavailable
    }
    sessions.insert(id)
    return id
  }

  func createFile(in sessionID: UUID, purpose: Purpose) throws -> FileReference {
    guard prepared else { throw Failure.cleanupFailed }
    try validateSession(sessionID)
    let reference = FileReference(sessionID: sessionID, fileID: UUID(), purpose: purpose)
    let url = fileURLUnchecked(reference)
    guard try entryKind(at: url) == .missing else { throw Failure.unsafePath }
    do { try fileSystem.createProtectedFile(at: url) }
    catch {
      do { try removeSession(sessionID) }
      catch { throw Failure.cleanupFailed }
      throw Failure.storageUnavailable
    }
    files.insert(reference)
    return reference
  }

  /// Platform adapters use this transiently; domain state only receives opaque IDs.
  func fileURL(for reference: FileReference) throws -> URL {
    guard prepared else { throw Failure.cleanupFailed }
    try validateSession(reference.sessionID)
    guard files.contains(reference) else { throw Failure.unknownFile }
    let url = fileURLUnchecked(reference)
    try validateContainedPath(url)
    guard try entryKind(at: url) == .regularFile else { throw Failure.unsafePath }
    return url
  }

  func removeFile(_ reference: FileReference) throws {
    guard files.contains(reference) else { return }
    try validateSession(reference.sessionID)
    let url = fileURLUnchecked(reference)
    try validateContainedPath(url)
    do {
      switch try entryKind(at: url) {
      case .missing: break
      case .regularFile: try fileSystem.remove(at: url)
      default: throw Failure.unsafePath
      }
      files.remove(reference)
    } catch let error as Failure { throw error }
    catch { prepared = false; throw Failure.cleanupFailed }
  }

  /// Encoders can replace a reserved inode and its attributes. Reapply before publishing a handle.
  func finishWriting(_ reference: FileReference) throws {
    let url = try fileURL(for: reference)
    do { try fileSystem.applyProtection(at: url) }
    catch {
      do { try removeSession(reference.sessionID) }
      catch { throw Failure.cleanupFailed }
      throw Failure.storageUnavailable
    }
  }

  func removeSession(_ sessionID: UUID) throws {
    guard sessions.contains(sessionID) else { return }
    do {
      try removeDirectoryIfPresent(sessionURL(sessionID))
      sessions.remove(sessionID)
      files = files.filter { $0.sessionID != sessionID }
    } catch let error as Failure { prepared = false; throw error }
    catch { prepared = false; throw Failure.cleanupFailed }
  }

  private func validateSession(_ id: UUID) throws {
    guard sessions.contains(id) else { throw Failure.unknownSession }
    try validateDirectory(root)
    try validateDirectory(sessionURL(id))
  }

  private func entryKind(at url: URL) throws -> AvatarPhotoSessionEntryKind {
    do { return try fileSystem.kind(at: url) }
    catch { throw Failure.storageUnavailable }
  }

  private func validateContainer() throws {
    guard container.resolvingSymlinksInPath() == container,
          try entryKind(at: container) == .directory else { throw Failure.unsafePath }
  }

  private func validateContainedPath(_ url: URL) throws {
    try validateContainer()
    let normalized = url.standardizedFileURL
    let rootComponents = root.standardizedFileURL.pathComponents
    guard normalized.pathComponents.count >= rootComponents.count,
          Array(normalized.pathComponents.prefix(rootComponents.count)) == rootComponents,
          normalized.resolvingSymlinksInPath() == normalized else { throw Failure.unsafePath }
  }

  private func validateDirectory(_ url: URL) throws {
    try validateContainedPath(url)
    guard try entryKind(at: url) == .directory else { throw Failure.unsafePath }
  }

  private func removeDirectoryIfPresent(_ url: URL) throws {
    try validateDirectory(root)
    try validateContainedPath(url)
    switch try entryKind(at: url) {
    case .missing: return
    case .directory: try fileSystem.remove(at: url)
    default: throw Failure.unsafePath
    }
  }

  private func sessionURL(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private func fileURLUnchecked(_ reference: FileReference) -> URL {
    sessionURL(reference.sessionID).appendingPathComponent("\(reference.purpose.rawValue)-\(reference.fileID.uuidString)")
  }
}
