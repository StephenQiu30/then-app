import Foundation
import ImageIO
import Vision

nonisolated struct VisionWardrobePersonAnalyzer: WardrobePhotoPersonAnalyzing {
  enum ComputeDevice: Sendable { case cpu, system }
  enum Failure: Error {
    case invalidLimits, invalidInput, resourceLimitExceeded, unsupportedDevice, unavailable
  }
  private let maximumBytes: Int
  private let maximumPixels: Int
  private let duration: Duration
  private let computeDevice: ComputeDevice

  init(maximumBytes: Int, maximumPixels: Int, duration: Duration, computeDevice: ComputeDevice) throws {
    guard maximumBytes > 0, maximumPixels > 0, duration > .zero else { throw Failure.invalidLimits }
    self.maximumBytes = maximumBytes
    self.maximumPixels = maximumPixels
    self.duration = duration
    self.computeDevice = computeDevice
  }

  @concurrent func analyze(_ image: WardrobeEncodedImage) async throws -> WardrobePhotoPersonObservations {
    let deadline = ContinuousClock.now.advanced(by: duration)
    try check(deadline)
    guard image.bytes.count <= maximumBytes else { throw Failure.resourceLimitExceeded }
    guard image.format == .png,
          let source = CGImageSourceCreateWithData(image.bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetType(source) as String? == "public.png",
          CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width == image.width, height == image.height, width > 0, height > 0,
          (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw Failure.invalidInput }
    guard width <= maximumPixels / height else { throw Failure.resourceLimitExceeded }
    guard VNDetectHumanRectanglesRequest.supportedRevisions.contains(VNDetectHumanRectanglesRequestRevision2),
          VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) else {
      throw Failure.unavailable
    }
    let people = VNDetectHumanRectanglesRequest()
    people.revision = VNDetectHumanRectanglesRequestRevision2
    people.upperBodyOnly = true
    let faces = VNDetectFaceRectanglesRequest()
    faces.revision = VNDetectFaceRectanglesRequestRevision3
    do {
      try configure(people)
      try configure(faces)
      let handler = VNImageRequestHandler(data: image.bytes, orientation: .up, options: [:])
      try check(deadline)
      try handler.perform([people])
      try check(deadline)
      try handler.perform([faces])
      try check(deadline)
      guard let peopleResult = people.results, let faceResult = faces.results else { throw Failure.unavailable }
      return try WardrobePhotoPersonObservations(people: peopleResult.count, faces: faceResult.count)
    } catch is CancellationError { throw CancellationError() }
    catch let error as Failure { throw error }
    catch { throw Failure.unavailable }
  }

  private func configure(_ request: VNRequest) throws {
    guard computeDevice == .cpu else { return }
    let stages = try request.supportedComputeStageDevices
    guard !stages.isEmpty else { throw Failure.unsupportedDevice }
    for (stage, devices) in stages {
      guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
        throw Failure.unsupportedDevice
      }
      request.setComputeDevice(cpu, for: stage)
    }
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Failure.resourceLimitExceeded }
  }
}
