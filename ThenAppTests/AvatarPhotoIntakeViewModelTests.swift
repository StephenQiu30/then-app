import Foundation
import Testing

@testable import ThenApp

@MainActor @Suite("人物照片 POC 状态机", .serialized)
struct AvatarPhotoIntakeViewModelTests {
  @Test("声明后依次呈现导入净化分析和复核")
  func stagesAndReview() async throws {
    let photo = try handle()
    let probe = ViewModelPreparationProbe([
      .init(result: .success(.review(photo, .init(primaryReason: nil))), controlled: true),
    ])
    let model = AvatarPhotoIntakeViewModel(useCase: probe)
    #expect(model.state == .disclosure)
    model.prepare(importing: { Self.input(sessionID: photo.sessionID) })
    await Task.yield()
    #expect(model.state == .disclosure)
    #expect(await probe.executionCount() == 0)
    model.continueToPhotoSelection()
    #expect(model.state == .awaitingSelection)

    model.prepare(importing: { Self.input(sessionID: photo.sessionID) })
    await expectState(model, .importing)
    await probe.releaseNext()
    await expectState(model, .sanitizing)
    await probe.releaseNext()
    await expectState(model, .analyzing)
    await probe.releaseNext()
    await expectState(model, .review(photo, .init(primaryReason: nil)))
    #expect(!model.isProcessing)
  }

  @Test("换图和不支持结果映射为稳定终态")
  func terminalMappings() async throws {
    let replacement = AvatarPhotoQualityAssessment(primaryReason: .multiplePeople)
    let unsupported = AvatarPhotoQualityAssessment(primaryReason: .deviceCapabilityUnavailable)
    let probe = ViewModelPreparationProbe([
      .init(result: .success(.replacement(replacement))),
      .init(result: .success(.unsupported(unsupported))),
    ])
    let model = AvatarPhotoIntakeViewModel(useCase: probe)
    model.continueToPhotoSelection()
    model.prepare(importing: { Self.input() })
    await expectState(model, .replacement(replacement))
    model.prepare(importing: { Self.input() })
    await expectState(model, .unsupported(unsupported))
  }

  @Test("异常可恢复，取消后迟到成功只清理不更新界面")
  func failureAndCancellation() async throws {
    let failingProbe = ViewModelPreparationProbe([
      .init(result: .failure(.processing)),
    ])
    let failingModel = AvatarPhotoIntakeViewModel(useCase: failingProbe)
    failingModel.continueToPhotoSelection()
    failingModel.prepare(importing: { Self.input() })
    await expectState(failingModel, .recoverableFailure(.analysisFailed))

    let photo = try handle()
    let delayedProbe = ViewModelPreparationProbe([
      .init(result: .success(.review(photo, .init(primaryReason: nil))), controlled: true),
    ])
    let delayedModel = AvatarPhotoIntakeViewModel(useCase: delayedProbe)
    delayedModel.continueToPhotoSelection()
    delayedModel.prepare(importing: { Self.input(sessionID: photo.sessionID) })
    await expectState(delayedModel, .importing)
    await expectExecutionCount(delayedProbe, 1)
    delayedModel.cancelProcessing()
    #expect(delayedModel.state == .awaitingSelection)
    await delayedProbe.releaseAllStages()
    await expectDiscard(delayedProbe, photo)
    #expect(delayedModel.state == .awaitingSelection)
  }

  @Test("旧选择完成收口后新选择才开始且不能被覆盖")
  func staleResultSuppression() async throws {
    let oldPhoto = try handle()
    let unsupported = AvatarPhotoQualityAssessment(primaryReason: .deviceCapabilityUnavailable)
    let probe = ViewModelPreparationProbe([
      .init(result: .success(.review(oldPhoto, .init(primaryReason: nil))), controlled: true),
      .init(result: .success(.unsupported(unsupported))),
    ])
    let model = AvatarPhotoIntakeViewModel(useCase: probe)
    model.continueToPhotoSelection()
    model.prepare(importing: { Self.input(sessionID: oldPhoto.sessionID) })
    await expectState(model, .importing)
    await expectExecutionCount(probe, 1)
    model.prepare(importing: { Self.input() })
    await probe.releaseAllStages()
    await expectState(model, .unsupported(unsupported))
    await expectDiscard(probe, oldPhoto)
    #expect(await probe.maximumConcurrentExecutions() == 1)
  }

  @Test("模板退出和进入后台都会移除可见预览")
  func templateAndSceneCleanup() async throws {
    let first = try handle()
    let second = try handle()
    let probe = ViewModelPreparationProbe([
      .init(result: .success(.review(first, .init(primaryReason: nil)))),
      .init(result: .success(.review(second, .init(primaryReason: nil)))),
    ])
    let model = AvatarPhotoIntakeViewModel(useCase: probe)
    model.continueToPhotoSelection()
    model.prepare(importing: { Self.input(sessionID: first.sessionID) })
    await expectState(model, .review(first, .init(primaryReason: nil)))
    model.useTemplate()
    #expect(model.state == .templateFallback)
    await expectDiscard(probe, first)

    model.returnToDisclosure()
    await expectState(model, .disclosure)
    model.continueToPhotoSelection()
    model.prepare(importing: { Self.input(sessionID: second.sessionID) })
    await expectState(model, .review(second, .init(primaryReason: nil)))
    model.sceneBecameInactive()
    #expect(model.state == .disclosure)
    await expectDiscard(probe, second)
  }

  nonisolated private static func input(sessionID: UUID = UUID()) -> AvatarPhotoInputHandle {
    AvatarPhotoInputHandle(sessionID: sessionID, inputID: UUID(), format: .png)
  }

  private func handle() throws -> SanitizedAvatarPhotoHandle {
    try SanitizedAvatarPhotoHandle(
      sessionID: UUID(), assetID: UUID(), width: 800, height: 1200)
  }

  private func expectState(
    _ model: AvatarPhotoIntakeViewModel,
    _ expected: AvatarPhotoIntakeState,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if model.state == expected { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("State did not become \(expected)", sourceLocation: sourceLocation)
  }

  private func expectDiscard(
    _ probe: ViewModelPreparationProbe,
    _ photo: SanitizedAvatarPhotoHandle,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if await probe.discardedPhotos().contains(photo) { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Review photo was not discarded", sourceLocation: sourceLocation)
  }

  private func expectExecutionCount(
    _ probe: ViewModelPreparationProbe,
    _ expected: Int,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if await probe.executionCount() == expected { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Execution count did not become \(expected)", sourceLocation: sourceLocation)
  }
}

nonisolated private enum ViewModelProbeError: Error { case processing }

private actor ViewModelPreparationProbe: AvatarPhotoPreparing {
  struct Response: Sendable {
    let result: Result<AvatarPhotoPreparationResult, ViewModelProbeError>
    let controlled: Bool

    init(
      result: Result<AvatarPhotoPreparationResult, ViewModelProbeError>,
      controlled: Bool = false
    ) {
      self.result = result
      self.controlled = controlled
    }
  }

  private var responses: [Response]
  private var gates: [CheckedContinuation<Void, Never>] = []
  private var releaseCredits = 0
  private var discarded: [SanitizedAvatarPhotoHandle] = []
  private var activeExecutions = 0
  private var maximumExecutions = 0
  private var totalExecutions = 0

  init(_ responses: [Response]) { self.responses = responses }

  func execute(
    importing importPhoto: @Sendable () async throws -> AvatarPhotoInputHandle,
    progress: @escaping @Sendable (AvatarPhotoPreparationStage) async -> Void
  ) async throws -> AvatarPhotoPreparationResult {
    activeExecutions += 1
    totalExecutions += 1
    maximumExecutions = max(maximumExecutions, activeExecutions)
    defer { activeExecutions -= 1 }
    let response = responses.removeFirst()
    await progress(.importing)
    if response.controlled { await waitForRelease() }
    _ = try await importPhoto()
    await progress(.sanitizing)
    if response.controlled { await waitForRelease() }
    await progress(.analyzing)
    if response.controlled { await waitForRelease() }
    return try response.result.get()
  }

  func discard(_ photo: SanitizedAvatarPhotoHandle) {
    discarded.append(photo)
  }

  func releaseNext() {
    if gates.isEmpty { releaseCredits += 1 }
    else { gates.removeFirst().resume() }
  }

  func releaseAllStages() {
    let pending = gates
    gates.removeAll()
    releaseCredits += max(0, 3 - pending.count)
    for continuation in pending { continuation.resume() }
  }

  func discardedPhotos() -> [SanitizedAvatarPhotoHandle] { discarded }
  func executionCount() -> Int { totalExecutions }
  func maximumConcurrentExecutions() -> Int { maximumExecutions }

  private func waitForRelease() async {
    if releaseCredits > 0 { releaseCredits -= 1; return }
    await withCheckedContinuation { gates.append($0) }
  }
}
