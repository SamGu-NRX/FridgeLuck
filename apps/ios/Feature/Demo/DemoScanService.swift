import FLFeatureLogic
import Foundation
import UIKit

/// Runs demo mode through the real scan pipeline when possible,
/// with a deterministic bundled fixture fallback for offline reliability.
enum DemoScanService {
  struct DemoScanPayload {
    let detections: [Detection]
    let image: UIImage?
    let provenance: ScanProvenance
    let diagnostics: ScanDiagnostics?
    let usedBundledFixture: Bool
    let usedStarterFallback: Bool
  }

  private struct DemoFixture: Decodable {
    let ingredientId: Int64
    let label: String
    let confidence: Float
    let source: String
    let originalVisionLabel: String
    let alternatives: [DemoFixtureAlternative]?
    let normalizedBoundingBox: DemoFixtureRect?
    let evidenceTokens: [String]?
    let cropID: String?
    let captureIndex: Int?
    let ocrMatchKind: String?
  }

  private struct DemoFixtureAlternative: Decodable {
    let ingredientId: Int64
    let label: String
  }

  private struct DemoFixtureRect: Decodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
  }

  /// Load demo payload for the default scenario (Asian Stir-Fry / legacy).
  static func loadDemoPayload(using visionService: VisionService) async -> DemoScanPayload {
    await loadDemoPayload(scenario: nil, using: visionService)
  }

  /// Load demo payload for a specific scenario, falling back through fixture → starter.
  static func loadDemoPayload(scenario: DemoScenario?, using visionService: VisionService) async
    -> DemoScanPayload
  {
    let demoImage = loadDemoImage()
    let fixtureName = scenario?.fixtureFileName ?? "demo_detections"

    if scenario == nil,
      let image = demoImage,
      let cgImage = image.cgImage,
      let scanResult = try? await visionService.scan(image: cgImage),
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: scenario == nil,
        hasDemoImage: true,
        detectionCount: scanResult.detections.count
      )
    {
      return DemoScanPayload(
        detections: scanResult.detections,
        image: image,
        provenance: scanResult.provenance,
        diagnostics: scanResult.diagnostics,
        usedBundledFixture: false,
        usedStarterFallback: false
      )
    }

    let fixtureDetections = loadFallbackFixture(named: fixtureName)
    let fallback = DemoFallbackPolicy.fallbackDecision(
      hasFixtureDetections: !fixtureDetections.isEmpty
    )

    if !fallback.usedStarterFallback {
      return DemoScanPayload(
        detections: fixtureDetections,
        image: demoImage,
        provenance: .bundledFixture,
        diagnostics: nil,
        usedBundledFixture: fallback.usedBundledFixture,
        usedStarterFallback: fallback.usedStarterFallback
      )
    }

    return DemoScanPayload(
      detections: starterDetections(),
      image: demoImage,
      provenance: .starterFallback,
      diagnostics: nil,
      usedBundledFixture: fallback.usedBundledFixture,
      usedStarterFallback: fallback.usedStarterFallback
    )
  }

  /// Load the scenario-specific photo for the scan animation overlay.
  static func loadScenarioImage(for scenario: DemoScenario) -> UIImage? {
    if let image = loadImage(name: scenario.scenarioImageName, ext: "png") {
      return image
    }
    return loadDemoImage()
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

  private static func loadFallbackFixture(named fixtureName: String = "demo_detections")
    -> [Detection]
  {
    guard
      let url = Bundle.main.url(forResource: fixtureName, withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let fixtures = try? JSONDecoder().decode([DemoFixture].self, from: data)
    else {
      return []
    }

    return fixtures.map { fixture in
      let source = DetectionSource(rawValue: fixture.source) ?? .vision
      let rect = fixture.normalizedBoundingBox.map {
        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
      }
      let matchKind = fixture.ocrMatchKind.flatMap(OCRMatchKind.init(rawValue:))
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
        },
        normalizedBoundingBox: rect,
        evidenceTokens: fixture.evidenceTokens ?? [],
        cropID: fixture.cropID,
        captureIndex: fixture.captureIndex,
        ocrMatchKind: matchKind
      )
    }
  }

  private static func starterDetections() -> [Detection] {
    let starterIds: [Int64] = [1, 2, 5, 6]
    return starterIds.map { id in
      Detection(
        ingredientId: id,
        label: IngredientLexicon.displayName(for: id),
        confidence: 1.0,
        source: .manual,
        originalVisionLabel: "starter_\(id)",
        alternatives: [],
        normalizedBoundingBox: nil,
        evidenceTokens: ["starter_fallback"],
        cropID: "starter",
        captureIndex: 0,
        ocrMatchKind: nil
      )
    }
  }
}
