import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import ThenApp

@Suite("人物照片合成夹具与 Vision 适配", .serialized)
struct VisionAvatarPhotoAnalyzerTests {
  private struct Manifest: Decodable {
    struct Truth: Decodable {
      let complete_body: Bool
      let exposure_usable: Bool
      let intentionally_obscured: Bool
      let person_count: Int
      let sharp: Bool
    }

    struct Entry: Decodable {
      let byte_count: Int
      let content_type: String
      let file: String
      let height: Int
      let human_review_truth: Truth
      let id: String
      let sha256: String
      let source: String
      let width: Int
    }

    let authorization: String
    let vision_fixtures: [Entry]
  }

  private func directory() throws -> URL {
    try #require(Bundle(for: VisionAvatarFixtureBundle.self)
      .url(forResource: "AvatarPhotoIntake", withExtension: nil))
  }

  private func manifest() throws -> Manifest {
    try JSONDecoder().decode(
      Manifest.self,
      from: Data(contentsOf: directory().appendingPathComponent("manifest.json"))
    )
  }

  private func entry(_ id: String) throws -> Manifest.Entry {
    try #require(manifest().vision_fixtures.first { $0.id == id })
  }

  private func data(_ id: String) throws -> Data {
    let row = try entry(id)
    return try Data(contentsOf: directory().appendingPathComponent(row.file))
  }

  private func image(_ id: String) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data(id) as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  }

  @Test("九张素材均为登记的合成 PNG，内容事实完整")
  func fixtureManifest() throws {
    let root = try directory()
    let manifest = try manifest()
    #expect(manifest.authorization.contains("synthetic"))
    #expect(manifest.vision_fixtures.count == 9)
    #expect(Set(manifest.vision_fixtures.map(\.id)).count == 9)
    #expect(Set(manifest.vision_fixtures.map(\.human_review_truth.person_count)) == [0, 1, 2])
    #expect(manifest.vision_fixtures.contains { $0.human_review_truth.intentionally_obscured })
    #expect(manifest.vision_fixtures.contains { !$0.human_review_truth.complete_body })
    #expect(manifest.vision_fixtures.contains { !$0.human_review_truth.sharp })
    #expect(manifest.vision_fixtures.contains { !$0.human_review_truth.exposure_usable })

    for entry in manifest.vision_fixtures {
      let bytes = try Data(contentsOf: root.appendingPathComponent(entry.file))
      #expect(bytes.count == entry.byte_count)
      #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
      #expect(entry.source.contains("synthetic"))
      let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
      #expect(CGImageSourceGetType(source) as String? == entry.content_type)
      let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
      #expect(properties[kCGImagePropertyPixelWidth] as? Int == entry.width)
      #expect(properties[kCGImagePropertyPixelHeight] as? Int == entry.height)
      #expect(CGImageSourceGetCount(source) == 1)
    }
  }

  @Test("真实合成像素能区分运动模糊和欠曝")
  func pixelQualityOrdering() throws {
    let fullBody = try VisionAvatarPhotoAnalyzer.pixelScores(for: image("vision-adult-full-body"))
    let headscarf = try VisionAvatarPhotoAnalyzer.pixelScores(for: image("vision-adult-headscarf"))
    let blurred = try VisionAvatarPhotoAnalyzer.pixelScores(for: image("vision-adult-motion-blur"))
    let underexposed = try VisionAvatarPhotoAnalyzer.pixelScores(for: image("vision-adult-underexposed"))

    #expect(fullBody.sharpness > blurred.sharpness)
    #expect(headscarf.sharpness > blurred.sharpness)
    #expect(fullBody.exposureUsability > underexposed.exposureUsability)
    #expect(headscarf.exposureUsability > underexposed.exposureUsability)
    for score in [fullBody, headscarf, blurred, underexposed] {
      #expect((0...1).contains(score.sharpness))
      #expect((0...1).contains(score.exposureUsability))
    }
  }

  @Test("模拟器能力不可用时不伪造人员或质量结论")
  func liveVisionCapabilityBoundary() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    let store = try AvatarPhotoTemporarySessionStore(container: container)
    defer {
      do { try FileManager.default.removeItem(at: container) }
      catch { Issue.record("Could not remove synthetic avatar fixture container") }
    }

    let row = try entry("vision-adult-full-body")
    let session = try await store.createSession()
    let file = try await store.createFile(in: session, purpose: .sanitizedPreview)
    try data(row.id).write(to: await store.fileURL(for: file), options: .completeFileProtection)
    try await store.finishWriting(file)
    let photo = try SanitizedAvatarPhotoHandle(
      sessionID: session, assetID: file.fileID, width: row.width, height: row.height)
    let analyzer = try VisionAvatarPhotoAnalyzer(
      store: store,
      maximumBytes: 4 * 1024 * 1024,
      maximumPixels: 4 * 1024 * 1024,
      duration: .seconds(15),
      computeDevice: .cpu
    )
    let result = try await analyzer.analyze(photo)
    let people = result.personCount.map { String($0) } ?? "nil"
    print("AVATAR_VISION_CAPABILITY available=\(result.deviceCapabilityAvailable) succeeded=\(result.analysisSucceeded) people=\(people)")
    if result.deviceCapabilityAvailable {
      #expect(result.analysisSucceeded)
      #expect(result.personCount == 1)
      #expect(result.sharpness != nil)
      #expect(result.exposureUsability != nil)
    } else {
      #expect(!result.analysisSucceeded)
      #expect(result.personCount == nil)
      #expect(result.fullPersonCoverage == nil)
      #expect(result.visibility == nil)
      #expect(result.sharpness == nil)
      #expect(result.exposureUsability == nil)
    }
    try await store.removeSession(session)
  }

  @Test("非法预算不构造分析器")
  func invalidConfiguration() throws {
    let store = try AvatarPhotoTemporarySessionStore()
    #expect(throws: VisionAvatarPhotoAnalyzer.ConfigurationError.invalidLimits) {
      try VisionAvatarPhotoAnalyzer(
        store: store, maximumBytes: 0, maximumPixels: 1,
        duration: .seconds(1), computeDevice: .cpu)
    }
    #expect(throws: VisionAvatarPhotoAnalyzer.ConfigurationError.invalidLimits) {
      try VisionAvatarPhotoAnalyzer(
        store: store, maximumBytes: 1, maximumPixels: 0,
        duration: .seconds(1), computeDevice: .cpu)
    }
    #expect(throws: VisionAvatarPhotoAnalyzer.ConfigurationError.invalidLimits) {
      try VisionAvatarPhotoAnalyzer(
        store: store, maximumBytes: 1, maximumPixels: 1,
        duration: .zero, computeDevice: .cpu)
    }
  }

  @Test("声明尺寸不符和文件超限时在 Vision 前关闭失败")
  func rejectsUnsafeDimensionsAndOversizedFile() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    let store = try AvatarPhotoTemporarySessionStore(container: container)
    defer {
      do { try FileManager.default.removeItem(at: container) }
      catch { Issue.record("Could not remove synthetic avatar fixture container") }
    }

    let row = try entry("vision-adult-full-body")
    let fixture = try data(row.id)
    let session = try await store.createSession()
    let file = try await store.createFile(in: session, purpose: .sanitizedPreview)
    try fixture.write(to: await store.fileURL(for: file), options: .completeFileProtection)
    try await store.finishWriting(file)

    let wrongDimensions = try SanitizedAvatarPhotoHandle(
      sessionID: session, assetID: file.fileID, width: row.width + 1, height: row.height)
    let normalAnalyzer = try VisionAvatarPhotoAnalyzer(
      store: store,
      maximumBytes: fixture.count,
      maximumPixels: row.width * row.height,
      duration: .seconds(5),
      computeDevice: .cpu
    )
    let unsafeResult = try await normalAnalyzer.analyze(wrongDimensions)
    #expect(!unsafeResult.inputSafe)
    #expect(!unsafeResult.analysisSucceeded)
    #expect(unsafeResult.personCount == nil)

    let correctHandle = try SanitizedAvatarPhotoHandle(
      sessionID: session, assetID: file.fileID, width: row.width, height: row.height)
    let limitedAnalyzer = try VisionAvatarPhotoAnalyzer(
      store: store,
      maximumBytes: fixture.count - 1,
      maximumPixels: row.width * row.height,
      duration: .seconds(5),
      computeDevice: .cpu
    )
    let oversizedResult = try await limitedAnalyzer.analyze(correctHandle)
    #expect(!oversizedResult.withinResourceBudget)
    #expect(!oversizedResult.analysisSucceeded)
    #expect(oversizedResult.personCount == nil)

    try await store.removeSession(session)
  }
}

private final class VisionAvatarFixtureBundle: NSObject {}
