import CryptoKit
import Foundation
import Testing
@testable import ThenApp

@Suite("单件图 Vision 隔离能力", .serialized)
struct WardrobeVisionProbeTests {
  private struct Manifest: Decodable {
    struct Entry: Decodable {
      let id: String
      let file: String
      let sha256: String
      let expected_people: Int?
      let expected_faces: Int?
      let expected_foreground_instances: Int?
    }
    let fixtures: [Entry]
  }

  @Test("明确合成标签与真实 Vision 返回逐项对照", arguments: ["synthetic-one-adult", "synthetic-flat-shirt"], WardrobeVisionProbe.Request.allCases)
  func measurements(id: String, request: WardrobeVisionProbe.Request) async throws {
    try await measure(id: id, request: request, cpuOnly: false)
  }

  @Test("明确 CPU 设备的隔离对照，不能覆盖默认运行失败", arguments: ["synthetic-one-adult", "synthetic-flat-shirt"], WardrobeVisionProbe.Request.allCases)
  func cpuMeasurements(id: String, request: WardrobeVisionProbe.Request) async throws {
    try await measure(id: id, request: request, cpuOnly: true)
  }

  private func measure(id: String, request: WardrobeVisionProbe.Request, cpuOnly: Bool) async throws {
    let root = try #require(Bundle(for: FixtureBundle.self).url(forResource: "WardrobeContentProbe", withExtension: nil))
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    let entry = try #require(manifest.fixtures.first { $0.id == id })
    let bytes = try Data(contentsOf: root.appendingPathComponent(entry.file))
    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
    let limits = try ImageIOWardrobePhotoPreparer.Limits(inputBytes: 12 * 1024 * 1024,
      sourcePixels: 4_000_000, normalizedDimension: 512, thumbnailDimension: 64,
      rasterBytes: 512 * 512 * 4, normalizedBytes: 4 * 1024 * 1024, thumbnailBytes: 512 * 1024,
      duration: .seconds(10))
    let normalized = try await ImageIOWardrobePhotoPreparer(limits: limits).prepare(bytes, format: .png)
    let start = ContinuousClock.now
    let count = try await WardrobeVisionProbe.count(request, png: normalized.normalized.bytes, cpuOnly: cpuOnly)
    let expectedValue: Int? = switch request {
    case .people: entry.expected_people
    case .faces: entry.expected_faces
    case .foreground: entry.expected_foreground_instances
    }
    let expected = try #require(expectedValue)
    print("WARDROBE_VISION fixture=\(id) request=\(request.rawValue) cpu=\(cpuOnly) expected=\(expected) actual=\(count) duration=\(start.duration(to: .now))")
    #expect(count == expected)
  }
}

private final class FixtureBundle: NSObject {}
