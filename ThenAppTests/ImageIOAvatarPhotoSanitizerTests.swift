import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import ThenApp

@Suite("照片 POC ImageIO 净化")
struct ImageIOAvatarPhotoSanitizerTests {
  private typealias Store = AvatarPhotoTemporarySessionStore
  private typealias Sanitizer = ImageIOAvatarPhotoSanitizer
  private let manager = FileManager.default

  private func limits(
    inputBytes: Int = 1_000_000, sourcePixels: Int = 4096,
    outputBytes: Int = 100_000, duration: Duration = .seconds(5)
  ) throws -> Sanitizer.Limits {
    try Sanitizer.Limits(maximumInputBytes: inputBytes, maximumSourcePixels: sourcePixels,
      maximumOutputDimension: 32, maximumRasterBytes: 4096,
      maximumOutputBytes: outputBytes, maximumDuration: duration)
  }

  private func fixtureDirectory() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["THEN_AVATAR_FIXTURE_DIRECTORY"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return try #require(Bundle(for: FixtureBundle.self).url(forResource: "AvatarPhotoIntake", withExtension: nil))
  }

  private func fixture(_ id: String) throws -> Data {
    try Data(contentsOf: fixtureDirectory().appendingPathComponent(id + ".fixture"))
  }

  private func withInput(
    _ bytes: Data, format: AvatarPhotoInputFormat,
    body: (Store, AvatarPhotoInputHandle, URL) async throws -> Void
  ) async throws {
    let container = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: container, withIntermediateDirectories: false)
    defer {
      do { try manager.removeItem(at: container) }
      catch { Issue.record("Synthetic image test container cleanup failed") }
    }
    let store = try Store(container: container)
    let session = try await store.createSession()
    let file = try await store.createFile(in: session, purpose: .originalImport)
    let url = try await store.fileURL(for: file)
    try bytes.write(to: url)
    let input = AvatarPhotoInputHandle(sessionID: session, inputID: file.fileID, format: format)
    try await body(store, input, url)
  }

  @Test("合成素材与登记的哈希、类型和帧数一致")
  func fixtureManifest() throws {
    struct Manifest: Decodable {
      struct Entry: Decodable { let file: String; let sha256: String; let content_type: String; let frames: Int }
      let fixtures: [Entry]
    }
    let root = try fixtureDirectory()
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    #expect(manifest.fixtures.count == 5)
    for entry in manifest.fixtures {
      let bytes = try Data(contentsOf: root.appendingPathComponent(entry.file))
      #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
      let source = try #require(CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
      #expect(CGImageSourceGetType(source) as String? == entry.content_type)
      #expect(CGImageSourceGetCount(source) == entry.frames)
    }
  }

  @Test("JPEG/PNG/HEIC 只从像素生成标准色彩净化图", arguments: [
    AvatarPhotoInputFormat.jpeg, .png, .heic,
  ])
  func sanitizedImage(format: AvatarPhotoInputFormat) async throws {
    let id = switch format { case .jpeg: "metadata-jpeg"; case .png: "metadata-png"; case .heic: "metadata-heic" }
    let bytes = try fixture(id)
    let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let sourceProperties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    #expect(sourceProperties[kCGImagePropertyOrientation as String] as? Int == 6)
    #expect(sourceProperties[kCGImagePropertyGPSDictionary as String] != nil)
    try await withInput(bytes, format: format) { store, input, originalURL in
      let result = try await Sanitizer(store: store, limits: limits()).sanitize(input)
      #expect(result.width == 16)
      #expect(result.height == 32)
      #expect(!manager.fileExists(atPath: originalURL.path))
      let file = Store.FileReference(sessionID: result.sessionID, fileID: result.assetID, purpose: .sanitizedPreview)
      let outputURL = try await store.fileURL(for: file)
      #expect(try outputURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
      let output = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
      #expect(CGImageSourceGetType(output) as String? == "public.png")
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [String: Any])
      for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary,
                  kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
        #expect(properties[key as String] == nil)
      }
      #expect((properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
      let image = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
      #expect(image.colorSpace?.name == CGColorSpace.sRGB)
      let outputBytes = try Data(contentsOf: outputURL)
      for marker in ["SYNTHETIC", "TEST-CAMERA", "source-name.jpg", "2000:01:01"] {
        #expect(outputBytes.range(of: Data(marker.utf8)) == nil)
      }
      #expect(try manager.contentsOfDirectory(atPath: outputURL.deletingLastPathComponent().path).count == 1)
      try await store.removeSession(result.sessionID)
      #expect(!manager.fileExists(atPath: outputURL.path))
    }
  }

  @Test("声明格式不一致或损坏输入被拒绝，并清空会话", arguments: [false, true])
  func invalidInput(truncated: Bool) async throws {
    let bytes = truncated ? Data(try fixture("metadata-png").prefix(40)) : try fixture("metadata-jpeg")
    try await withInput(bytes, format: .png) { store, input, originalURL in
      let sanitizer = try Sanitizer(store: store, limits: limits())
      await #expect(throws: Sanitizer.Failure.unsafeOrCorruptInput) { try await sanitizer.sanitize(input) }
      #expect(!manager.fileExists(atPath: originalURL.deletingLastPathComponent().path))
    }
  }

  @Test("动画和未批准格式不会按第一帧继续", arguments: ["animated-png", "unsupported-tiff"])
  func unsupportedInput(id: String) async throws {
    try await withInput(fixture(id), format: .png) { store, input, originalURL in
      let sanitizer = try Sanitizer(store: store, limits: limits())
      await #expect(throws: Sanitizer.Failure.unsupportedFormat) { try await sanitizer.sanitize(input) }
      #expect(!manager.fileExists(atPath: originalURL.deletingLastPathComponent().path))
    }
  }

  @Test("文件、像素、输出和阶段预算分别生效", arguments: 0..<4)
  func resourceLimits(index: Int) async throws {
    try await withInput(fixture("metadata-jpeg"), format: .jpeg) { store, input, originalURL in
      let budget = try limits(inputBytes: index == 0 ? 1 : 1_000_000,
        sourcePixels: index == 1 ? 2047 : 4096, outputBytes: index == 2 ? 1 : 100_000,
        duration: index == 3 ? .nanoseconds(1) : .seconds(5))
      let sanitizer = Sanitizer(store: store, limits: budget)
      await #expect(throws: Sanitizer.Failure.resourceLimitExceeded) { try await sanitizer.sanitize(input) }
      #expect(!manager.fileExists(atPath: originalURL.deletingLastPathComponent().path))
    }
  }

  @Test("预先取消的任务清理原图且不返回净化句柄")
  func cancellation() async throws {
    try await withInput(fixture("metadata-png"), format: .png) { store, input, originalURL in
      let sanitizer = try Sanitizer(store: store, limits: limits())
      await #expect(throws: CancellationError.self) {
        try await withThrowingTaskGroup(of: SanitizedAvatarPhotoHandle.self) { group in
          group.cancelAll()
          group.addTask { try await sanitizer.sanitize(input) }
          _ = try await group.next()
        }
      }
      #expect(!manager.fileExists(atPath: originalURL.deletingLastPathComponent().path))
    }
  }

  @Test("无效预算不会构造处理器")
  func invalidConfiguration() {
    #expect(throws: Sanitizer.ConfigurationError.invalidLimits) {
      try Sanitizer.Limits(maximumInputBytes: 1, maximumSourcePixels: 1,
        maximumOutputDimension: Int.max, maximumRasterBytes: Int.max,
        maximumOutputBytes: 1, maximumDuration: .seconds(1))
    }
    #expect(throws: Sanitizer.ConfigurationError.invalidLimits) { try limits(duration: .zero) }
  }
}

private final class FixtureBundle: NSObject {}
