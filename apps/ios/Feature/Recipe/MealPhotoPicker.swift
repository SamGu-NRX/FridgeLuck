import SwiftUI
import UIKit

/// UIKit camera wrapper for meal photos.
/// Unlike `CameraPicker`, this does NOT apply `ScanImagePreprocessor`.
struct MealPhotoPicker: UIViewControllerRepresentable {
  @Binding var image: UIImage?
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.delegate = context.coordinator
    picker.modalPresentationStyle = .fullScreen
    picker.allowsEditing = true
    picker.sourceType = .camera
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let parent: MealPhotoPicker

    init(_ parent: MealPhotoPicker) {
      self.parent = parent
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
        parent.image = image
      }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}
