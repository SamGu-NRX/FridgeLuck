import Foundation
import UIKit

/// Runs demo mode through the real scan pipeline when possible,
/// with a deterministic bundled fixture fallback for offline reliability.
enum DemoScanService {
  struct DemoScanPayload {
    let detections: [Detection]
    let image: UIImage?
  }

  private struct DemoFixture: Decodable {
    let ingredientId: Int64
    let label: String
    let confidence: Float
    let source: String
    let originalVisionLabel: String
    let alternatives: [DemoFixtureAlternative]?
  }

  private struct DemoFixtureAlternative: Decodable {
    let ingredientId: Int64
    let label: String
  }

  static func loadDemoPayload(using visionService: VisionService) async -> DemoScanPayload {
    let demoImage = loadDemoImage()

    if let image = demoImage,
      let cgImage = image.cgImage,
      let scanResult = try? await visionService.scan(image: cgImage),
      !scanResult.detections.isEmpty
    {
      return DemoScanPayload(detections: scanResult.detections, image: image)
    }

    return DemoScanPayload(detections: loadFallbackFixture(), image: demoImage)
  }

  static func loadDemoImage() -> UIImage? {
    let candidates: [(name: String, ext: String)] = [
      ("garlic_fried_rice", "jpg"),
      ("garlic fried rice", "jpg"),
      ("garlic-fried-rice", "jpg"),
      ("placeholder_ingredients", "jpg"),
    ]

    for candidate in candidates {
      if let image = loadImage(name: candidate.name, ext: candidate.ext) {
        return image
      }
    }

    return nil
  }

  private static func loadImage(name: String, ext: String) -> UIImage? {
    // Prefer explicit demo subdirectory matches to avoid accidentally loading similarly named assets.
    if let demoURLs = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "demo") {
      for url in demoURLs where url.deletingPathExtension().lastPathComponent == name {
        if let image = decodeImage(url: url) {
          return image
        }
      }
    }

    let legacyURLs: [URL?] = [
      Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/demo"),
      Bundle.main.url(forResource: "Resources/demo/\(name)", withExtension: ext),
      Bundle.main.url(forResource: name, withExtension: ext),
    ]

    for url in legacyURLs.compactMap({ $0 }) {
      if let image = decodeImage(url: url) {
        return image
      }
    }

    return nil
  }

  private static func decodeImage(url: URL) -> UIImage? {
    guard
      let data = try? Data(contentsOf: url),
      let image = UIImage(data: data),
      image.size.width > 24,
      image.size.height > 24
    else {
      return nil
    }

    return ScanImagePreprocessor.prepare(image)
  }

  private static func loadFallbackFixture() -> [Detection] {
    guard
      let url = Bundle.main.url(forResource: "demo_detections", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let fixtures = try? JSONDecoder().decode([DemoFixture].self, from: data)
    else {
      return []
    }

    return fixtures.map { fixture in
      let source = DetectionSource(rawValue: fixture.source) ?? .vision
      return Detection(
        ingredientId: fixture.ingredientId,
        label: fixture.label,
        confidence: fixture.confidence,
        source: source,
        originalVisionLabel: fixture.originalVisionLabel,
        alternatives: (fixture.alternatives ?? []).map {
          DetectionAlternative(
            ingredientId: $0.ingredientId,
            label: $0.label,
            confidence: nil
          )
        }
      )
    }
  }
}
