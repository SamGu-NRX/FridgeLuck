import Foundation
import UIKit

/// Saves and loads meal photos to the app's documents directory.
/// Photos are stored as JPEG with a quality/size balance suitable for a food journal.
final class ImageStorageService: Sendable {
  private static let directoryName = "MealPhotos"
  private static let jpegQuality: CGFloat = 0.82

  // MARK: - Save

  /// Save a UIImage and return the relative path (for storing in cooking_history.image_path).
  func save(_ image: UIImage) throws -> String {
    let directory = try photosDirectory()
    let filename = "\(UUID().uuidString).jpg"
    let filePath = directory.appendingPathComponent(filename)

    // Resize to reasonable dimensions for a food journal (max 1200px wide)
    let resized = Self.resize(image, maxDimension: 1200)

    guard let data = resized.jpegData(compressionQuality: Self.jpegQuality) else {
      throw ImageStorageError.encodingFailed
    }

    try data.write(to: filePath, options: .atomic)
    return "\(Self.directoryName)/\(filename)"
  }

  // MARK: - Load

  /// Load a UIImage from a relative path stored in cooking_history.
  func load(relativePath: String) -> UIImage? {
    guard let docsURL = try? documentsDirectory() else { return nil }
    let fileURL = docsURL.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return UIImage(contentsOfFile: fileURL.path)
  }

  // MARK: - Delete

  func delete(relativePath: String) throws {
    let docsURL = try documentsDirectory()
    let fileURL = docsURL.appendingPathComponent(relativePath)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
  }

  // MARK: - Paths

  private func documentsDirectory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
  }

  private func photosDirectory() throws -> URL {
    let dir = try documentsDirectory().appendingPathComponent(Self.directoryName)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  // MARK: - Resize

  private static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let size = image.size
    guard max(size.width, size.height) > maxDimension else { return image }

    let scale: CGFloat
    if size.width > size.height {
      scale = maxDimension / size.width
    } else {
      scale = maxDimension / size.height
    }

    let newSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
  }
}

enum ImageStorageError: LocalizedError {
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .encodingFailed: "Failed to encode image as JPEG."
    }
  }
}
