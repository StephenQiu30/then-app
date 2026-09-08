import AVFoundation
import Foundation
import Vision

nonisolated struct VisionReceiptOCRService: ReceiptOCRService {
  private let parser: ReceiptOCRParser

  init(parser: ReceiptOCRParser = ReceiptOCRParser()) {
    self.parser = parser
  }

  func recognizeReceipt(
    imageData: Data,
    referenceDate: Date,
    baseCurrencyCode: CurrencyCode
  ) async throws -> ReceiptOCRCandidate {
    guard !imageData.isEmpty else { throw ReceiptOCRError.emptyImage }

    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.usesLanguageCorrection = true

    let observations = try await request.perform(on: imageData)
    try Task.checkCancellation()
    let lines =
      observations
      .compactMap { observation -> (ReceiptOCRLine, CGFloat, CGFloat)? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return (
          ReceiptOCRLine(text: candidate.string, confidence: candidate.confidence),
          observation.topLeft.y,
          observation.topLeft.x
        )
      }
      .sorted { left, right in
        if abs(left.1 - right.1) > 0.015 {
          return left.1 > right.1
        }
        return left.2 < right.2
      }
      .map(\.0)

    return try parser.parse(
      lines: lines,
      referenceDate: referenceDate,
      baseCurrencyCode: baseCurrencyCode
    )
  }
}

nonisolated struct AVReceiptCameraAccessService: ReceiptCameraAccessService {
  func requestAccess() async -> ReceiptCameraAccess {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return .allowed
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
    case .denied, .restricted:
      return .denied
    @unknown default:
      return .denied
    }
  }
}
