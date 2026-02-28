import SwiftUI
import UIKit

/// Normalizes scan images before they enter the UX flow to keep layout and memory stable.
enum ScanImagePreprocessor {
  static func prepare(_ image: UIImage, maxDimension: CGFloat = 1600) -> UIImage {
    let oriented = normalizedOrientationImage(image)
    return downscaledImageIfNeeded(oriented, maxDimension: maxDimension)
  }

  private static func normalizedOrientationImage(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up else { return image }

    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = true
    format.scale = 1

    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }

  private static func downscaledImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let largestSide = max(image.size.width, image.size.height)
    guard largestSide > maxDimension, largestSide > 0 else { return image }

    let ratio = maxDimension / largestSide
    let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)

    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = true
    format.scale = 1

    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
  }
}
