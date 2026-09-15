import Foundation
import Testing

@testable import ThenApp

@Suite("人物照片 POC 启动边界")
struct AvatarPhotoPOCHostTests {
  @Test("只有 Debug 能力明确开启且参数完全匹配时进入 POC")
  func launchMode() {
    #expect(ThenLaunchMode.resolve(arguments: [], debugFeaturesEnabled: true) == .product)
    #expect(ThenLaunchMode.resolve(
      arguments: ["--then-avatar-photo-intake-poc"],
      debugFeaturesEnabled: true
    ) == .avatarPhotoIntakePOC)
    #expect(ThenLaunchMode.resolve(
      arguments: ["--then-avatar-photo-intake-poc"],
      debugFeaturesEnabled: false
    ) == .product)
    #expect(ThenLaunchMode.resolve(
      arguments: ["--then-avatar-photo-intake"],
      debugFeaturesEnabled: true
    ) == .product)
  }

  @Test("POC 场景参数只识别明确的测试值")
  func scenario() {
    #expect(AvatarPhotoPOCScenario.resolve(arguments: []) == .system)
    #expect(AvatarPhotoPOCScenario.resolve(
      arguments: ["--then-avatar-photo-poc-scenario=delayed-multiple-people"]
    ) == .delayedMultiplePeople)
    #expect(AvatarPhotoPOCScenario.resolve(
      arguments: ["--then-avatar-photo-poc-scenario=multiple-people"]
    ) == .multiplePeople)
    #expect(AvatarPhotoPOCScenario.resolve(
      arguments: ["--then-avatar-photo-poc-scenario=device-unavailable"]
    ) == .deviceUnavailable)
    #expect(AvatarPhotoPOCScenario.resolve(
      arguments: ["--then-avatar-photo-poc-scenario=unknown"]
    ) == .system)
  }

  @Test("预览只读取当前会话内尺寸匹配且未超限的单帧净化 PNG")
  func previewBoundary() async throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: container, withIntermediateDirectories: false)
    defer {
      do { try manager.removeItem(at: container) }
      catch { Issue.record("Preview loader test container cleanup failed") }
    }

    let fixtureDirectory = try #require(Bundle(for: AvatarPhotoPOCHostFixtureBundle.self)
      .url(forResource: "AvatarPhotoIntake", withExtension: nil))
    let fixture = try Data(contentsOf: fixtureDirectory
      .appendingPathComponent("vision-adult-full-body.png"))
    let store = try AvatarPhotoTemporarySessionStore(container: container)
    let session = try await store.createSession()
    let file = try await store.createFile(in: session, purpose: .sanitizedPreview)
    let url = try await store.fileURL(for: file)
    try fixture.write(to: url)
    try await store.finishWriting(file)
    let photo = try SanitizedAvatarPhotoHandle(
      sessionID: session,
      assetID: file.fileID,
      width: 1_024,
      height: 1_536
    )

    let loader = AvatarPhotoPreviewLoader(store: store, maximumBytes: fixture.count)
    #expect(try await loader.load(photo) == fixture)

    let wrongDimensions = try SanitizedAvatarPhotoHandle(
      sessionID: session,
      assetID: file.fileID,
      width: 1_023,
      height: 1_536
    )
    await #expect(throws: AvatarPhotoPreviewLoader.Failure.unreadable) {
      try await loader.load(wrongDimensions)
    }
    let undersizedBudget = AvatarPhotoPreviewLoader(
      store: store,
      maximumBytes: fixture.count - 1
    )
    await #expect(throws: AvatarPhotoPreviewLoader.Failure.unreadable) {
      try await undersizedBudget.load(photo)
    }
    try await store.removeSession(session)
  }
}

private final class AvatarPhotoPOCHostFixtureBundle: NSObject {}
