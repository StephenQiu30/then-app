/// POC thresholds must be supplied by the caller; there are no production defaults.
nonisolated struct AvatarPhotoQualityPolicy: Sendable {
  nonisolated enum ConfigurationError: Error {
    case invalidThreshold
  }

  let minimumFullPersonCoverage: Double
  let minimumVisibility: Double
  let minimumSharpness: Double
  let minimumExposureUsability: Double

  init(
    minimumFullPersonCoverage: Double,
    minimumVisibility: Double,
    minimumSharpness: Double,
    minimumExposureUsability: Double
  ) throws {
    let thresholds = [minimumFullPersonCoverage, minimumVisibility, minimumSharpness, minimumExposureUsability]
    guard thresholds.allSatisfy(Self.isValidScore) else {
      throw ConfigurationError.invalidThreshold
    }
    self.minimumFullPersonCoverage = minimumFullPersonCoverage
    self.minimumVisibility = minimumVisibility
    self.minimumSharpness = minimumSharpness
    self.minimumExposureUsability = minimumExposureUsability
  }

  func assess(_ signals: AvatarPhotoTechnicalSignals) -> AvatarPhotoQualityAssessment {
    AvatarPhotoQualityAssessment(primaryReason: primaryReason(for: signals))
  }

  private func primaryReason(for signals: AvatarPhotoTechnicalSignals) -> AvatarPhotoQualityReason? {
    // Order is part of the 11-01 contract. A lower-priority failure cannot hide a known privacy risk.
    if !signals.formatSupported { return .unsupportedFormat }
    if !signals.inputSafe { return .unsafeOrCorruptInput }
    if !signals.withinResourceBudget { return .resourceLimitExceeded }
    if let count = signals.personCount, count > 1 { return .multiplePeople }
    if signals.personCount == 0 { return .noPersonDetected }
    if belowThreshold(signals.fullPersonCoverage, minimumFullPersonCoverage) { return .personNotFullyVisible }
    if belowThreshold(signals.visibility, minimumVisibility) { return .personObscured }
    if belowThreshold(signals.sharpness, minimumSharpness) { return .imageTooBlurry }
    if belowThreshold(signals.exposureUsability, minimumExposureUsability) { return .imageExposureUnusable }
    if !signals.deviceCapabilityAvailable { return .deviceCapabilityUnavailable }

    let scores = [signals.fullPersonCoverage, signals.visibility, signals.sharpness, signals.exposureUsability]
    guard signals.analysisSucceeded,
          let count = signals.personCount, count >= 0,
          scores.allSatisfy({ value in value.map(Self.isValidScore) == true })
    else { return .analysisFailed }
    return signals.hasQualityWarning ? .qualityWarning : nil
  }

  private func belowThreshold(_ value: Double?, _ threshold: Double) -> Bool {
    guard let value, Self.isValidScore(value) else { return false }
    return value < threshold
  }

  private static func isValidScore(_ value: Double) -> Bool {
    value.isFinite && (0...1).contains(value)
  }
}
