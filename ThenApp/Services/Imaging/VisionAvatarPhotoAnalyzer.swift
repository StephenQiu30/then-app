import CoreGraphics
import Foundation
import ImageIO
import Vision

/// DEBUG POC adapter. It publishes only aggregate technical scores and never returns Vision observations.
nonisolated struct VisionAvatarPhotoAnalyzer: AvatarPhotoAnalyzing {
  nonisolated enum ComputeDevice: Sendable { case cpu, system }

  nonisolated enum ConfigurationError: Error { case invalidLimits }

  nonisolated struct PixelScores: Sendable, Equatable {
    let sharpness: Double
    let exposureUsability: Double
  }

  private enum Failure: Error {
    case unsupportedFormat, unsafeOrCorruptInput, resourceLimitExceeded
    case deviceCapabilityUnavailable, analysisFailed
  }

  private let store: AvatarPhotoTemporarySessionStore
  private let maximumBytes: Int
  private let maximumPixels: Int
  private let duration: Duration
  private let computeDevice: ComputeDevice

  init(
    store: AvatarPhotoTemporarySessionStore,
    maximumBytes: Int,
    maximumPixels: Int,
    duration: Duration,
    computeDevice: ComputeDevice
  ) throws {
    guard maximumBytes > 0, maximumPixels > 0, duration > .zero else {
      throw ConfigurationError.invalidLimits
    }
    self.store = store
    self.maximumBytes = maximumBytes
    self.maximumPixels = maximumPixels
    self.duration = duration
    self.computeDevice = computeDevice
  }

  @concurrent func analyze(_ photo: SanitizedAvatarPhotoHandle) async throws -> AvatarPhotoTechnicalSignals {
    let deadline = ContinuousClock.now.advanced(by: duration)
    do {
      try check(deadline)
      let reference = AvatarPhotoTemporarySessionStore.FileReference(
        sessionID: photo.sessionID, fileID: photo.assetID, purpose: .sanitizedPreview)
      let url = try await store.fileURL(for: reference)
      let checked = try checkedImage(at: url, expectedWidth: photo.width, expectedHeight: photo.height)
      let pixels = try Self.pixelScores(for: checked.image)
      let vision = try runVision(on: checked.data, deadline: deadline)
      return AvatarPhotoTechnicalSignals(
        formatSupported: true,
        inputSafe: true,
        withinResourceBudget: true,
        personCount: vision.personCount,
        fullPersonCoverage: vision.fullPersonCoverage,
        visibility: vision.visibility,
        sharpness: pixels.sharpness,
        exposureUsability: pixels.exposureUsability,
        deviceCapabilityAvailable: true,
        analysisSucceeded: vision.analysisSucceeded,
        hasQualityWarning: false
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch Failure.unsupportedFormat {
      return failedSignals(formatSupported: false)
    } catch Failure.unsafeOrCorruptInput {
      return failedSignals(inputSafe: false)
    } catch Failure.resourceLimitExceeded {
      return failedSignals(withinResourceBudget: false)
    } catch Failure.deviceCapabilityUnavailable {
      return failedSignals(deviceCapabilityAvailable: false)
    } catch {
      return failedSignals()
    }
  }

  static func pixelScores(for image: CGImage) throws -> PixelScores {
    let maximumDimension = 128
    let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    var luminance = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(
      data: &luminance,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { throw Failure.analysisFailed }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let count = Double(luminance.count)
    let mean = luminance.reduce(0.0) { $0 + Double($1) / 255 } / count
    let usable = Double(luminance.count { (8...247).contains($0) }) / count
    let meanExposure = min(1, min(mean / 0.15, (1 - mean) / 0.15))
    let exposure = Self.clamp(min(meanExposure, usable / 0.6))

    var edgeTotal = 0.0
    var edgeCount = 0
    for y in 0..<height {
      for x in 0..<width {
        let index = y * width + x
        if x > 0 {
          edgeTotal += abs(Double(luminance[index]) - Double(luminance[index - 1])) / 255
          edgeCount += 1
        }
        if y > 0 {
          edgeTotal += abs(Double(luminance[index]) - Double(luminance[index - width])) / 255
          edgeCount += 1
        }
      }
    }
    guard edgeCount > 0 else { throw Failure.analysisFailed }
    let sharpness = Self.clamp(edgeTotal / Double(edgeCount) / 0.04)
    return PixelScores(sharpness: sharpness, exposureUsability: exposure)
  }

  private func checkedImage(
    at url: URL, expectedWidth: Int, expectedHeight: Int
  ) throws -> (data: Data, image: CGImage) {
    guard url.isFileURL else { throw Failure.unsafeOrCorruptInput }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard !data.isEmpty else { throw Failure.unsafeOrCorruptInput }
    guard data.count <= maximumBytes else { throw Failure.resourceLimitExceeded }
    guard let source = CGImageSourceCreateWithData(
      data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
    ) else { throw Failure.unsafeOrCorruptInput }
    guard CGImageSourceGetType(source) as String? == AvatarPhotoInputFormat.png.rawValue else {
      throw Failure.unsupportedFormat
    }
    guard CGImageSourceGetCount(source) == 1,
          CGImageSourceGetStatus(source) == .statusComplete,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width == expectedWidth,
          height == expectedHeight,
          width > 0,
          height > 0,
          (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    else { throw Failure.unsafeOrCorruptInput }
    guard width <= maximumPixels / height else { throw Failure.resourceLimitExceeded }
    guard let image = CGImageSourceCreateImageAtIndex(
      source, 0, [kCGImageSourceShouldCache: true] as CFDictionary
    ) else { throw Failure.unsafeOrCorruptInput }
    return (data, image)
  }

  private func runVision(
    on data: Data, deadline: ContinuousClock.Instant
  ) throws -> (personCount: Int, fullPersonCoverage: Double?, visibility: Double?, analysisSucceeded: Bool) {
    guard VNDetectHumanRectanglesRequest.supportedRevisions.contains(VNDetectHumanRectanglesRequestRevision2),
          VNDetectHumanBodyPoseRequest.supportedRevisions.contains(VNDetectHumanBodyPoseRequestRevision1)
    else { throw Failure.deviceCapabilityUnavailable }

    let people = VNDetectHumanRectanglesRequest()
    people.revision = VNDetectHumanRectanglesRequestRevision2
    people.upperBodyOnly = true
    let pose = VNDetectHumanBodyPoseRequest()
    pose.revision = VNDetectHumanBodyPoseRequestRevision1
    do {
      try configure(people)
      try configure(pose)
      try check(deadline)
      try VNImageRequestHandler(data: data, orientation: .up, options: [:]).perform([people, pose])
      try check(deadline)
      guard let peopleResults = people.results, let poseResults = pose.results else {
        throw Failure.analysisFailed
      }
      let count = peopleResults.count
      guard count == 1 else {
        return (count, nil, nil, true)
      }
      guard let observation = poseResults.first else {
        return (count, nil, nil, false)
      }
      let points = try observation.recognizedPoints(.all)
      let required: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftShoulder, .rightShoulder, .leftHip, .rightHip,
        .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
      ]
      let confidences = required.map { Double(points[$0]?.confidence ?? 0) }
      let visible = confidences.count { $0 >= 0.3 }
      let coverage = Double(visible) / Double(required.count)
      let visibility = confidences.reduce(0, +) / Double(required.count)
      return (count, Self.clamp(coverage), Self.clamp(visibility), true)
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.deviceCapabilityUnavailable
    }
  }

  private func configure(_ request: VNRequest) throws {
    guard computeDevice == .cpu else { return }
    let stages = try request.supportedComputeStageDevices
    guard !stages.isEmpty else { throw Failure.deviceCapabilityUnavailable }
    for (stage, devices) in stages {
      guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
        throw Failure.deviceCapabilityUnavailable
      }
      request.setComputeDevice(cpu, for: stage)
    }
  }

  private func failedSignals(
    formatSupported: Bool = true,
    inputSafe: Bool = true,
    withinResourceBudget: Bool = true,
    deviceCapabilityAvailable: Bool = true
  ) -> AvatarPhotoTechnicalSignals {
    AvatarPhotoTechnicalSignals(
      formatSupported: formatSupported,
      inputSafe: inputSafe,
      withinResourceBudget: withinResourceBudget,
      personCount: nil,
      fullPersonCoverage: nil,
      visibility: nil,
      sharpness: nil,
      exposureUsability: nil,
      deviceCapabilityAvailable: deviceCapabilityAvailable,
      analysisSucceeded: false,
      hasQualityWarning: false
    )
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Failure.resourceLimitExceeded }
  }

  private static func clamp(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
  }
}
