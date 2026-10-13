import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ImageIOWardrobePhotoPreparer: WardrobePhotoPreparing {
  enum Failure: Error { case invalidLimits, unsupportedFormat, unsafeInput, resourceLimitExceeded, encodingFailed }

  struct Limits: Sendable {
    let inputBytes: Int
    let sourcePixels: Int
    let normalizedDimension: Int
    let thumbnailDimension: Int
    let rasterBytes: Int
    let normalizedBytes: Int
    let thumbnailBytes: Int
    let duration: Duration

    init(inputBytes: Int, sourcePixels: Int, normalizedDimension: Int, thumbnailDimension: Int,
         rasterBytes: Int, normalizedBytes: Int, thumbnailBytes: Int, duration: Duration) throws {
      guard inputBytes > 0, sourcePixels > 0, normalizedDimension > 0, thumbnailDimension > 0,
            thumbnailDimension <= normalizedDimension, rasterBytes > 0,
            normalizedDimension <= rasterBytes / 4 / normalizedDimension,
            normalizedBytes > 0, thumbnailBytes > 0, duration > .zero else { throw Failure.invalidLimits }
      self.inputBytes = inputBytes
      self.sourcePixels = sourcePixels
      self.normalizedDimension = normalizedDimension
      self.thumbnailDimension = thumbnailDimension
      self.rasterBytes = rasterBytes
      self.normalizedBytes = normalizedBytes
      self.thumbnailBytes = thumbnailBytes
      self.duration = duration
    }
  }

  let limits: Limits

  @concurrent func prepare(_ bytes: Data, format: WardrobePhotoSourceFormat) async throws -> WardrobePreparedPhoto {
    let deadline = ContinuousClock.now.advanced(by: limits.duration)
    try check(deadline)
    guard !bytes.isEmpty else { throw Failure.unsafeInput }
    guard bytes.count <= limits.inputBytes else { throw Failure.resourceLimitExceeded }
    guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let type = CGImageSourceGetType(source) as String? else { throw Failure.unsafeInput }
    guard WardrobePhotoSourceFormat(rawValue: type) != nil else { throw Failure.unsupportedFormat }
    guard type == format.rawValue, signatureMatches(bytes, format) else { throw Failure.unsafeInput }
    guard CGImageSourceGetCount(source) == 1 else { throw Failure.unsupportedFormat }
    guard CGImageSourceGetStatus(source) == .statusComplete,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else { throw Failure.unsafeInput }
    guard width <= limits.sourcePixels / height else { throw Failure.resourceLimitExceeded }
    try check(deadline)
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false,
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(limits.normalizedDimension, max(width, height))]
    guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.unsafeInput }
    try check(deadline)
    let normalized = try raster(decoded, dimension: limits.normalizedDimension)
    let full = try encode(normalized, maximumBytes: limits.normalizedBytes, deadline: deadline)
    try check(deadline)
    let thumbnail = try raster(normalized, dimension: limits.thumbnailDimension)
    let small = try encode(thumbnail, maximumBytes: limits.thumbnailBytes, deadline: deadline)
    try check(deadline)
    return WardrobePreparedPhoto(normalized: full, thumbnail: small)
  }

  private func raster(_ image: CGImage, dimension: Int) throws -> CGImage {
    let scale = min(1, Double(dimension) / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard width <= dimension, height <= dimension, width <= limits.rasterBytes / 4 / height,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure.resourceLimitExceeded }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw Failure.resourceLimitExceeded }
    return result
  }

  private func encode(_ image: CGImage, maximumBytes: Int, deadline: ContinuousClock.Instant) throws -> WardrobeEncodedImage {
    try check(deadline)
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
      throw Failure.encodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
    try check(deadline)
    guard encoded.length <= maximumBytes else { throw Failure.resourceLimitExceeded }
    let clean: Data
    do { clean = try PixelOnlyPNG.clean(encoded as Data) }
    catch { throw Failure.encodingFailed }
    return try WardrobeEncodedImage(bytes: clean, format: .png, width: image.width,
                                    height: image.height, maximumBytes: maximumBytes)
  }

  private func signatureMatches(_ bytes: Data, _ format: WardrobePhotoSourceFormat) -> Bool {
    switch format {
    case .jpeg: bytes.starts(with: [0xff, 0xd8, 0xff])
    case .png: bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    case .heic: bytes.count >= 12 && bytes.dropFirst(4).prefix(4).elementsEqual("ftyp".utf8)
    }
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Failure.resourceLimitExceeded }
  }
}
