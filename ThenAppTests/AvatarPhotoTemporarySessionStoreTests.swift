import Foundation
import Synchronization
import Testing

@testable import ThenApp

@Suite("照片 POC 临时会话")
struct AvatarPhotoTemporarySessionStoreTests {
  private typealias Store = AvatarPhotoTemporarySessionStore
  private let manager = FileManager.default

  private func withContainer(_ body: (URL) async throws -> Void) async throws {
    let container = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: container, withIntermediateDirectories: false)
    defer {
      do { try manager.removeItem(at: container) }
      catch { Issue.record("Test container cleanup failed") }
    }
    try await body(container)
  }

  @Test("文件先保留在随机会话，单文件与会话清理均可重复")
  func lifecycle() async throws {
    try await withContainer { container in
      let store = try Store(container: container)
      let session = try await store.createSession()
      let original = try await store.createFile(in: session, purpose: .originalImport)
      let preview = try await store.createFile(in: session, purpose: .sanitizedPreview)
      let originalURL = try await store.fileURL(for: original)
      let previewURL = try await store.fileURL(for: preview)
      #expect(original.fileID != preview.fileID)
      #expect(originalURL.deletingLastPathComponent().lastPathComponent == session.uuidString)
      #expect(try originalURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
      #expect(try originalURL.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true)
      try Data([1, 2, 3]).write(to: originalURL)
      try await store.removeFile(original)
      try await store.removeFile(original)
      #expect(!manager.fileExists(atPath: originalURL.path))
      #expect(manager.fileExists(atPath: previewURL.path))
      try await store.removeSession(session)
      try await store.removeSession(session)
      #expect(!manager.fileExists(atPath: previewURL.path))
      #expect(try manager.contentsOfDirectory(atPath: container.appendingPathComponent(Store.directoryName).path).isEmpty)
    }
  }

  @Test("未知引用不可读，重复或未知清理不会扩大范围")
  func unknownReferences() async throws {
    try await withContainer { container in
      let store = try Store(container: container)
      let session = try await store.createSession()
      let foreign = Store.FileReference(sessionID: session, fileID: UUID(), purpose: .originalImport)
      await #expect(throws: Store.Failure.unknownFile) { try await store.fileURL(for: foreign) }
      await #expect(throws: Store.Failure.unknownSession) {
        try await store.createFile(in: UUID(), purpose: .originalImport)
      }
      try await store.removeFile(foreign)
      try await store.removeSession(UUID())
      let file = try await store.createFile(in: session, purpose: .originalImport)
      #expect(manager.fileExists(atPath: try await store.fileURL(for: file).path))
      try await store.removeSession(session)
    }
  }

  @Test("启动清扫只清理专用根，活跃会话不能被启动清扫删除")
  func startupRecovery() async throws {
    try await withContainer { container in
      let first = try Store(container: container)
      let session = try await first.createSession()
      let file = try await first.createFile(in: session, purpose: .originalImport)
      let url = try await first.fileURL(for: file)
      await #expect(throws: Store.Failure.sessionsInUse) { try await first.prepareForUse() }
      #expect(manager.fileExists(atPath: url.path))
      let neighbor = container.appendingPathComponent(Store.directoryName + "-unrelated")
      try manager.createDirectory(at: neighbor, withIntermediateDirectories: false)
      let sentinel = neighbor.appendingPathComponent("sentinel")
      try Data([9]).write(to: sentinel)
      // A new owner models a process restart; the first owner is never used again.
      let restarted = try Store(container: container)
      try await restarted.prepareForUse()
      #expect(!manager.fileExists(atPath: url.path))
      #expect(try Data(contentsOf: sentinel) == Data([9]))
      try await restarted.prepareForUse()
    }
  }

  @Test("根目录链接不能指向相邻文件夹")
  func rootSymlink() async throws {
    try await withContainer { container in
      let outside = container.appendingPathComponent("outside")
      try manager.createDirectory(at: outside, withIntermediateDirectories: false)
      let sentinel = outside.appendingPathComponent("sentinel")
      try Data([7]).write(to: sentinel)
      try manager.createSymbolicLink(at: container.appendingPathComponent(Store.directoryName), withDestinationURL: outside)
      let store = try Store(container: container)
      await #expect(throws: Store.Failure.unsafePath) { try await store.createSession() }
      #expect(try Data(contentsOf: sentinel) == Data([7]))
    }
  }

  @Test("会话目录被链接替换后，不读取或删除目标")
  func sessionSymlink() async throws {
    try await withContainer { container in
      let store = try Store(container: container)
      let session = try await store.createSession()
      let directory = container.appendingPathComponent(Store.directoryName).appendingPathComponent(session.uuidString)
      try manager.removeItem(at: directory)
      let outside = container.appendingPathComponent("outside")
      try manager.createDirectory(at: outside, withIntermediateDirectories: false)
      let sentinel = outside.appendingPathComponent("sentinel")
      try Data([7]).write(to: sentinel)
      try manager.createSymbolicLink(at: directory, withDestinationURL: outside)
      await #expect(throws: Store.Failure.unsafePath) { try await store.removeSession(session) }
      await #expect(throws: Store.Failure.cleanupFailed) {
        try await store.createFile(in: session, purpose: .originalImport)
      }
      #expect(try Data(contentsOf: sentinel) == Data([7]))
    }
  }

  @Test("暂存文件的符号链接或硬链接不能获得可写 URL", arguments: [false, true])
  func fileLink(hardLink: Bool) async throws {
    try await withContainer { container in
      let store = try Store(container: container)
      let session = try await store.createSession()
      let file = try await store.createFile(in: session, purpose: .originalImport)
      let url = try await store.fileURL(for: file)
      try manager.removeItem(at: url)
      let outside = container.appendingPathComponent("sentinel")
      try Data([7]).write(to: outside)
      if hardLink { try manager.linkItem(at: outside, to: url) }
      else { try manager.createSymbolicLink(at: url, withDestinationURL: outside) }
      await #expect(throws: Store.Failure.unsafePath) { try await store.fileURL(for: file) }
      await #expect(throws: Store.Failure.unsafePath) { try await store.removeFile(file) }
      try await store.removeSession(session)
      #expect(try Data(contentsOf: outside) == Data([7]))
    }
  }

  @Test("低存储或属性失败后的部分目录和文件被清理", arguments: [false, true])
  func partialCreation(fileFailure: Bool) async throws {
    try await withContainer { container in
      let fs = FaultFileSystem()
      let store = try Store(container: container, fileSystem: fs)
      try await store.prepareForUse()
      if fileFailure {
        let session = try await store.createSession()
        fs.arm(.fileAfterCreation)
        await #expect(throws: Store.Failure.storageUnavailable) {
          try await store.createFile(in: session, purpose: .originalImport)
        }
      } else {
        fs.arm(.directoryAfterCreation)
        await #expect(throws: Store.Failure.storageUnavailable) { try await store.createSession() }
      }
      #expect(try manager.contentsOfDirectory(atPath: container.appendingPathComponent(Store.directoryName).path).isEmpty)
      let retry = try await store.createSession()
      try await store.removeSession(retry)
    }
  }

  @Test("删除失败保持可重试状态，清理前不能再创建会话")
  func removalFailure() async throws {
    try await withContainer { container in
      let fs = FaultFileSystem()
      let store = try Store(container: container, fileSystem: fs)
      let session = try await store.createSession()
      let file = try await store.createFile(in: session, purpose: .originalImport)
      let url = try await store.fileURL(for: file)
      fs.arm(.remove)
      await #expect(throws: Store.Failure.cleanupFailed) { try await store.removeSession(session) }
      #expect(manager.fileExists(atPath: url.path))
      await #expect(throws: Store.Failure.cleanupFailed) { try await store.fileURL(for: file) }
      await #expect(throws: Store.Failure.cleanupFailed) {
        try await store.createFile(in: session, purpose: .sanitizedPreview)
      }
      await #expect(throws: Store.Failure.sessionsInUse) { try await store.createSession() }
      try await store.removeSession(session)
      #expect(!manager.fileExists(atPath: url.path))
      let next = try await store.createSession()
      try await store.removeSession(next)
    }
  }

  @Test("创建与后续清理同时失败时，保留原会话用于重试清理")
  func failedCreationAndCleanup() async throws {
    try await withContainer { container in
      let fs = FaultFileSystem()
      let store = try Store(container: container, fileSystem: fs)
      let session = try await store.createSession()
      fs.arm(.fileAfterCreation)
      fs.arm(.remove)
      await #expect(throws: Store.Failure.cleanupFailed) {
        try await store.createFile(in: session, purpose: .originalImport)
      }
      let directory = container.appendingPathComponent(Store.directoryName).appendingPathComponent(session.uuidString)
      #expect(try manager.contentsOfDirectory(atPath: directory.path).count == 1)
      await #expect(throws: Store.Failure.sessionsInUse) { try await store.createSession() }
      try await store.removeSession(session)
      #expect(!manager.fileExists(atPath: directory.path))
    }
  }

  @Test("启动清理和保护失败不启动会话，恢复后重新请求保护")
  func preparationFailure() async throws {
    try await withContainer { container in
      let fs = FaultFileSystem()
      let store = try Store(container: container, fileSystem: fs)
      fs.arm(.directoryAfterCreation)
      await #expect(throws: Store.Failure.cleanupFailed) { try await store.createSession() }
      fs.arm(.protect)
      await #expect(throws: Store.Failure.cleanupFailed) { try await store.createSession() }
      let session = try await store.createSession()
      try await store.removeSession(session)
    }
  }

  @Test("写入后保护失败会清理会话；清理失败继续禁止访问", arguments: [false, true])
  func finishWritingFailure(cleanupFails: Bool) async throws {
    try await withContainer { container in
      let fs = FaultFileSystem()
      let store = try Store(container: container, fileSystem: fs)
      let session = try await store.createSession()
      let file = try await store.createFile(in: session, purpose: .sanitizedPreview)
      let url = try await store.fileURL(for: file)
      fs.arm(.protect)
      if cleanupFails { fs.arm(.remove) }
      let expected: Store.Failure = cleanupFails ? .cleanupFailed : .storageUnavailable
      await #expect(throws: expected) { try await store.finishWriting(file) }
      if cleanupFails {
        await #expect(throws: Store.Failure.cleanupFailed) { try await store.fileURL(for: file) }
        try await store.removeSession(session)
      }
      #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
  }

  @Test("底层文件错误不能泄露路径")
  func sanitizedErrors() async throws {
    try await withContainer { container in
      let fs = FaultFileSystem()
      let store = try Store(container: container, fileSystem: fs)
      fs.arm(.kind)
      await #expect(throws: Store.Failure.storageUnavailable) { try await store.createSession() }
    }
  }
}

nonisolated private final class FaultFileSystem: AvatarPhotoSessionFileSystem {
  enum Fault: Sendable { case directoryAfterCreation, fileAfterCreation, remove, protect, kind }
  private let pending = Mutex<[Fault]>([])
  private let real = FoundationAvatarPhotoSessionFileSystem()

  func arm(_ fault: Fault) { pending.withLock { $0.append(fault) } }
  private func failIfArmed(_ candidate: Fault) throws {
    let fail = pending.withLock { value in
      guard value.first == candidate else { return false }
      value.removeFirst()
      return true
    }
    if fail {
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
        userInfo: [NSFilePathErrorKey: "synthetic-sensitive-file-name"])
    }
  }
  func kind(at url: URL) throws -> AvatarPhotoSessionEntryKind {
    try failIfArmed(.kind)
    return try real.kind(at: url)
  }
  func createProtectedDirectory(at url: URL) throws {
    try real.createProtectedDirectory(at: url)
    try failIfArmed(.directoryAfterCreation)
  }
  func applyProtection(at url: URL) throws {
    try failIfArmed(.protect)
    try real.applyProtection(at: url)
  }
  func createProtectedFile(at url: URL) throws {
    try real.createProtectedFile(at: url)
    try failIfArmed(.fileAfterCreation)
  }
  func children(at url: URL) throws -> [URL] { try real.children(at: url) }
  func remove(at url: URL) throws {
    try failIfArmed(.remove)
    try real.remove(at: url)
  }
}
