import SwiftUI
import UIKit

struct LocalDataShareSheet: UIViewControllerRepresentable {
  let fileURL: URL
  let onCompletion: () -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: [fileURL],
      applicationActivities: nil
    )
    controller.completionWithItemsHandler = { _, _, _, _ in
      onCompletion()
    }
    return controller
  }

  func updateUIViewController(
    _ uiViewController: UIActivityViewController,
    context: Context
  ) {}
}
