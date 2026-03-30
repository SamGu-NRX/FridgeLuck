import FLFeatureLogic
import Foundation
import XCTest

final class ScanBenchmarkScorerTests: XCTestCase {
  func testExactMatchImageScoresPerfectDetectionMetrics() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: exactMatchEntry(),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .passed)
    XCTAssertEqual(report.detectionMetrics.status, .measured)
    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 1, accuracy: 0.0001)
  }

  func testPartialMissImageScoresCorrectionCoverageAndRegression() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: ScanBenchmarkCorpusEntry(
        id: "partial",
        resourceName: "partial",
        resourceExtension: "png",
        scenarioTags: ["synthetic"],
        expectedIngredientIds: [1, 2, 3]
      ),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, alternatives: [3], bucket: .confirm),
            detection(99, bucket: .possible),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .regressed)
    XCTAssertEqual(report.detectionMetrics.status, .measured)
    XCTAssertEqual(report.correctionMetrics.status, .measured)
    XCTAssertEqual(report.correctionMetrics.alternativeCoverageRate ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(
      report.correctionMetrics.topPredictionAcceptanceRate ?? -1,
      2.0 / 3.0,
      accuracy: 0.0001
    )
  }

  func testEmptyButExpectedImageIsInvalid() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: exactMatchEntry(),
      runs: [
        run(iteration: 0, detections: [])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.runs.first?.valid, false)
    XCTAssertEqual(report.detectionMetrics.status, .failed)
    XCTAssertEqual(report.reliabilityMetrics.status, .failed)
  }

  func testOCRPresentImageScoresNutritionAccuracy() {
    let entry = ScanBenchmarkCorpusEntry(
      id: "ocr",
      resourceName: "ocr",
      resourceExtension: "png",
      scenarioTags: ["ocr"],
      expectedIngredientIds: [1],
      expectedNutrition: ScanBenchmarkExpectedNutrition(
        caloriesPerServing: 210,
        servingSize: "1 cup (240g)",
        servingsPerContainer: 2
      )
    )

    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry,
      runs: [
        run(
          iteration: 0,
          detections: [detection(1, bucket: .auto)],
          nutrition: ScanBenchmarkObservedNutrition(
            caloriesPerServing: 210,
            servingSize: "1 cup (240g)",
            servingsPerContainer: 2
          )
        )
      ],
      gates: gates()
    )

    XCTAssertEqual(report.ocrMetrics.status, .measured)
    XCTAssertEqual(report.ocrMetrics.parseSuccessRate ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.caloriesAccuracy ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.servingSizeAccuracy ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.servingsPerContainerAccuracy ?? -1, 1, accuracy: 0.0001)
  }

  func testEmptyRepeatedDetectionsDoNotCountAsReliable() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: exactMatchEntry(),
      runs: [
        run(iteration: 0, detections: []),
        run(iteration: 1, detections: []),
        run(iteration: 2, detections: []),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertNil(report.reliabilityMetrics.minJaccardVsFirstValid)
    XCTAssertEqual(report.reliabilityMetrics.validRunCount, 0)
    XCTAssertEqual(report.reliabilityMetrics.invalidRunCount, 3)
  }

  func testUnsupportedMetricsAreExplicitlyMarked() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: exactMatchEntry(),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.localizationMetric.status, .notSupported)
    XCTAssertEqual(report.amountMetric.status, .notSupported)
  }

  func testReportGenerationAggregatesSyntheticRuns() {
    let corpus = ScanBenchmarkCorpus(
      iterations: 2,
      gates: gates(),
      images: [exactMatchEntry()]
    )
    let imageReport = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: exactMatchEntry(),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
          ]),
        run(
          iteration: 1,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
          ]),
      ],
      gates: gates()
    )

    let report = ScanBenchmarkScorer.makeReport(corpus: corpus, imageReports: [imageReport])

    XCTAssertEqual(report.status, .passed)
    XCTAssertEqual(report.summary.imageCount, 1)
    XCTAssertEqual(report.summary.passedImageCount, 1)
    XCTAssertEqual(report.summary.invalidImageCount, 0)
    XCTAssertEqual(report.summary.overallDetectionF1 ?? -1, 1, accuracy: 0.0001)
  }

  func testMakeReportWithoutImagesIsInvalid() {
    let corpus = ScanBenchmarkCorpus(
      iterations: 2,
      gates: gates(),
      images: [exactMatchEntry()]
    )

    let report = ScanBenchmarkScorer.makeReport(corpus: corpus, imageReports: [])

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.invalidReason, "No benchmark images were evaluated.")
    XCTAssertEqual(report.summary.imageCount, 0)
  }

  func testReliabilityRegressionUsesDisagreeingValidRuns() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: exactMatchEntry(),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
          ]),
        run(
          iteration: 1,
          detections: [
            detection(1, bucket: .auto)
          ]),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .regressed)
    XCTAssertEqual(report.reliabilityMetrics.status, .measured)
    XCTAssertEqual(report.reliabilityMetrics.validRunCount, 2)
    XCTAssertEqual(report.reliabilityMetrics.minJaccardVsFirstValid ?? -1, 0.5, accuracy: 0.0001)
  }

  private func exactMatchEntry() -> ScanBenchmarkCorpusEntry {
    ScanBenchmarkCorpusEntry(
      id: "exact",
      resourceName: "exact",
      resourceExtension: "png",
      scenarioTags: ["synthetic"],
      expectedIngredientIds: [1, 2]
    )
  }

  private func run(
    iteration: Int,
    detections: [ScanBenchmarkObservedDetection],
    nutrition: ScanBenchmarkObservedNutrition? = nil
  ) -> ScanBenchmarkRunObservation {
    ScanBenchmarkRunObservation(
      iteration: iteration,
      detections: detections,
      nutrition: nutrition,
      elapsedMs: 1200
    )
  }

  private func detection(
    _ ingredientId: Int64,
    alternatives: [Int64] = [],
    bucket: ScanBenchmarkDetectionBucket
  ) -> ScanBenchmarkObservedDetection {
    ScanBenchmarkObservedDetection(
      ingredientId: ingredientId,
      alternativeIngredientIds: alternatives,
      bucket: bucket
    )
  }

  private func gates() -> ScanBenchmarkGates {
    ScanBenchmarkGates(
      minimumDetectionF1: 0.8,
      minimumCorrectionCoverage: 0.5,
      minimumOCRFieldAccuracy: 0.8,
      minimumReliabilityJaccard: 0.8,
      targetMedianElapsedMs: 8000
    )
  }
}
