import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ImageIOAvatarPhotoSanitizer: AvatarPhotoSanitizing {
  nonisolated enum Failure: Error {
    case unsupportedFormat, unsafeOrCorruptInput, resourceLimitExceeded
    case storageUnavailable, cleanupFailed
  }

  nonisolated enum ConfigurationError: Error { case invalidLimits }

  nonisolated struct Limits: Sendable {
    let maximumInputBytes: Int
    let maximumSourcePixels: Int
    let maximumOutputDimension: Int
    let maximumRasterBytes: Int
    let maximumOutputBytes: Int
    let maximumDuration: Duration

    init(maximumInputBytes: Int, maximumSourcePixels: Int, maximumOutputDimension: Int,
         maximumRasterBytes: Int, maximumOutputBytes: Int, maximumDuration: Duration) throws {
      guard maximumInputBytes > 0, maximumSourcePixels > 0, maximumOutputDimension > 0,
            maximumRasterBytes > 0, maximumOutputBytes > 0, maximumDuration > .zero,
            maximumOutputDimension <= maximumRasterBytes / 4 / maximumOutputDimension
      else { throw ConfigurationError.invalidLimits }
      self.maximumInputBytes = maximumInputBytes
      self.maximumSourcePixels = maximumSourcePixels
      self.maximumOutputDimension = maximumOutputDimension
      self.maximumRasterBytes = maximumRasterBytes
      self.maximumOutputBytes = maximumOutputBytes
      self.maximumDuration = maximumDuration
    }
  }

  private let store: AvatarPhotoTemporarySessionStore
  private let limits: Limits

  init(store: AvatarPhotoTemporarySessionStore, limits: Limits) {
    self.store = store
    self.limits = limits
  }

  @concurrent func sanitize(_ input: AvatarPhotoInputHandle) async throws -> SanitizedAvatarPhotoHandle {
    let deadline = ContinuousClock.now.advanced(by: limits.maximumDuration)
    do {
      try check(deadline)
      let original = AvatarPhotoTemporarySessionStore.FileReference(
        sessionID: input.sessionID, fileID: input.inputID, purpose: .originalImport)
      let inputURL = try await store.fileURL(for: original)
      let source = try checkedSource(at: inputURL, format: input.format)
      try check(deadline)
      let output = try await store.createFile(in: input.sessionID, purpose: .sanitizedPreview)
      let outputURL = try await store.fileURL(for: output)
      let dimensions = try encodeNormalized(source, to: outputURL, deadline: deadline)
      try check(deadline)
      let size = try FileManager().attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
      guard let size, size.uint64Value > 0, size.uint64Value <= UInt64(limits.maximumOutputBytes)
      else { throw Failure.resourceLimitExceeded }
      try stripEncodedMetadata(at: outputURL)
      try check(deadline)
      try await store.finishWriting(output)
      // No usable result is returned until the imported original has actually been removed.
      try await store.removeFile(original)
      try check(deadline)
      return try SanitizedAvatarPhotoHandle(sessionID: input.sessionID, assetID: output.fileID,
        width: dimensions.width, height: dimensions.height)
    } catch {
      do { try await store.removeSession(input.sessionID) }
      catch { throw Failure.cleanupFailed }
      if error is CancellationError { throw CancellationError() }
      if let failure = error as? Failure { throw failure }
      throw Failure.storageUnavailable
    }
  }

  /// Reusable by the file importer before it copies the provider's bytes into the private session.
  func validateInput(at url: URL, format: AvatarPhotoInputFormat) throws {
    _ = try checkedSource(at: url, format: format)
  }

  private func checkedSource(at url: URL, format: AvatarPhotoInputFormat) throws -> CGImageSource {
    guard url.isFileURL else { throw Failure.unsafeOrCorruptInput }
    let attributes: [FileAttributeKey: Any]
    let header: Data
    do {
      attributes = try FileManager().attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.referenceCount] as? NSNumber)?.intValue == 1
      else { throw Failure.unsafeOrCorruptInput }
      guard let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else {
        throw Failure.unsafeOrCorruptInput
      }
      guard size.uint64Value <= UInt64(limits.maximumInputBytes) else { throw Failure.resourceLimitExceeded }
      let file = try FileHandle(forReadingFrom: url)
      do {
        header = try file.read(upToCount: 33) ?? Data()
        try file.close()
      } catch {
        // Preserve the input error; the owning session is removed by sanitize's error path.
        try? file.close()
        throw error
      }
    } catch let failure as Failure { throw failure }
    catch { throw Failure.unsafeOrCorruptInput }

    try rejectOversizedPNGHeader(header, format: format)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let type = CGImageSourceGetType(source) as String?
    else { throw Failure.unsafeOrCorruptInput }
    guard AvatarPhotoInputFormat(rawValue: type) != nil else { throw Failure.unsupportedFormat }
    guard type == format.rawValue, headerMatches(header, format: format) else { throw Failure.unsafeOrCorruptInput }
    guard CGImageSourceGetCount(source) == 1 else { throw Failure.unsupportedFormat }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
      as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0 else { throw Failure.unsafeOrCorruptInput }
    guard width <= limits.maximumSourcePixels / height else { throw Failure.resourceLimitExceeded }
    guard CGImageSourceGetStatus(source) == .statusComplete else { throw Failure.unsafeOrCorruptInput }
    return source
  }

  /// ImageIO may inspect compressed payloads while loading properties. Reject a PNG whose
  /// fixed IHDR dimensions already exceed our budget before handing it to ImageIO.
  private func rejectOversizedPNGHeader(_ header: Data, format: AvatarPhotoInputFormat) throws {
    guard format == .png, header.count >= 24,
          header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
          header.subdata(in: 8..<12) == Data([0, 0, 0, 13]),
          header.subdata(in: 12..<16) == Data("IHDR".utf8)
    else { return }
    let width = header[16..<20].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    let height = header[20..<24].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    guard width > 0, height > 0 else { throw Failure.unsafeOrCorruptInput }
    guard width <= UInt64(limits.maximumSourcePixels) / height else {
      throw Failure.resourceLimitExceeded
    }
  }

  private func headerMatches(_ header: Data, format: AvatarPhotoInputFormat) -> Bool {
    switch format {
    case .jpeg: return header.starts(with: [0xFF, 0xD8, 0xFF])
    case .png: return header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    case .heic:
      // ISO BMFF family marker plus ImageIO's independently detected public.heic type above.
      return header.count >= 12 && header.subdata(in: 4..<8) == Data("ftyp".utf8)
    }
  }

  private func encodeNormalized(_ source: CGImageSource, to url: URL,
                                deadline: ContinuousClock.Instant) throws -> (width: Int, height: Int) {
    try check(deadline)
    let options: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: limits.maximumOutputDimension,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw Failure.unsafeOrCorruptInput
    }
    try check(deadline)
    let width = thumbnail.width, height = thumbnail.height
    guard width > 0, height > 0,
          width <= limits.maximumOutputDimension, height <= limits.maximumOutputDimension,
          width <= limits.maximumRasterBytes / 4 / height else { throw Failure.resourceLimitExceeded }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure.resourceLimitExceeded }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let normalized = context.makeImage() else { throw Failure.resourceLimitExceeded }
    try check(deadline)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw Failure.storageUnavailable }
    // The new bitmap has no source metadata. Do not forward even a filtered source dictionary.
    CGImageDestinationAddImage(destination, normalized, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure.storageUnavailable }
    try check(deadline)
    return (width, height)
  }

  private func stripEncodedMetadata(at url: URL) throws {
    let encoded = try Data(contentsOf: url)
    guard encoded.count <= limits.maximumOutputBytes else { throw Failure.resourceLimitExceeded }
    let clean: Data
    do { clean = try PixelOnlyPNG.clean(encoded) }
    catch { throw Failure.unsafeOrCorruptInput }
    try clean.write(to: url, options: .completeFileProtection)
  }

  private func check(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else { throw Failure.resourceLimitExceeded }
  }
}
