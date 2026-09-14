import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ThenApp

@Suite("单件衣物图编码与真实媒体存储")
struct WardrobePhotoPreparerTests {
  typealias Preparer = ImageIOWardrobePhotoPreparer

  private func limits(input: Int = 1_000_000, pixels: Int = 100_000, full: Int = 1_000_000,
                      small: Int = 100_000, duration: Duration = .seconds(5)) throws -> Preparer.Limits {
    try Preparer.Limits(inputBytes: input, sourcePixels: pixels, normalizedDimension: 160,
      thumbnailDimension: 40, rasterBytes: 160 * 160 * 4, normalizedBytes: full,
      thumbnailBytes: small, duration: duration)
  }

  // Original geometric T-shirt with asymmetric red sleeve; no persons, brands, or private data.
  private func fixture(type: String = "public.png", orientation: Int = 1, frames: Int = 1) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8,
      bytesPerRow: 240 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0.2, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 65, y: 40, width: 110, height: 210))
    context.fill(CGRect(x: 25, y: 190, width: 190, height: 60))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 25, y: 190, width: 35, height: 60))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
    var metadata: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "SYNTHETIC-source-name"],
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0, kCGImagePropertyGPSLatitudeRef: "N"],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SYNTHETIC-camera"],
      kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "SYNTHETIC-caption"]]
    if frames > 1 { metadata[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: 0.1] }
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, metadata as CFDictionary) }
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func inspect(_ encoded: WardrobeEncodedImage) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(encoded.bytes as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.png")
    #expect(CGImageSourceGetCount(source) == 1)
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] { #expect(properties[key] == nil) }
    #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    #expect(encoded.bytes.range(of: Data("SYNTHETIC".utf8)) == nil)
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == encoded.width && image.height == encoded.height)
    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    return image
  }

  @Test("三种输入从像素重编码为同向两图，不传递原始元数据", arguments: [
    WardrobePhotoSourceFormat.png, .jpeg, .heic])
  func formats(_ format: WardrobePhotoSourceFormat) async throws {
    let bytes = try fixture(type: format.rawValue, orientation: 6)
    let result = try await Preparer(limits: limits()).prepare(bytes, format: format)
    #expect(result.normalized.width == 160 && result.normalized.height == 120)
    #expect(result.thumbnail.width == 40 && result.thumbnail.height == 30)
    _ = try inspect(result.normalized)
    _ = try inspect(result.thumbnail)
  }

  @Test("全部八种 EXIF 方向保留比例且归一化", arguments: 1...8)
  func orientations(_ orientation: Int) async throws {
    let result = try await Preparer(limits: limits()).prepare(fixture(orientation: orientation), format: .png)
    #expect(result.normalized.width == (orientation > 4 ? 160 : 120))
    #expect(result.normalized.height == (orientation > 4 ? 120 : 160))
    _ = try inspect(result.normalized)
  }

  private func rgba(_ image: CGImage) throws -> [UInt8] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pointer = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
    return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4))
  }

  @Test("透明背景落在白底，镜像会改变不对称袖子像素")
  func pixelsAndMirror() async throws {
    let processor = try Preparer(limits: limits())
    let ordinary = try await processor.prepare(fixture(), format: .png)
    let mirrored = try await processor.prepare(fixture(orientation: 2), format: .png)
    let image = try inspect(ordinary.normalized), other = try inspect(mirrored.normalized)
    let pixels = try rgba(image), mirror = try rgba(other)
    #expect(Array(pixels.prefix(4)) == [255, 255, 255, 255])
    #expect(pixels != mirror)
    for y in stride(from: 0, to: image.height, by: 13) {
      for x in stride(from: 0, to: image.width, by: 11) {
        let i = (y * image.width + x) * 4
        let j = (y * image.width + image.width - x - 1) * 4
        for channel in 0..<4 { #expect(abs(Int(pixels[i + channel]) - Int(mirror[j + channel])) <= 3) }
      }
    }
  }

  @Test("八种方向的非对称袖子按 EXIF 规则变换，而非仅交换宽高", arguments: 1...8)
  func orientationPixels(_ orientation: Int) async throws {
    let processor = try Preparer(limits: limits())
    let baseline = try await processor.prepare(fixture(), format: .png)
    let transformed = try await processor.prepare(fixture(orientation: orientation), format: .png)
    let baseImage = try inspect(baseline.normalized), output = try inspect(transformed.normalized)
    let base = try rgba(baseImage), pixels = try rgba(output)
    let width = baseImage.width, height = baseImage.height
    for y in stride(from: 5, to: output.height, by: 17) {
      for x in stride(from: 5, to: output.width, by: 19) {
        let point: (Int, Int) = switch orientation {
        case 2: (width - x - 1, y)
        case 3: (width - x - 1, height - y - 1)
        case 4: (x, height - y - 1)
        case 5: (y, x)
        case 6: (y, height - x - 1)
        case 7: (width - y - 1, height - x - 1)
        case 8: (width - y - 1, x)
        default: (x, y)
        }
        let target = (y * output.width + x) * 4
        let origin = (point.1 * width + point.0) * 4
        for channel in 0..<4 { #expect(abs(Int(pixels[target + channel]) - Int(base[origin + channel])) <= 3) }
      }
    }
  }

  @Test("源图低于预算时不会人为放大")
  func noUpscaling() async throws {
    let config = try Preparer.Limits(inputBytes: 1_000_000, sourcePixels: 100_000,
      normalizedDimension: 512, thumbnailDimension: 400, rasterBytes: 512 * 512 * 4,
      normalizedBytes: 1_000_000, thumbnailBytes: 1_000_000, duration: .seconds(5))
    let result = try await Preparer(limits: config).prepare(fixture(), format: .png)
    #expect(result.normalized.width == 240 && result.normalized.height == 320)
    #expect(result.thumbnail.width == 240 && result.thumbnail.height == 320)
  }

  @Test("预算在输入、源像素、两图输出和阶段时限生效", arguments: 0..<5)
  func budgets(_ index: Int) async throws {
    let config = try limits(input: index == 0 ? 1 : 1_000_000, pixels: index == 1 ? 1 : 100_000,
      full: index == 2 ? 1 : 1_000_000, small: index == 3 ? 1 : 100_000,
      duration: index == 4 ? .nanoseconds(1) : .seconds(5))
    let source = try fixture()
    await #expect(throws: Preparer.Failure.resourceLimitExceeded) {
      try await Preparer(limits: config).prepare(source, format: .png)
    }
  }

  @Test("损坏、错误类型与空输入不返回图片", arguments: 0..<3)
  func invalidInput(_ index: Int) async throws {
    let bytes = index == 0 ? Data() : index == 1 ? Data(try fixture().prefix(40)) : try fixture(type: "public.jpeg")
    await #expect(throws: Preparer.Failure.unsafeInput) {
      try await Preparer(limits: limits()).prepare(bytes, format: .png)
    }
  }

  @Test("动画及未批准格式不偷偷使用第一帧", arguments: [false, true])
  func unsupported(_ animated: Bool) async throws {
    let bytes = try fixture(type: animated ? "public.png" : "public.tiff", frames: animated ? 2 : 1)
    await #expect(throws: Preparer.Failure.unsupportedFormat) {
      try await Preparer(limits: limits()).prepare(bytes, format: .png)
    }
  }

  @Test("非零起点 Data 输入也按实际字节处理")
  func slicedInput() async throws {
    var bytes = Data(repeating: 0, count: 32)
    bytes.append(try fixture(type: "public.heic"))
    let slice = bytes.dropFirst(32)
    #expect(slice.startIndex == 32)
    let result = try await Preparer(limits: limits()).prepare(slice, format: .heic)
    _ = try inspect(result.thumbnail)
  }

  @Test("预先取消不会返回待保存结果")
  func cancellation() async throws {
    let bytes = try fixture(), processor = try Preparer(limits: limits())
    await #expect(throws: CancellationError.self) {
      try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
        group.cancelAll()
        group.addTask { try await processor.prepare(bytes, format: .png) }
        _ = try await group.next()
      }
    }
  }

  @Test("不接受溢出、零预算或比规范图大的缩略图")
  func badConfiguration() throws {
    for (dimension, thumb, duration) in [(0, 1, Duration.seconds(1)), (Int.max, 1, .seconds(1)),
                                        (16, 17, .seconds(1)), (16, 8, .zero)] {
      #expect(throws: Preparer.Failure.invalidLimits) {
        try Preparer.Limits(inputBytes: 1, sourcePixels: 1, normalizedDimension: dimension,
          thumbnailDimension: thumb, rasterBytes: Int.max, normalizedBytes: 1, thumbnailBytes: 1, duration: duration)
      }
    }
  }

  @Test("实际编码图可保存、重启读取并按衣物删除")
  func persistenceJourney() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { Issue.record("Image test directory cleanup failed") }
    }
    let prepared = try await Preparer(limits: limits()).prepare(fixture(), format: .png)
    let store = GRDBWardrobeRepository(directory: directory)
    let itemID = UUID()
    _ = try await store.create(id: itemID, input: WardrobeInput(name: "合成衣物", category: .top, availability: .wearable), source: .wardrobe)
    // Explicit test approval of this original geometric fixture; not a production classifier.
    let photo = try WardrobePhotoWrite(id: UUID(), thumbnailID: UUID(), normalized: prepared.normalized,
                                      thumbnail: prepared.thumbnail, quality: .catalogReady)
    _ = try await store.savePhoto(photo, itemID: itemID, expectedRevision: 1)
    try await store.close()
    let reopened = GRDBWardrobeRepository(directory: directory)
    let read = try #require(try await reopened.readPhoto(itemID: itemID, purpose: .thumbnail, maximumBytes: 100_000))
    #expect(read.bytes == prepared.thumbnail.bytes)
    let source = try #require(CGImageSourceCreateWithData(read.bytes as CFData, nil))
    #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    try await reopened.delete(id: itemID, expectedRevision: 2, impact: .init(plans: []), policy: .redactSnapshots)
    #expect(try await reopened.readPhoto(itemID: itemID, purpose: .normalized, maximumBytes: 1_000_000) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("WardrobeMedia").path).isEmpty)
    try await reopened.close()
  }
}
