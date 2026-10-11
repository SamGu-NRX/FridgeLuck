import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Hands the rendered document text to the system share sheet.
///
/// Completion is reported neutrally in both the completed and cancelled case —
/// a closed share sheet never confirms that another app received the text.
struct RecipeExportShareSheet: UIViewControllerRepresentable {
  let text: String
  let onClosed: (_ userCompleted: Bool) -> Void

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, completed, _, _ in
      // UIActivityViewController reports completion on the main thread.
      MainActor.assumeIsolated {
        onClosed(completed)
      }
    }
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// A plain-text document wrapper so the prepared text exports through
/// `.fileExporter` as UTF-8.
struct RecipeExportTextDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }

  var text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    let data = configuration.file.regularFileContents ?? Data()
    text = String(data: data, encoding: .utf8) ?? ""
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
