import FLFeatureLogic
import Foundation
import ImageIO

enum ScanBenchmarkRunner {
  enum RunnerError: LocalizedError {
    case missingManifest
    case missingImageResource(String)
    case couldNotDecodeImage(String)

    var errorDescription: String? {
      switch self {
      case .missingManifest:
        return "Scan benchmark manifest resource is missing."
      case .missingImageResource(let imageID):
        return "Missing scan benchmark image resource for \(imageID)."
      case .couldNotDecodeImage(let imageID):
        return "Could not decode benchmark image for \(imageID)."
      }
    }
  }

  struct AppRunObservation: Sendable {
    let detections: [Detection]
    let nutrition: NutritionLabelParseOutcome?
    let elapsedMs: Int
    let passErrors: [String]
    let errorDescription: String?
  }

  typealias ScanClosure =
    @Sendable (_ cgImage: CGImage, _ captureIndex: Int) async -> AppRunObservation

  static func defaultCorpus(bundle: Bundle = .main) throws -> ScanBenchmarkCorpus {
    guard let url = bundle.url(forResource: "benchmark_manifest", withExtension: "json") else {
      throw RunnerError.missingManifest
    }

    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ScanBenchmarkCorpus.self, from: data)
  }

  static func run(
    corpus: ScanBenchmarkCorpus,
    bundle: Bundle = .main,
    scanImage: ScanClosure
  ) async throws -> ScanBenchmarkReport {
    var imageReports: [ScanBenchmarkImageReport] = []

    for entry in corpus.images {
      guard
        let imageURL = bundle.url(
          forResource: entry.resourceName,
          withExtension: entry.resourceExtension,
          subdirectory: entry.resourceSubdirectory
        )
      else {
        throw RunnerError.missingImageResource(entry.id)
      }

      guard let cgImage = loadCGImage(at: imageURL) else {
        throw RunnerError.couldNotDecodeImage(entry.id)
      }

      var runs: [ScanBenchmarkRunObservation] = []
      for iteration in 0..<max(1, corpus.iterations) {
        let observation = await scanImage(cgImage, iteration)
        runs.append(
          ScanBenchmarkRunObservation(
            iteration: iteration,
            detections: observation.detections.map(mapDetection),
            nutrition: mapNutrition(observation.nutrition),
            elapsedMs: observation.elapsedMs,
            passErrors: observation.passErrors,
            errorDescription: observation.errorDescription
          )
        )
      }

      imageReports.append(
        ScanBenchmarkScorer.evaluateImage(
          corpusEntry: entry,
          runs: runs,
          gates: corpus.gates
        )
      )
    }

    return ScanBenchmarkScorer.makeReport(corpus: corpus, imageReports: imageReports)
  }

  static func run(
    corpus: ScanBenchmarkCorpus,
    visionService: VisionService,
    bundle: Bundle = .main
  ) async throws -> ScanBenchmarkReport {
    try await run(corpus: corpus, bundle: bundle) { cgImage, captureIndex in
      let startedAt = Date()

      do {
        let result = try await visionService.scan(
          inputs: [ScanInput(image: cgImage, source: .benchmark, captureIndex: captureIndex)]
        )

        return AppRunObservation(
          detections: result.detections,
          nutrition: NutritionLabelParser.parse(ocrText: result.ocrText),
          elapsedMs: result.diagnostics.elapsedMs,
          passErrors: result.diagnostics.passErrors,
          errorDescription: nil
        )
      } catch {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let errorDescription = error.localizedDescription
        return AppRunObservation(
          detections: [],
          nutrition: nil,
          elapsedMs: elapsedMs,
          passErrors: [],
          errorDescription: errorDescription
        )
      }
    }
  }

  static func writeReport(_ report: ScanBenchmarkReport, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: url, options: .atomic)
  }

  private static func loadCGImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func mapDetection(_ detection: Detection) -> ScanBenchmarkObservedDetection {
    ScanBenchmarkObservedDetection(
      ingredientId: detection.ingredientId,
      alternativeIngredientIds: detection.alternatives.map(\.ingredientId),
      bucket: mapBucket(detection)
    )
  }

  private static func mapBucket(_ detection: Detection) -> ScanBenchmarkDetectionBucket {
    switch ConfidenceRouter.bucket(for: detection) {
    case .auto:
      return .auto
    case .confirm:
      return .confirm
    case .possible:
      return .possible
    }
  }

  private static func mapNutrition(
    _ nutrition: NutritionLabelParseOutcome?
  ) -> ScanBenchmarkObservedNutrition? {
    guard let parsed = nutrition?.parsed else { return nil }
    return ScanBenchmarkObservedNutrition(
      caloriesPerServing: parsed.caloriesPerServing,
      servingSize: parsed.servingSize,
      servingsPerContainer: parsed.servingsPerContainer
    )
  }
}
