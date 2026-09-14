import Foundation
import ImageIO
import Testing
@testable import ThenApp

@Suite("衣物 provider 文件接收")
struct WardrobePhotoFileImporterTests {
  typealias Importer = WardrobePhotoFileImporter

  private func limits(bytes: Int = 1_000_000, duration: Duration = .seconds(5)) throws -> ImageIOWardrobePhotoPreparer.Limits {
    try .init(inputBytes: bytes, sourcePixels: 4096, normalizedDimension: 32, thumbnailDimension: 8,
              rasterBytes: 4096, normalizedBytes: 100_000, thumbnailBytes: 100_000, duration: duration)
  }

  private func fixture(_ name: String) throws -> Data {
    let directory = try #require(Bundle(for: FixtureBundle.self).url(forResource: "AvatarPhotoIntake", withExtension: nil))
    return try Data(contentsOf: directory.appendingPathComponent(name + ".fixture"))
  }

  private func withFile(_ bytes: Data, body: (URL, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Provider fixture cleanup failed") }
    }
    let file = root.appendingPathComponent("source.fixture")
    try bytes.write(to: file)
    try await body(root, file)
  }

  @Test("三种真实格式在 provider 有效期内返回净化对且不删源", arguments: [
    WardrobePhotoSourceFormat.png, .jpeg, .heic])
  func importAndKeepSource(_ format: WardrobePhotoSourceFormat) async throws {
    let name = switch format { case .png: "metadata-png"; case .jpeg: "metadata-jpeg"; case .heic: "metadata-heic" }
    let source = try fixture(name)
    try await withFile(source) { root, file in
      let output = try await Importer(limits: limits()).prepare(fromFile: file, format: format)
      #expect(output.normalized.width == 16 && output.normalized.height == 32)
      #expect(output.thumbnail.width == 4 && output.thumbnail.height == 8)
      #expect(try Data(contentsOf: file) == source)
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      #expect(entries == ["source.fixture"])
      let decoded = try #require(CGImageSourceCreateWithData(output.thumbnail.bytes as CFData, nil))
      #expect(CGImageSourceCreateImageAtIndex(decoded, 0, nil) != nil)
      #expect(output.normalized.bytes.range(of: Data("SYNTHETIC".utf8)) == nil)
    }
  }

  @Test("文件大小和阶段时限超限不保留副本", arguments: [false, true])
  func limitsApply(_ time: Bool) async throws {
    try await withFile(fixture("metadata-png")) { root, file in
      let config = try limits(bytes: time ? 1_000_000 : 1, duration: time ? .nanoseconds(1) : .seconds(5))
      await #expect(throws: Importer.Failure.resourceLimitExceeded) {
        try await Importer(limits: config).prepare(fromFile: file, format: .png)
      }
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      #expect(entries == ["source.fixture"])
    }
  }

  @Test("拒绝链接、目录和空文件，不改动目标", arguments: 0..<4)
  func unsafePaths(_ kind: Int) async throws {
    let bytes = try fixture("metadata-png")
    try await withFile(bytes) { root, original in
      let file = root.appendingPathComponent("unsafe")
      switch kind {
      case 0: try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
      case 1: try FileManager.default.linkItem(at: original, to: file)
      case 2: try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      default: try Data().write(to: file)
      }
      await #expect(throws: Importer.Failure.unsafeInput) {
        try await Importer(limits: limits()).prepare(fromFile: file, format: .png)
      }
      #expect(try Data(contentsOf: original) == bytes)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }
  }

  @Test("缺失和非文件地址明确失败")
  func unavailable() async throws {
    let importer = try Importer(limits: limits())
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    await #expect(throws: Importer.Failure.sourceUnavailable) { try await importer.prepare(fromFile: missing, format: .png) }
    let remote = try #require(URL(string: "https://example.invalid/photo.png"))
    await #expect(throws: Importer.Failure.unsafeInput) { try await importer.prepare(fromFile: remote, format: .png) }
  }

  @Test("错误声明和动画沿用编解码拒绝，不返回原字节", arguments: [false, true])
  func rejectedContent(_ animated: Bool) async throws {
    try await withFile(fixture(animated ? "animated-png" : "metadata-jpeg")) { root, file in
      let expected: ImageIOWardrobePhotoPreparer.Failure = animated ? .unsupportedFormat : .unsafeInput
      await #expect(throws: expected) { try await Importer(limits: limits()).prepare(fromFile: file, format: .png) }
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      #expect(entries == ["source.fixture"])
    }
  }

  @Test("预先取消不读入图片也不删除源")
  func cancelled() async throws {
    try await withFile(fixture("metadata-png")) { root, file in
      let importer = try Importer(limits: limits())
      await #expect(throws: CancellationError.self) {
        try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
          group.cancelAll()
          group.addTask { try await importer.prepare(fromFile: file, format: .png) }
          _ = try await group.next()
        }
      }
      let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
      #expect(entries == ["source.fixture"])
    }
  }

  @Test("真实 2 MiB 图像跨多个读取块且恰好等于输入上限")
  func multipleBlocks() async throws {
    let root = try #require(Bundle(for: FixtureBundle.self).url(forResource: "WardrobeContentProbe", withExtension: nil))
    let bytes = try Data(contentsOf: root.appendingPathComponent("synthetic-flat-shirt.png"))
    #expect(bytes.count > 64 * 1024 * 2)
    let config = try ImageIOWardrobePhotoPreparer.Limits(inputBytes: bytes.count, sourcePixels: 4_000_000,
      normalizedDimension: 512, thumbnailDimension: 64, rasterBytes: 512 * 512 * 4,
      normalizedBytes: 4 * 1024 * 1024, thumbnailBytes: 512 * 1024, duration: .seconds(10))
    try await withFile(bytes) { directory, file in
      let result = try await Importer(limits: config).prepare(fromFile: file, format: .png)
      #expect(result.normalized.width == 512 && result.normalized.height == 512)
      #expect(result.thumbnail.width == 64 && result.thumbnail.height == 64)
      #expect(try Data(contentsOf: file) == bytes)
      let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(entries == ["source.fixture"])
    }
  }

  @Test("Int.max 输入上限不会造成读取长度加一溢出")
  func maximumIntegerBudget() async throws {
    try await withFile(fixture("metadata-png")) { _, file in
      let result = try await Importer(limits: limits(bytes: Int.max)).prepare(fromFile: file, format: .png)
      #expect(result.thumbnail.width == 4)
    }
  }
}

private final class FixtureBundle: NSObject {}
