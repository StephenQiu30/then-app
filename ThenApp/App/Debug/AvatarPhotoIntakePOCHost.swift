#if DEBUG
import SwiftUI

struct AvatarPhotoIntakePOCHost: View {
  private enum Phase {
    case starting
    case ready(Composition)
    case failed
  }

  private struct Composition {
    let model: AvatarPhotoIntakeViewModel
    let picker: SystemAvatarPhotoPicker
    let previewLoader: AvatarPhotoPreviewLoader
  }

  @State private var phase: Phase = .starting
  @State private var attempt = 0

  var body: some View {
    Group {
      switch phase {
      case .starting:
        ProgressView("正在准备照片测试…")
          .accessibilityIdentifier("avatar.photo.poc.starting")
      case .ready(let composition):
        AvatarPhotoIntakePOCView(
          model: composition.model,
          picker: composition.picker,
          previewLoader: composition.previewLoader
        )
      case .failed:
        ContentUnavailableView {
          Label("无法启动照片测试", systemImage: "photo.badge.exclamationmark")
        } description: {
          Text("临时照片空间无法安全准备。你仍可退出测试并使用风格化形象。")
        } actions: {
          Button("重试") {
            phase = .starting
            attempt += 1
          }
        }
        .accessibilityIdentifier("avatar.photo.poc.startup-failed")
      }
    }
    .task(id: attempt) { await start() }
  }

  private func start() async {
    guard case .starting = phase else { return }
    do {
      let store = try AvatarPhotoTemporarySessionStore()
      try await store.prepareForUse()
      let limits = try ImageIOAvatarPhotoSanitizer.Limits(
        maximumInputBytes: 20 * 1024 * 1024,
        maximumSourcePixels: 48_000_000,
        maximumOutputDimension: 2_048,
        maximumRasterBytes: 16 * 1024 * 1024,
        maximumOutputBytes: 12 * 1024 * 1024,
        maximumDuration: .seconds(20)
      )
      let analyzer = try VisionAvatarPhotoAnalyzer(
        store: store,
        maximumBytes: 12 * 1024 * 1024,
        maximumPixels: 2_048 * 2_048,
        duration: .seconds(15),
        computeDevice: .system
      )
      // These thresholds are deliberately POC-only. Sharpness remains disabled until
      // the approved evaluation set can separate normal and motion-blurred inputs.
      let policy = try AvatarPhotoQualityPolicy(
        minimumFullPersonCoverage: 0.75,
        minimumVisibility: 0.30,
        minimumSharpness: 0,
        minimumExposureUsability: 0.25
      )
      let useCase = PrepareAvatarPhotoUseCase(
        sanitizer: ImageIOAvatarPhotoSanitizer(store: store, limits: limits),
        analyzer: analyzer,
        policy: policy,
        sessionCleaner: store
      )
      try Task.checkCancellation()
      phase = .ready(Composition(
        model: AvatarPhotoIntakeViewModel(useCase: useCase),
        picker: SystemAvatarPhotoPicker(store: store, limits: limits),
        previewLoader: AvatarPhotoPreviewLoader(store: store, maximumBytes: 12 * 1024 * 1024)
      ))
    } catch is CancellationError {
      // A replacement host task owns the next attempt.
    } catch {
      phase = .failed
    }
  }
}
#endif
