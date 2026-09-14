import Foundation

nonisolated enum AvatarPhotoIntakeState: Sendable, Equatable {
  case disclosure
  case awaitingSelection
  case importing
  case sanitizing
  case analyzing
  case review(SanitizedAvatarPhotoHandle, AvatarPhotoQualityAssessment)
  case replacement(AvatarPhotoQualityAssessment)
  case unsupported(AvatarPhotoQualityAssessment)
  case recoverableFailure(AvatarPhotoQualityReason)
  case templateFallback
}

nonisolated struct AvatarPhotoInputHandle: Sendable, Equatable {
  let sessionID: UUID
  let inputID: UUID
  let format: AvatarPhotoInputFormat
}

nonisolated enum AvatarPhotoInputFormat: String, Sendable {
  case jpeg = "public.jpeg"
  case png = "public.png"
  case heic = "public.heic"
}

nonisolated protocol AvatarPhotoSanitizing: Sendable {
  func sanitize(_ input: AvatarPhotoInputHandle) async throws -> SanitizedAvatarPhotoHandle
}

nonisolated struct SanitizedAvatarPhotoHandle: Sendable, Equatable {
  nonisolated enum ValidationError: Error {
    case invalidDimensions
  }

  let sessionID: UUID
  let assetID: UUID
  let width: Int
  let height: Int

  init(sessionID: UUID, assetID: UUID, width: Int, height: Int) throws {
    guard width > 0, height > 0 else { throw ValidationError.invalidDimensions }
    self.sessionID = sessionID
    self.assetID = assetID
    self.width = width
    self.height = height
  }
}

/// Ephemeral technical measurements. Missing measurements are unknown, never a passing default.
/// Scores use the adapter's normalized 0...1 scale, not physical or personal attributes.
nonisolated struct AvatarPhotoTechnicalSignals: Sendable {
  let formatSupported: Bool
  let inputSafe: Bool
  let withinResourceBudget: Bool
  let personCount: Int?
  let fullPersonCoverage: Double?
  let visibility: Double?
  let sharpness: Double?
  let exposureUsability: Double?
  let deviceCapabilityAvailable: Bool
  let analysisSucceeded: Bool
  let hasQualityWarning: Bool
}

nonisolated enum AvatarPhotoQualityReason: String, Sendable {
  case unsupportedFormat = "unsupported_format"
  case unsafeOrCorruptInput = "unsafe_or_corrupt_input"
  case resourceLimitExceeded = "resource_limit_exceeded"
  case multiplePeople = "multiple_people"
  case noPersonDetected = "no_person_detected"
  case personNotFullyVisible = "person_not_fully_visible"
  case personObscured = "person_obscured"
  case imageTooBlurry = "image_too_blurry"
  case imageExposureUnusable = "image_exposure_unusable"
  case deviceCapabilityUnavailable = "device_capability_unavailable"
  case analysisFailed = "analysis_failed"
  case qualityWarning = "quality_warning"
}

nonisolated struct AvatarPhotoQualityAssessment: Sendable, Equatable {
  nonisolated enum Outcome: String, Sendable {
    case pass
    case passWithWarning = "pass_with_warning"
    case needsReplacement = "needs_replacement"
    case unsupported
  }

  nonisolated enum RecoveryAction: Sendable {
    case continueReview
    case replacePhotoOrUseTemplate
    case retryOrUseTemplate
  }

  let primaryReason: AvatarPhotoQualityReason?

  var outcome: Outcome {
    switch primaryReason {
    case nil: .pass
    case .qualityWarning: .passWithWarning
    case .unsupportedFormat, .unsafeOrCorruptInput, .resourceLimitExceeded,
         .deviceCapabilityUnavailable, .analysisFailed: .unsupported
    default: .needsReplacement
    }
  }

  var recoveryAction: RecoveryAction {
    switch primaryReason {
    case nil, .qualityWarning: .continueReview
    case .deviceCapabilityUnavailable, .analysisFailed: .retryOrUseTemplate
    default: .replacePhotoOrUseTemplate
    }
  }
}
