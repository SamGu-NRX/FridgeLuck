import SwiftUI
import UIKit

/// Normalizes scan images before they enter the UX flow to keep layout and memory stable.
enum ScanImagePreprocessor {
  struct PreparedCrop: Sendable {
    let id: String
    let image: CGImage
  }

  static func prepare(_ image: UIImage, maxDimension: CGFloat = 1600) -> UIImage {
    let oriented = normalizedOrientationImage(image)
    return downscaledImageIfNeeded(oriented, maxDimension: maxDimension)
  }

  /// Deterministic crop schedule:
  /// - full frame
  /// - center crop
  /// - four quadrants
  static func deterministicCrops(for image: CGImage) -> [PreparedCrop] {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else {
      return [PreparedCrop(id: "full", image: image)]
    }

    var crops: [PreparedCrop] = [
      PreparedCrop(id: "full", image: image)
    ]

    let minSide = min(width, height)
    let centerSize = Int(Double(minSide) * 0.70)
    let centerX = max(0, (width - centerSize) / 2)
    let centerY = max(0, (height - centerSize) / 2)
    if let center = crop(
      image,
      x: centerX,
      y: centerY,
      width: centerSize,
      height: centerSize,
      id: "center"
    ) {
      crops.append(center)
    }

    let halfWidth = max(1, width / 2)
    let halfHeight = max(1, height / 2)
    let quadrantDefs: [(String, Int, Int)] = [
      ("topLeft", 0, 0),
      ("topRight", max(0, width - halfWidth), 0),
      ("bottomLeft", 0, max(0, height - halfHeight)),
      ("bottomRight", max(0, width - halfWidth), max(0, height - halfHeight)),
    ]

    for (id, x, y) in quadrantDefs {
      if let q = crop(image, x: x, y: y, width: halfWidth, height: halfHeight, id: id) {
        crops.append(q)
      }
    }

    return crops
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

  private static func crop(
    _ image: CGImage,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    id: String
  ) -> PreparedCrop? {
    guard width >= 64, height >= 64 else { return nil }
    let rect = CGRect(x: x, y: y, width: width, height: height).integral
    guard let cropped = image.cropping(to: rect) else { return nil }
    return PreparedCrop(id: id, image: cropped)
  }
}
