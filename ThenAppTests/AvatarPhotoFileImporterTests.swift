import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ThenApp

@Suite("照片 POC 受控文件导入")
struct AvatarPhotoFileImporterTests {
  private typealias Importer = AvatarPhotoFileImporter
  private typealias Store = AvatarPhotoTemporarySessionStore

  private func limits(bytes: Int = 1_000_000, pixels: Int = 4096) throws -> ImageIOAvatarPhotoSanitizer.Limits {
    try .init(maximumInputBytes: bytes, maximumSourcePixels: pixels,
      maximumOutputDimension: 32, maximumRasterBytes: 4096,
      maximumOutputBytes: 100_000, maximumDuration: .seconds(5))
  }

  private func fixture(_ name: String) throws -> Data {
    let root: URL
    if let path = ProcessInfo.processInfo.environment["THEN_AVATAR_FIXTURE_DIRECTORY"] {
      root = URL(fileURLWithPath: path)
    } else {
      root = try #require(Bundle(for: FixtureBundle.self).url(forResource: "AvatarPhotoIntake", withExtension: nil))
    }
    return try Data(contentsOf: root.appendingPathComponent(name + ".fixture"))
  }

  private func withFiles(
    _ name: String = "metadata-png", body: (URL, URL, Data) async throws -> Void
  ) async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      do { try manager.removeItem(at: root) }
      catch { Issue.record("Synthetic import test cleanup failed") }
    }
    let container = root.appendingPathComponent("private", isDirectory: true)
    try manager.createDirectory(at: container, withIntermediateDirectories: false)
    let source = root.appendingPathComponent("SYNTHETIC-private-original-name")
    let bytes = try fixture(name)
    try bytes.write(to: source)
    try await body(container, source, bytes)
  }

  @Test("未确认声明与预先取消均不读取源文件或创建会话", arguments: [false, true])
  func noImportWithoutPermission(cancelled: Bool) async throws {
    try await withFiles { container, source, bytes in
      let importer = try Importer(store: Store(container: container), limits: limits())
      let missing = source.appendingPathComponent("not-a-file")
      if cancelled {
        await #expect(throws: CancellationError.self) {
          try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
            group.cancelAll()
            group.addTask { try await importer.importFile(at: missing, format: .png, confirmedAdultSelf: true) }
            _ = try await group.next()
          }
        }
      } else {
        await #expect(throws: Importer.Failure.declarationRequired) {
          try await importer.importFile(at: missing, format: .png, confirmedAdultSelf: false)
        }
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: container.path).isEmpty)
      #expect(try Data(contentsOf: source) == bytes)
    }
  }

  @Test("三种合法文件导入净化闭环且不更改系统源", arguments: [
    AvatarPhotoInputFormat.jpeg, .png, .heic,
  ])
  func importAndSanitize(format: AvatarPhotoInputFormat) async throws {
    let name = switch format { case .jpeg: "metadata-jpeg"; case .png: "metadata-png"; case .heic: "metadata-heic" }
    try await withFiles(name) { container, source, bytes in
      let store = try Store(container: container)
      let budget = try limits()
      let input = try await Importer(store: store, limits: budget)
        .importFile(at: source, format: format, confirmedAdultSelf: true)
      let file = Store.FileReference(sessionID: input.sessionID, fileID: input.inputID, purpose: .originalImport)
      let privateURL = try await store.fileURL(for: file)
      #expect(privateURL.lastPathComponent == "original_import-\(input.inputID.uuidString)")
      #expect(try Data(contentsOf: privateURL) == bytes)
      #expect(try privateURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
      let sanitized = try await ImageIOAvatarPhotoSanitizer(store: store, limits: budget).sanitize(input)
      #expect(sanitized.width == 16 && sanitized.height == 32)
      #expect(!FileManager.default.fileExists(atPath: privateURL.path))
      try await store.removeSession(input.sessionID)
      #expect(try Data(contentsOf: source) == bytes)
      #expect(try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent(Store.directoryName).path).isEmpty)
    }
  }

  @Test("非法输入在创建 session 前拒绝", arguments: 0..<5)
  func rejectedBeforeCopy(kind: Int) async throws {
    try await withFiles { container, source, bytes in
      var selected = source
      var expected: Importer.Failure = .unsafeOrCorruptInput
      let manager = FileManager.default
      if kind == 0 {
        selected = source.appendingPathExtension("link")
        try manager.createSymbolicLink(at: selected, withDestinationURL: source)
      } else if kind == 1 {
        selected = source.appendingPathExtension("hardlink")
        try manager.linkItem(at: source, to: selected)
      } else if kind == 2 {
        selected = source.appendingPathExtension("missing")
        expected = .sourceUnavailable
      } else if kind == 4 {
        expected = .resourceLimitExceeded
      }
      let importer = try Importer(store: Store(container: container), limits: limits(bytes: kind == 4 ? 1 : 1_000_000))
      await #expect(throws: expected) {
        try await importer.importFile(at: selected, format: kind == 3 ? .jpeg : .png, confirmedAdultSelf: true)
      }
      #expect(try manager.contentsOfDirectory(atPath: container.path).isEmpty)
      #expect(try Data(contentsOf: source) == bytes)
    }
  }

  @Test("原图文件预留后取消、源变化和低存储均删除私有半成品", arguments: 0..<3)
  func failureAfterReservation(kind: Int) async throws {
    try await withFiles { container, source, bytes in
      let fileSystem = ImportFaultFileSystem {
        switch kind {
        case 0: withUnsafeCurrentTask { $0?.cancel() }
        case 1: try Data([0, 1, 2]).write(to: source)
        default: throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
      }
      let store = try Store(container: container, fileSystem: fileSystem)
      let importer = try Importer(store: store, limits: limits())
      if kind == 0 {
        await #expect(throws: CancellationError.self) {
          try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
            group.addTask { try await importer.importFile(at: source, format: .png, confirmedAdultSelf: true) }
            _ = try await group.next()
          }
        }
      } else {
        let expected: Importer.Failure = kind == 1 ? .unsafeOrCorruptInput : .storageUnavailable
        await #expect(throws: expected) {
          try await importer.importFile(at: source, format: .png, confirmedAdultSelf: true)
        }
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent(Store.directoryName).path).isEmpty)
      if kind != 1 { #expect(try Data(contentsOf: source) == bytes) }
    }
  }

  @Test("大于两个复制缓冲的合法 PNG 字节完整且仍可净化")
  func multipleChunks() async throws {
    try await withFiles { container, source, _ in
      let width = 512, height = 256
      var seed: UInt32 = 17
      let pixels = Data((0..<(width * height * 4)).map { index -> UInt8 in
        seed = 1_664_525 &* seed &+ 1_013_904_223
        return index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 24)
      })
      let provider = try #require(CGDataProvider(data: pixels as CFData))
      let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
      let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      let encoded = NSMutableData()
      let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      #expect(CGImageDestinationFinalize(destination))
      let bytes = encoded as Data
      #expect(bytes.count > 2 * 64 * 1024)
      try bytes.write(to: source)
      let store = try Store(container: container)
      let budget = try limits(pixels: width * height)
      let input = try await Importer(store: store, limits: budget)
        .importFile(at: source, format: .png, confirmedAdultSelf: true)
      let original = Store.FileReference(sessionID: input.sessionID, fileID: input.inputID, purpose: .originalImport)
      #expect(try Data(contentsOf: await store.fileURL(for: original)) == bytes)
      let output = try await ImageIOAvatarPhotoSanitizer(store: store, limits: budget).sanitize(input)
      #expect(output.width == 32 && output.height == 16)
      try await store.removeSession(input.sessionID)
      #expect(try Data(contentsOf: source) == bytes)
    }
  }

  @Test("取消后清理失败单独报告且私有引用不可继续使用")
  func cleanupFailure() async throws {
    try await withFiles { container, source, bytes in
      let fs = ImportFaultFileSystem(afterCreateFile: { withUnsafeCurrentTask { $0?.cancel() } }, failRemove: true)
      let store = try Store(container: container, fileSystem: fs)
      let importer = try Importer(store: store, limits: limits())
      await #expect(throws: Importer.Failure.cleanupFailed) {
        try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
          group.addTask { try await importer.importFile(at: source, format: .png, confirmedAdultSelf: true) }
          _ = try await group.next()
        }
      }
      await #expect(throws: Store.Failure.sessionsInUse) { try await store.createSession() }
      #expect(try Data(contentsOf: source) == bytes)
      let resumedStore = try Store(container: container)
      try await resumedStore.prepareForUse()
      #expect(try FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent(Store.directoryName).path).isEmpty)
    }
  }
}

nonisolated private struct ImportFaultFileSystem: AvatarPhotoSessionFileSystem {
  let afterCreateFile: @Sendable () throws -> Void
  var failRemove = false
  private let real = FoundationAvatarPhotoSessionFileSystem()
  func kind(at url: URL) throws -> AvatarPhotoSessionEntryKind { try real.kind(at: url) }
  func createProtectedDirectory(at url: URL) throws { try real.createProtectedDirectory(at: url) }
  func applyProtection(at url: URL) throws { try real.applyProtection(at: url) }
  func createProtectedFile(at url: URL) throws {
    try real.createProtectedFile(at: url)
    try afterCreateFile()
  }
  func children(at url: URL) throws -> [URL] { try real.children(at: url) }
  func remove(at url: URL) throws {
    if failRemove { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
    try real.remove(at: url)
  }
}

private final class FixtureBundle: NSObject {}
