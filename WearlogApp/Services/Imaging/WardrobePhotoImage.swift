import Foundation
import ImageIO
import SwiftUI

/// Decodes already bounded, normalized pixels; never reads files or fetches remote content.
enum WardrobePhotoImage {
  static func decode(_ data: Data) -> Image? {
    guard !data.isEmpty, data.count <= 4 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 512, height <= 512,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return Image(decorative: image, scale: 1, orientation: .up)
  }
}
