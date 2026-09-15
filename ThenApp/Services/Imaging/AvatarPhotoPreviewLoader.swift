#if DEBUG
import Foundation
import ImageIO

nonisolated struct AvatarPhotoPreviewLoader: Sendable {
  nonisolated enum Failure: Error {
    case unreadable
  }

  private let store: AvatarPhotoTemporarySessionStore
  private let maximumBytes: Int

  init(store: AvatarPhotoTemporarySessionStore, maximumBytes: Int) {
    self.store = store
    self.maximumBytes = maximumBytes
  }

  @concurrent func load(_ photo: SanitizedAvatarPhotoHandle) async throws -> Data {
    try Task.checkCancellation()
    guard maximumBytes > 0 else { throw Failure.unreadable }
    let reference = AvatarPhotoTemporarySessionStore.FileReference(
      sessionID: photo.sessionID,
      fileID: photo.assetID,
      purpose: .sanitizedPreview
    )
    let url = try await store.fileURL(for: reference)
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    try Task.checkCancellation()
    guard !data.isEmpty, data.count <= maximumBytes,
          let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
          ),
          CGImageSourceGetType(source) as String? == AvatarPhotoInputFormat.png.rawValue,
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetStatus(source) == .statusComplete,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          properties[kCGImagePropertyPixelWidth] as? Int == photo.width,
          properties[kCGImagePropertyPixelHeight] as? Int == photo.height,
          (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    else { throw Failure.unreadable }
    return data
  }
}
#endif
