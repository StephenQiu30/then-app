import Foundation
import Testing

@testable import ThenApp

@Suite("照片 POC 纯领域质量策略")
struct AvatarPhotoQualityPolicyTests {
  private func policy() throws -> AvatarPhotoQualityPolicy {
    try AvatarPhotoQualityPolicy(
      minimumFullPersonCoverage: 0.5,
      minimumVisibility: 0.5,
      minimumSharpness: 0.5,
      minimumExposureUsability: 0.5
    )
  }

  private func signals(
    failing reasons: Set<AvatarPhotoQualityReason> = [],
    personCount: Int? = 1,
    score: Double? = 1,
    scoreDimension: Int? = nil
  ) -> AvatarPhotoTechnicalSignals {
    var scores: [Double?] = [score, score, score, score]
    if let scoreDimension {
      scores = [1, 1, 1, 1]
      scores[scoreDimension] = score
    }
    return AvatarPhotoTechnicalSignals(
      formatSupported: !reasons.contains(.unsupportedFormat),
      inputSafe: !reasons.contains(.unsafeOrCorruptInput),
      withinResourceBudget: !reasons.contains(.resourceLimitExceeded),
      personCount: reasons.contains(.multiplePeople) ? 2
        : reasons.contains(.noPersonDetected) ? 0 : personCount,
      fullPersonCoverage: reasons.contains(.personNotFullyVisible) ? 0 : scores[0],
      visibility: reasons.contains(.personObscured) ? 0 : scores[1],
      sharpness: reasons.contains(.imageTooBlurry) ? 0 : scores[2],
      exposureUsability: reasons.contains(.imageExposureUnusable) ? 0 : scores[3],
      deviceCapabilityAvailable: !reasons.contains(.deviceCapabilityUnavailable),
      analysisSucceeded: !reasons.contains(.analysisFailed),
      hasQualityWarning: reasons.contains(.qualityWarning)
    )
  }

  @Test("合格结果无原因；提醒是独立可继续的结果")
  func validAndWarningResults() throws {
    let policy = try policy()
    let valid = policy.assess(signals())
    #expect(valid.outcome == .pass)
    #expect(valid.primaryReason == nil)
    #expect(valid.recoveryAction == .continueReview)
    let warning = policy.assess(signals(failing: [.qualityWarning]))
    #expect(warning.outcome == .passWithWarning)
    #expect(warning.primaryReason == .qualityWarning)
    #expect(warning.recoveryAction == .continueReview)
  }

  @Test("每种阻断都有确定的结果和恢复动作", arguments: [
    AvatarPhotoQualityReason.unsupportedFormat, .unsafeOrCorruptInput,
    .resourceLimitExceeded, .multiplePeople, .noPersonDetected,
    .personNotFullyVisible, .personObscured, .imageTooBlurry,
    .imageExposureUnusable, .deviceCapabilityUnavailable, .analysisFailed,
  ])
  func singleFailure(reason: AvatarPhotoQualityReason) throws {
    let assessment = try policy().assess(signals(failing: [reason]))
    #expect(assessment.primaryReason == reason)
    switch reason {
    case .unsupportedFormat, .unsafeOrCorruptInput, .resourceLimitExceeded:
      #expect(assessment.outcome == .unsupported)
      #expect(assessment.recoveryAction == .replacePhotoOrUseTemplate)
    case .deviceCapabilityUnavailable, .analysisFailed:
      #expect(assessment.outcome == .unsupported)
      #expect(assessment.recoveryAction == .retryOrUseTemplate)
    default:
      #expect(assessment.outcome == .needsReplacement)
      #expect(assessment.recoveryAction == .replacePhotoOrUseTemplate)
    }
  }

  @Test("多个失败只返回契约中的最高优先级原因")
  func allFailureCombinationsRespectPriority() throws {
    // This order is the approved 11-01 contract, independent of enum declaration order.
    let priority: [AvatarPhotoQualityReason] = [
      .unsupportedFormat, .unsafeOrCorruptInput, .resourceLimitExceeded,
      .multiplePeople, .noPersonDetected, .personNotFullyVisible,
      .personObscured, .imageTooBlurry, .imageExposureUnusable,
      .deviceCapabilityUnavailable, .analysisFailed, .qualityWarning,
    ]
    let policy = try policy()
    for mask in 1..<(1 << priority.count) {
      let failures = Set(priority.enumerated().compactMap { index, reason in
        mask & (1 << index) == 0 ? nil : reason
      })
      let result = policy.assess(signals(failing: failures))
      #expect(result.primaryReason == priority.first(where: failures.contains))
      #expect(result == policy.assess(signals(failing: failures)))
    }
  }

  @Test("每项阈值本身可通过，低于阈值必须拒绝", arguments: 0..<4)
  func thresholdBoundary(dimension: Int) throws {
    let policy = try policy()
    let expected: [AvatarPhotoQualityReason] = [
      .personNotFullyVisible, .personObscured, .imageTooBlurry, .imageExposureUnusable,
    ]
    #expect(policy.assess(signals(score: 0.5, scoreDimension: dimension)).outcome == .pass)
    #expect(policy.assess(signals(score: 0.5.nextDown, scoreDimension: dimension)).primaryReason == expected[dimension])
    #expect(policy.assess(signals(score: 0.5.nextUp, scoreDimension: dimension)).outcome == .pass)
  }

  @Test("缺失和无效分数不能被当作合格", arguments: [
    Double?.none, .some(.nan), .some(.infinity), .some(-.infinity), .some(-0.1), .some(1.1),
  ])
  func invalidSignal(score: Double?) throws {
    for dimension in 0..<4 {
      let result = try policy().assess(signals(score: score, scoreDimension: dimension))
      #expect(result.primaryReason == .analysisFailed)
      #expect(result.outcome == .unsupported)
    }
  }

  @Test("人员数未知或无效不能通过", arguments: [Int?.none, .some(-1)])
  func invalidPersonCount(count: Int?) throws {
    #expect(try policy().assess(signals(personCount: count)).primaryReason == .analysisFailed)
  }

  @Test("设备不可用时不把缺失信号当成零人；已知多人仍优先阻断")
  func unavailableAnalysis() throws {
    let policy = try policy()
    #expect(policy.assess(signals(failing: [.deviceCapabilityUnavailable], personCount: nil, score: nil))
      .primaryReason == .deviceCapabilityUnavailable)
    #expect(policy.assess(signals(failing: [.multiplePeople, .analysisFailed], score: nil))
      .primaryReason == .multiplePeople)
  }

  @Test("配置中所有阈值都必须是有限的归一化分数", arguments: [
    Double.nan, .infinity, -.infinity, -0.01, 1.01,
  ])
  func invalidThreshold(value: Double) {
    for index in 0..<4 {
      var thresholds = [0.5, 0.5, 0.5, 0.5]
      thresholds[index] = value
      #expect(throws: AvatarPhotoQualityPolicy.ConfigurationError.invalidThreshold) {
        try AvatarPhotoQualityPolicy(
          minimumFullPersonCoverage: thresholds[0], minimumVisibility: thresholds[1],
          minimumSharpness: thresholds[2], minimumExposureUsability: thresholds[3]
        )
      }
    }
  }

  @Test("临时句柄只保留随机身份与有效像素尺寸")
  func sanitizedHandle() throws {
    let sessionID = UUID()
    let handle = try SanitizedAvatarPhotoHandle(sessionID: sessionID, assetID: UUID(), width: 800, height: 1200)
    #expect(handle.sessionID == sessionID)
    #expect(handle.width == 800)
    #expect(handle.height == 1200)
    #expect(throws: SanitizedAvatarPhotoHandle.ValidationError.invalidDimensions) {
      try SanitizedAvatarPhotoHandle(sessionID: sessionID, assetID: UUID(), width: 0, height: 1200)
    }
  }

  @Test("策略可以在非 MainActor 任务调用")
  nonisolated func usableOutsideMainActor() async throws {
    let policy = try AvatarPhotoQualityPolicy(
      minimumFullPersonCoverage: 0.5, minimumVisibility: 0.5,
      minimumSharpness: 0.5, minimumExposureUsability: 0.5
    )
    let result = await withTaskGroup(of: AvatarPhotoQualityAssessment.self) { group in
      group.addTask {
        policy.assess(AvatarPhotoTechnicalSignals(
          formatSupported: true, inputSafe: true, withinResourceBudget: true,
          personCount: 1, fullPersonCoverage: 1, visibility: 1, sharpness: 1,
          exposureUsability: 1, deviceCapabilityAvailable: true,
          analysisSucceeded: true, hasQualityWarning: false
        ))
      }
      return await group.next()
    }
    #expect(result?.outcome == .pass)
  }
}
