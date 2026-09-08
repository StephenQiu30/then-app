import SwiftUI
import UIKit

struct ReceiptCameraPicker: UIViewControllerRepresentable {
  let onImageData: @MainActor (Data) -> Void
  let onFailure: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  static var isAvailable: Bool {
    UIImagePickerController.isSourceTypeAvailable(.camera)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onImageData: onImageData,
      onFailure: onFailure,
      onCancel: onCancel
    )
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let controller = UIImagePickerController()
    controller.delegate = context.coordinator
    controller.sourceType = .camera
    controller.cameraCaptureMode = .photo
    return controller
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  @MainActor
  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate
  {
    private let onImageData: @MainActor (Data) -> Void
    private let onFailure: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void

    init(
      onImageData: @escaping @MainActor (Data) -> Void,
      onFailure: @escaping @MainActor () -> Void,
      onCancel: @escaping @MainActor () -> Void
    ) {
      self.onImageData = onImageData
      self.onFailure = onFailure
      self.onCancel = onCancel
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      onCancel()
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      guard let image = info[.originalImage] as? UIImage,
        let data = image.jpegData(compressionQuality: 0.92)
      else {
        onFailure()
        return
      }
      onImageData(data)
    }
  }
}
