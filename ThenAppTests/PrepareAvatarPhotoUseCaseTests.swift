import Foundation
import Synchronization
import Testing

@testable import ThenApp

@Suite("人物照片准备管线", .serialized)
struct PrepareAvatarPhotoUseCaseTests {
  private func policy() throws -> AvatarPhotoQualityPolicy {
    try AvatarPhotoQualityPolicy(
      minimumFullPersonCoverage: 0.5,
      minimumVisibility: 0.5,
      minimumSharpness: 0.5,
      minimumExposureUsability: 0.5
    )
  }

  private func passingSignals() -> AvatarPhotoTechnicalSignals {
    AvatarPhotoTechnicalSignals(
      formatSupported: true,
      inputSafe: true,
      withinResourceBudget: true,
      personCount: 1,
      fullPersonCoverage: 1,
      visibility: 1,
      sharpness: 1,
      exposureUsability: 1,
      deviceCapabilityAvailable: true,
      analysisSucceeded: true,
      hasQualityWarning: false
    )
  }

  @Test("通过结果保留净化预览直到调用方明确丢弃")
  func passingReviewOwnership() async throws {
    let probe = PipelineProbe()
    let session = UUID()
    let input = AvatarPhotoInputHandle(sessionID: session, inputID: UUID(), format: .png)
    let photo = try SanitizedAvatarPhotoHandle(
      sessionID: session, assetID: UUID(), width: 800, height: 1200)
    let useCase = PrepareAvatarPhotoUseCase(
      sanitizer: SanitizerProbe(probe: probe, result: .success(photo)),
      analyzer: AnalyzerProbe(probe: probe, result: .success(passingSignals())),
      policy: try policy(),
      sessionCleaner: CleanerProbe(probe: probe)
    )

    let result = try await useCase.execute {
      await probe.record(.importPhoto)
      return input
    }
    #expect(result == .review(photo, AvatarPhotoQualityAssessment(primaryReason: nil)))
    #expect(await probe.snapshot() == [.importPhoto, .sanitize, .analyze])

    try await useCase.discard(photo)
    #expect(await probe.snapshot() == [.importPhoto, .sanitize, .analyze, .cleanup(session)])
  }

  @Test("需要换图和设备不支持都先清理再返回")
  func rejectedResultsCleanSession() async throws {
    let cases: [(AvatarPhotoTechnicalSignals, AvatarPhotoPreparationResult)] = [
      (
        AvatarPhotoTechnicalSignals(
          formatSupported: true, inputSafe: true, withinResourceBudget: true,
          personCount: 0, fullPersonCoverage: nil, visibility: nil, sharpness: 1,
          exposureUsability: 1, deviceCapabilityAvailable: true,
          analysisSucceeded: true, hasQualityWarning: false),
        .replacement(AvatarPhotoQualityAssessment(primaryReason: .noPersonDetected))
      ),
      (
        AvatarPhotoTechnicalSignals(
          formatSupported: true, inputSafe: true, withinResourceBudget: true,
          personCount: nil, fullPersonCoverage: nil, visibility: nil, sharpness: nil,
          exposureUsability: nil, deviceCapabilityAvailable: false,
          analysisSucceeded: false, hasQualityWarning: false),
        .unsupported(AvatarPhotoQualityAssessment(primaryReason: .deviceCapabilityUnavailable))
      ),
    ]

    for (signals, expected) in cases {
      let probe = PipelineProbe()
      let session = UUID()
      let input = AvatarPhotoInputHandle(sessionID: session, inputID: UUID(), format: .png)
      let photo = try SanitizedAvatarPhotoHandle(
        sessionID: session, assetID: UUID(), width: 800, height: 1200)
      let useCase = PrepareAvatarPhotoUseCase(
        sanitizer: SanitizerProbe(probe: probe, result: .success(photo)),
        analyzer: AnalyzerProbe(probe: probe, result: .success(signals)),
        policy: try policy(),
        sessionCleaner: CleanerProbe(probe: probe)
      )

      let result = try await useCase.execute {
        await probe.record(.importPhoto)
        return input
      }
      #expect(result == expected)
      #expect(await probe.snapshot() == [.importPhoto, .sanitize, .analyze, .cleanup(session)])
    }
  }

  @Test("净化异常和分析取消都清理已导入会话")
  func failureAndCancellationCleanSession() async throws {
    for stage in [PipelineStage.sanitize, .analyze] {
      let probe = PipelineProbe()
      let session = UUID()
      let input = AvatarPhotoInputHandle(sessionID: session, inputID: UUID(), format: .png)
      let photo = try SanitizedAvatarPhotoHandle(
        sessionID: session, assetID: UUID(), width: 800, height: 1200)
      let useCase = PrepareAvatarPhotoUseCase(
        sanitizer: SanitizerProbe(
          probe: probe,
          result: stage == .sanitize ? .failure(PipelineProbeError.stage) : .success(photo)),
        analyzer: AnalyzerProbe(
          probe: probe,
          result: stage == .analyze ? .failure(CancellationError()) : .success(passingSignals())),
        policy: try policy(),
        sessionCleaner: CleanerProbe(probe: probe)
      )

      if stage == .analyze {
        await #expect(throws: CancellationError.self) {
          try await useCase.execute {
            await probe.record(.importPhoto)
            return input
          }
        }
        #expect(await probe.snapshot() == [.importPhoto, .sanitize, .analyze, .cleanup(session)])
      } else {
        await #expect(throws: PipelineProbeError.stage) {
          try await useCase.execute {
            await probe.record(.importPhoto)
            return input
          }
        }
        #expect(await probe.snapshot() == [.importPhoto, .sanitize, .cleanup(session)])
      }
    }
  }

  @Test("导入前失败不猜测会话，清理失败使用稳定错误")
  func importAndCleanupFailures() async throws {
    let importProbe = PipelineProbe()
    let unusedPhoto = try SanitizedAvatarPhotoHandle(
      sessionID: UUID(), assetID: UUID(), width: 1, height: 1)
    let importUseCase = PrepareAvatarPhotoUseCase(
      sanitizer: SanitizerProbe(probe: importProbe, result: .success(unusedPhoto)),
      analyzer: AnalyzerProbe(probe: importProbe, result: .success(passingSignals())),
      policy: try policy(),
      sessionCleaner: CleanerProbe(probe: importProbe)
    )
    await #expect(throws: PipelineProbeError.stage) {
      try await importUseCase.execute {
        await importProbe.record(.importPhoto)
        throw PipelineProbeError.stage
      }
    }
    #expect(await importProbe.snapshot() == [.importPhoto])

    let cleanupProbe = PipelineProbe(cleanupFails: true)
    let session = UUID()
    let input = AvatarPhotoInputHandle(sessionID: session, inputID: UUID(), format: .png)
    let cleanupUseCase = PrepareAvatarPhotoUseCase(
      sanitizer: SanitizerProbe(probe: cleanupProbe, result: .failure(PipelineProbeError.stage)),
      analyzer: AnalyzerProbe(probe: cleanupProbe, result: .success(passingSignals())),
      policy: try policy(),
      sessionCleaner: CleanerProbe(probe: cleanupProbe)
    )
    await #expect(throws: PrepareAvatarPhotoUseCase.Failure.cleanupFailed) {
      try await cleanupUseCase.execute {
        await cleanupProbe.record(.importPhoto)
        return input
      }
    }
    #expect(await cleanupProbe.snapshot() == [.importPhoto, .sanitize, .cleanup(session)])
  }

  @Test("净化结果不能切换到另一个会话")
  func rejectsChangedSession() async throws {
    let probe = PipelineProbe()
    let session = UUID()
    let input = AvatarPhotoInputHandle(sessionID: session, inputID: UUID(), format: .png)
    let foreign = try SanitizedAvatarPhotoHandle(
      sessionID: UUID(), assetID: UUID(), width: 800, height: 1200)
    let useCase = PrepareAvatarPhotoUseCase(
      sanitizer: SanitizerProbe(probe: probe, result: .success(foreign)),
      analyzer: AnalyzerProbe(probe: probe, result: .success(passingSignals())),
      policy: try policy(),
      sessionCleaner: CleanerProbe(probe: probe)
    )

    await #expect(throws: PrepareAvatarPhotoUseCase.Failure.invalidSessionOwnership) {
      try await useCase.execute {
        await probe.record(.importPhoto)
        return input
      }
    }
    #expect(await probe.snapshot() == [.importPhoto, .sanitize, .cleanup(session)])
  }
}

nonisolated private enum PipelineProbeError: Error { case stage, cleanup }

nonisolated private enum PipelineStage: Sendable, Equatable {
  case importPhoto, sanitize, analyze, cleanup(UUID)
}

private actor PipelineProbe {
  private var stages: [PipelineStage] = []
  private let cleanupFails: Bool

  init(cleanupFails: Bool = false) { self.cleanupFails = cleanupFails }

  func record(_ stage: PipelineStage) { stages.append(stage) }
  func snapshot() -> [PipelineStage] { stages }
  func cleanup(_ sessionID: UUID) throws {
    stages.append(.cleanup(sessionID))
    if cleanupFails { throw PipelineProbeError.cleanup }
  }
}

nonisolated private struct SanitizerProbe: AvatarPhotoSanitizing {
  let probe: PipelineProbe
  let result: Result<SanitizedAvatarPhotoHandle, any Error>

  func sanitize(_ input: AvatarPhotoInputHandle) async throws -> SanitizedAvatarPhotoHandle {
    await probe.record(.sanitize)
    return try result.get()
  }
}

nonisolated private struct AnalyzerProbe: AvatarPhotoAnalyzing {
  let probe: PipelineProbe
  let result: Result<AvatarPhotoTechnicalSignals, any Error>

  func analyze(_ photo: SanitizedAvatarPhotoHandle) async throws -> AvatarPhotoTechnicalSignals {
    await probe.record(.analyze)
    return try result.get()
  }
}

nonisolated private struct CleanerProbe: AvatarPhotoSessionCleaning {
  let probe: PipelineProbe

  func removeSession(_ sessionID: UUID) async throws {
    try await probe.cleanup(sessionID)
  }
}
