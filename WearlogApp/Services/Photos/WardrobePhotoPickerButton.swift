import PhotosUI
import SwiftUI

/// Only the system selection control lives here; product state belongs to the editor.
struct WardrobePhotoPickerButton: View {
  let onSelection: (any WardrobePhotoSelecting) -> Void
  @State private var selection: PhotosPickerItem?

  var body: some View {
    PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
      Text("选择衣物照片")
        .font(.body)
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 44, alignment: .leading)
    }
    .accessibilityIdentifier("wardrobe.photo.pick")
    .onChange(of: selection) { _, item in
      guard let item else { return }
      onSelection(SystemWardrobePhotoSelection(item: item))
      selection = nil
    }
  }
}

nonisolated private struct SystemWardrobePhotoSelection: WardrobePhotoSelecting {
  let item: PhotosPickerItem

  func load() async throws -> WardrobePhotoCandidate {
    // Explicit simulator-development composition, not an assertion of release image budgets.
    let limits = try ImageIOWardrobePhotoPreparer.Limits(inputBytes: 20 * 1024 * 1024,
      sourcePixels: 48 * 1024 * 1024, normalizedDimension: 512, thumbnailDimension: 128,
      rasterBytes: 1024 * 1024, normalizedBytes: 4 * 1024 * 1024, thumbnailBytes: 512 * 1024,
      duration: .seconds(5))
    let picker = try SystemWardrobePhotoPicker(limits: limits, transferTimeout: .seconds(60))
    let photo = try await picker.load(item)
    let analyzer = try VisionWardrobePersonAnalyzer(maximumBytes: 4 * 1024 * 1024,
      maximumPixels: 512 * 512, duration: .seconds(5), computeDevice: .cpu)
    let observations = try await analyzer.analyze(photo.normalized)
    return WardrobePhotoCandidate(photo: photo, observations: observations)
  }
}
