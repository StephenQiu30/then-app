import Foundation

nonisolated enum WardrobePhotoPurpose: String, Sendable { case normalized, thumbnail }
nonisolated enum WardrobeImageFormat: String, Sendable { case jpeg, png }
nonisolated enum WardrobePhotoQuality: String, Sendable { case catalogReady = "catalog_ready" }
nonisolated enum WardrobePhotoInputError: Error { case invalidImage }

/// Storage input from the image preparation service. It does not itself establish image safety/quality.
nonisolated struct WardrobeEncodedImage: Equatable, Sendable {
  let bytes: Data
  let format: WardrobeImageFormat
  let width: Int
  let height: Int

  init(bytes: Data, format: WardrobeImageFormat, width: Int, height: Int, maximumBytes: Int) throws {
    guard maximumBytes > 0, !bytes.isEmpty, bytes.count <= maximumBytes,
          width > 0, height > 0, width <= Int.max / height / 4 else {
      throw WardrobePhotoInputError.invalidImage
    }
    self.bytes = bytes
    self.format = format
    self.width = width
    self.height = height
  }
}

nonisolated struct WardrobePhotoWrite: Equatable, Sendable {
  let id: UUID
  let thumbnailID: UUID
  let normalized: WardrobeEncodedImage
  let thumbnail: WardrobeEncodedImage
  let quality: WardrobePhotoQuality

  init(id: UUID, thumbnailID: UUID, normalized: WardrobeEncodedImage, thumbnail: WardrobeEncodedImage,
       quality: WardrobePhotoQuality) throws {
    guard id != thumbnailID, thumbnail.width <= normalized.width,
          thumbnail.height <= normalized.height else { throw WardrobePhotoInputError.invalidImage }
    self.id = id
    self.thumbnailID = thumbnailID
    self.normalized = normalized
    self.thumbnail = thumbnail
    self.quality = quality
  }
}

nonisolated struct WardrobePhotoVariant: Equatable, Sendable {
  let id: UUID
  let format: WardrobeImageFormat
  let width: Int
  let height: Int
  let byteCount: Int
  let sha256: String
}

nonisolated struct WardrobePhotoMetadata: Equatable, Sendable {
  let id: UUID
  let quality: WardrobePhotoQuality
  let normalized: WardrobePhotoVariant
  let thumbnail: WardrobePhotoVariant
  let createdAt: Date
}

nonisolated struct WardrobePhotoRead: Equatable, Sendable {
  let metadata: WardrobePhotoMetadata
  let purpose: WardrobePhotoPurpose
  let bytes: Data
}

nonisolated struct WardrobePhotoSaveResult: Sendable {
  let metadata: WardrobePhotoMetadata
  let itemRevision: Int
  let cleanupPending: Bool
}

nonisolated protocol WardrobePhotoRepository: Sendable {
  func saveItemWithPhoto(_ edit: WardrobeItemPhotoEdit, photo: WardrobePhotoWrite) async throws -> WardrobeItemPhotoSaveResult
  func photoMetadata(itemID: UUID) async throws -> WardrobePhotoMetadata?
  func savePhoto(_ photo: WardrobePhotoWrite, itemID: UUID, expectedRevision: Int) async throws -> WardrobePhotoSaveResult
  func readPhoto(itemID: UUID, purpose: WardrobePhotoPurpose, maximumBytes: Int) async throws -> WardrobePhotoRead?
  func removePhoto(id: UUID, itemID: UUID, expectedRevision: Int) async throws
  func hasPendingPhotoCleanup() async throws -> Bool
  func retryPhotoCleanup() async throws
}


nonisolated enum WardrobePhotoSourceFormat: String, Sendable {
  case jpeg = "public.jpeg", png = "public.png", heic = "public.heic"
}

/// Encoded previews awaiting the single-garment and user review gates, not a quality approval.
nonisolated struct WardrobePreparedPhoto: Sendable {
  let normalized: WardrobeEncodedImage
  let thumbnail: WardrobeEncodedImage
}

nonisolated protocol WardrobePhotoPreparing: Sendable {
  func prepare(_ bytes: Data, format: WardrobePhotoSourceFormat) async throws -> WardrobePreparedPhoto
}

nonisolated struct WardrobeItemPhotoEdit: Sendable {
  let id: UUID
  let input: WardrobeInput
  let source: WardrobeSource
  let expectedRevision: Int?
}

nonisolated struct WardrobeItemPhotoSaveResult: Sendable {
  let item: WardrobeItem
  let photo: WardrobePhotoMetadata
  let cleanupPending: Bool
}
