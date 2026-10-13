import Foundation

/// Restricts PNG bytes created by our sRGB encoder, never arbitrary source PNGs.
nonisolated enum PixelOnlyPNG {
  enum Failure: Error { case invalidEncoding }

  static func clean(_ encoded: Data) throws -> Data {
    guard !encoded.isEmpty,
          encoded.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    else { throw Failure.invalidEncoding }
    var clean = Data(encoded.prefix(8))
    var offset = 8
    var sawHeader = false, sawColor = false, sawPixels = false, sawEnd = false
    while encoded.count - offset >= 12 {
      let length = encoded[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
      guard length <= encoded.count - offset - 12 else { throw Failure.invalidEncoding }
      let end = offset + length + 12
      let typeBytes = encoded[(offset + 4)..<(offset + 8)]
      let type = String(decoding: typeBytes, as: UTF8.self)
      switch type {
      case "IHDR":
        guard offset == 8, length == 13, !sawHeader else { throw Failure.invalidEncoding }
        sawHeader = true
      case "sRGB":
        guard sawHeader, !sawColor, !sawPixels, length == 1 else { throw Failure.invalidEncoding }
        sawColor = true
      case "IDAT":
        guard sawHeader else { throw Failure.invalidEncoding }
        sawPixels = true
      case "IEND":
        guard sawPixels, length == 0, end == encoded.count else { throw Failure.invalidEncoding }
        sawEnd = true
      default:
        // Unexpected critical chunks are an encoder-contract error, never silently removed.
        guard let first = typeBytes.first, first & 0x20 != 0 else { throw Failure.invalidEncoding }
        offset = end
        continue
      }
      clean.append(encoded[offset..<end])
      offset = end
    }
    guard offset == encoded.count, sawHeader, sawColor, sawPixels, sawEnd else { throw Failure.invalidEncoding }
    return clean
  }
}
