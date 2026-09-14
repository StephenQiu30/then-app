import Foundation
import Vision

/// Test-only capability probe. Never delivers masks, face boxes or person observations to the product.
nonisolated struct WardrobeVisionProbe {
  enum Request: String, CaseIterable, Sendable { case people, faces, foreground }
  enum Failure: Error { case invalidInput, unsupportedRevision, missingResult, unsupportedCPUStage }

  @concurrent static func count(_ request: Request, png: Data, cpuOnly: Bool = false) async throws -> Int {
    try Task.checkCancellation()
    guard !png.isEmpty, png.count <= 4 * 1024 * 1024 else { throw Failure.invalidInput }
    let handler = VNImageRequestHandler(data: png, orientation: .up, options: [:])
    switch request {
    case .people:
      guard VNDetectHumanRectanglesRequest.supportedRevisions.contains(VNDetectHumanRectanglesRequestRevision2) else {
        throw Failure.unsupportedRevision
      }
      let detection = VNDetectHumanRectanglesRequest()
      detection.revision = VNDetectHumanRectanglesRequestRevision2
      detection.upperBodyOnly = true
      try configure(detection, cpuOnly: cpuOnly)
      try handler.perform([detection])
      try Task.checkCancellation()
      guard let results = detection.results else { throw Failure.missingResult }
      return results.count
    case .faces:
      guard VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) else {
        throw Failure.unsupportedRevision
      }
      let detection = VNDetectFaceRectanglesRequest()
      detection.revision = VNDetectFaceRectanglesRequestRevision3
      try configure(detection, cpuOnly: cpuOnly)
      try handler.perform([detection])
      try Task.checkCancellation()
      guard let results = detection.results else { throw Failure.missingResult }
      return results.count
    case .foreground:
      guard VNGenerateForegroundInstanceMaskRequest.supportedRevisions.contains(VNGenerateForegroundInstanceMaskRequestRevision1) else {
        throw Failure.unsupportedRevision
      }
      let detection = VNGenerateForegroundInstanceMaskRequest()
      detection.revision = VNGenerateForegroundInstanceMaskRequestRevision1
      try configure(detection, cpuOnly: cpuOnly)
      try handler.perform([detection])
      try Task.checkCancellation()
      guard let result = detection.results?.first else { throw Failure.missingResult }
      return result.allInstances.count
    }
  }

  private static func configure(_ request: VNRequest, cpuOnly: Bool) throws {
    guard cpuOnly else { return }
    // Explicit diagnostic mode, not an automatic runtime fallback or product policy.
    let stages = try request.supportedComputeStageDevices
    guard !stages.isEmpty else { throw Failure.unsupportedCPUStage }
    for (stage, devices) in stages {
      guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
        throw Failure.unsupportedCPUStage
      }
      request.setComputeDevice(cpu, for: stage)
    }
  }
}
