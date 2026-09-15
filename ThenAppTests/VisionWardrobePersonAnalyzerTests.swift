import CryptoKit
import Foundation
import Testing
@testable import ThenApp

@Suite("衣物真实人物分析与复核存储", .serialized)
struct VisionWardrobePersonAnalyzerTests {
  typealias Analyzer = VisionWardrobePersonAnalyzer

  private func limits() throws -> ImageIOWardrobePhotoPreparer.Limits {
    try .init(inputBytes: 12 * 1024 * 1024, sourcePixels: 4 * 1024 * 1024,
      normalizedDimension: 512, thumbnailDimension: 64, rasterBytes: 1024 * 1024,
      normalizedBytes: 4 * 1024 * 1024, thumbnailBytes: 512 * 1024, duration: .seconds(10))
  }
  private func analyzer(bytes: Int = 4 * 1024 * 1024, pixels: Int = 512 * 512,
                        duration: Duration = .seconds(10)) throws -> Analyzer {
    try .init(maximumBytes: bytes, maximumPixels: pixels, duration: duration, computeDevice: .cpu)
  }
  private func fixture(_ name: String) throws -> URL {
    let folder = try #require(Bundle(for: AnalyzerFixtureBundle.self).url(forResource: "WardrobeContentProbe", withExtension: nil))
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any]
    let rows = try #require(manifest?["fixtures"] as? [[String: Any]])
    let row = try #require(rows.first { $0["id"] as? String == name })
    let url = folder.appendingPathComponent(name + ".png")
    let bytes = try Data(contentsOf: url)
    #expect(bytes.count == (row["byte_count"] as? Int))
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(hash == (row["sha256"] as? String))
    return url
  }
  private func prepared(_ name: String = "synthetic-flat-shirt") async throws -> WardrobePreparedPhoto {
    let source = try Data(contentsOf: fixture(name))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try source.write(to: file)
    defer {
      do { try FileManager.default.removeItem(at: file) }
      catch { Issue.record("Could not remove owned provider fixture") }
    }
    let result = try await WardrobePhotoFileImporter(limits: limits()).prepare(fromFile: file, format: .png)
    #expect(try Data(contentsOf: file) == source)
    return result
  }

  @Test("显式 CPU 在真实规范图上检出成人并允许衣物进入人工复核",
    arguments: ["synthetic-flat-shirt", "synthetic-red-sweater", "synthetic-one-adult"])
  func realCPUAnalysis(_ fixtureName: String) async throws {
    let adult = fixtureName == "synthetic-one-adult"
    let photo = try await prepared(fixtureName)
    let result = try await analyzer().analyze(photo.normalized)
    #expect(result.people == (adult ? 1 : 0))
    #expect(result.faces == (adult ? 1 : 0))
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    try review.receive(photo, for: id)
    try review.analyze(result, for: id)
    #expect(review.phase == (adult ? .rejected(.personDetected) : .needsConfirmation))
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
  }

  @Test("局部身体零检出仍强制当前图片复核")
  func bodyPartsRequireConfirmation() async throws {
    let photo = try await prepared("synthetic-hands-on-shirt")
    let observations = try await analyzer().analyze(photo.normalized)
    print("WARDROBE_BODY_PART_PROBE people=\(observations.people) faces=\(observations.faces)")
    #expect(observations.people == 0)
    #expect(observations.faces == 0)
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    try review.receive(photo, for: id)
    try review.analyze(observations, for: id)
    #expect(review.phase == .needsConfirmation)
    #expect(review.preview != nil)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
    #expect(throws: WardrobePhotoReview.Failure.confirmationRequired) {
      try review.confirm(.init(subject: .singleGarment, ownedByUser: true,
        noPersonInImage: false, mainItemIsComplete: true), for: id)
    }
    #expect(review.phase == .needsConfirmation)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
  }

  @Test("字节、像素和阶段时限均拒绝，非法配置不启动分析", arguments: 0..<3)
  func budget(_ kind: Int) async throws {
    let photo = try await prepared()
    let service = try analyzer(bytes: kind == 0 ? 1 : 4 * 1024 * 1024,
      pixels: kind == 1 ? 1 : 512 * 512, duration: kind == 2 ? .nanoseconds(1) : .seconds(10))
    await #expect(throws: Analyzer.Failure.resourceLimitExceeded) { try await service.analyze(photo.normalized) }
    #expect(throws: Analyzer.Failure.invalidLimits) { try analyzer(bytes: 0) }
    #expect(throws: Analyzer.Failure.invalidLimits) { try analyzer(pixels: 0) }
    #expect(throws: Analyzer.Failure.invalidLimits) { try analyzer(duration: .zero) }
  }

  @Test("格式、真实尺寸与编码内容不符不能进入检测", arguments: 0..<3)
  func invalidImage(_ kind: Int) async throws {
    let photo = try await prepared()
    let input = try WardrobeEncodedImage(bytes: kind == 0 ? Data([1]) : photo.normalized.bytes,
      format: kind == 1 ? .jpeg : .png, width: kind == 2 ? 1 : photo.normalized.width,
      height: photo.normalized.height, maximumBytes: 4 * 1024 * 1024)
    await #expect(throws: Analyzer.Failure.invalidInput) { try await analyzer().analyze(input) }
  }

  @Test("取消不返回检测结论")
  func cancellation() async throws {
    let photo = try await prepared()
    let service = try analyzer()
    await withTaskGroup(of: Void.self) { group in
      group.cancelAll()
      group.addTask {
        await #expect(throws: CancellationError.self) { try await service.analyze(photo.normalized) }
      }
    }
  }

  @Test("真实文件到 CPU 检测、当前复核、持久保存重试与删除")
  func reviewAndPersist() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = GRDBWardrobeRepository(directory: root)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Could not clean analyzer integration fixture") }
    }
    do {
      let item = try await store.create(
        id: UUID(),
        input: .init(
          name: "synthetic shirt",
          category: .top,
          availability: .wearable,
          attributes: .init()
        ),
        source: .wardrobe
      )
      let photo = try await prepared()
      let observations = try await analyzer().analyze(photo.normalized)
      var review = WardrobePhotoReview()
      let id = review.beginSelection()
      try review.receive(photo, for: id)
      try review.analyze(observations, for: id)
      #expect(try await store.readPhoto(itemID: item.id, purpose: .normalized, maximumBytes: 4 * 1024 * 1024) == nil)
      try review.confirm(.init(subject: .singleGarment, ownedByUser: true, noPersonInImage: true, mainItemIsComplete: true), for: id)
      let write = try review.write(for: id)
      let saved = try await store.savePhoto(write, itemID: item.id, expectedRevision: item.revision)
      let retry = try await store.savePhoto(review.write(for: id), itemID: item.id, expectedRevision: item.revision)
      #expect(saved.metadata == retry.metadata && saved.itemRevision == retry.itemRevision)
      try await store.close()
      try await store.prepare()
      let restored = try #require(try await store.readPhoto(itemID: item.id, purpose: .normalized, maximumBytes: 4 * 1024 * 1024))
      #expect(restored.bytes == photo.normalized.bytes)
      #expect(restored.metadata.quality == .catalogReady)
      try await store.removePhoto(id: write.id, itemID: item.id, expectedRevision: saved.itemRevision)
      #expect(try await store.readPhoto(itemID: item.id, purpose: .thumbnail, maximumBytes: 512 * 1024) == nil)
      let items = try await store.list(.init(availability: nil))
      #expect(items.count == 1 && items.first?.id == item.id)
      #expect(try await store.hasPendingPhotoCleanup() == false)
      try await store.close()
    } catch {
      try await store.close()
      throw error
    }
  }
}
private final class AnalyzerFixtureBundle: NSObject {}
