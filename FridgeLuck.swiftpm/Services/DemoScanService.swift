import Foundation
import UIKit

/// Runs demo mode through the real scan pipeline when possible,
/// with a deterministic bundled fixture fallback for offline reliability.
enum DemoScanService {
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

  static func loadDetections(using visionService: VisionService) async -> [Detection] {
    if let url = Bundle.main.url(forResource: "demo_ingredients", withExtension: "jpg"),
      let data = try? Data(contentsOf: url),
      let image = UIImage(data: data),
      let cgImage = image.cgImage,
      let scanResult = try? await visionService.scan(image: cgImage),
      !scanResult.detections.isEmpty
    {
      return scanResult.detections
    }

    return loadFallbackFixture()
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
