import FLFeatureLogic
import Foundation
import XCTest

/// Hardening tests for the scan benchmark scorer's public invariants.
///
/// Pins the aggregation math, status precedence, determinism, and Codable contract of
/// `ScanBenchmarkScorer.evaluateImage` / `makeReport` so a refactor that silently changes
/// report semantics fails here before it reaches CI consumers. Tests-only part: suspected
/// defects are reported to the owner parts, not fixed in this change.
final class ScanBenchmarkInvariantsHardeningTests: XCTestCase {
  // MARK: - Summary counts

  func testSummaryStatusCountsPartitionImageCount() {
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [
        imageReport(id: "pass-a", runs: [perfectRun(0, elapsedMs: 1200)]),
        imageReport(id: "pass-b", runs: [perfectRun(0, elapsedMs: 1300)]),
        imageReport(id: "regress-latency", runs: [perfectRun(0, elapsedMs: 9000)]),
        imageReport(id: "invalid-a", runs: [erroredRun(0, message: "boom")]),
      ],
      createdAt: fixedDate()
    )

    XCTAssertEqual(report.summary.imageCount, 4)
    XCTAssertEqual(report.summary.passedImageCount, 2)
    XCTAssertEqual(report.summary.regressedImageCount, 1)
    XCTAssertEqual(report.summary.invalidImageCount, 1)
    // ScanBenchmarkStatus has exactly three cases, so every image lands in one bucket
    // and the three counts must always sum to the total.
    XCTAssertEqual(
      report.summary.passedImageCount
        + report.summary.regressedImageCount
        + report.summary.invalidImageCount,
      report.summary.imageCount
    )
  }

  // MARK: - Overall aggregates

  func testOverallDetectionF1IsMeanOfMeasuredImageF1Values() {
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [
        imageReport(id: "pass-a", runs: [perfectRun(0)]),  // f1 1.0
        imageReport(id: "pass-b", runs: [perfectRun(0)]),  // f1 1.0
        // precision 1, recall 1/3 -> f1 0.5; latency stays under the gate so only
        // detection regresses.
        imageReport(
          id: "regress-recall",
          runs: [perfectRun(0, ids: [1], elapsedMs: 1300)],
          expected: [1, 2, 3]
        ),
        imageReport(id: "invalid-a", runs: [erroredRun(0, message: "boom")]),  // f1 nil
      ],
      createdAt: fixedDate()
    )

    XCTAssertNil(report.images.last?.detectionMetrics.f1)
    XCTAssertEqual(
      report.summary.overallDetectionF1 ?? -1,
      (1.0 + 1.0 + 0.5) / 3.0,
      accuracy: 0.0001
    )
  }

  func testOverallMedianElapsedMsIsMedianOfPerImageMedians() {
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [
        imageReport(id: "a", runs: [perfectRun(0, elapsedMs: 1200)]),
        imageReport(id: "b", runs: [perfectRun(0, elapsedMs: 3000)]),
        imageReport(id: "c", runs: [perfectRun(0, elapsedMs: 9000)]),
        imageReport(id: "invalid-a", runs: [erroredRun(0, message: "boom")]),
      ],
      createdAt: fixedDate()
    )

    XCTAssertNil(report.images.last?.latencyMetrics.medianElapsedMs)
    // Odd count of measured images keeps this assertion neutral to the even-count
    // median convention pinned separately below.
    XCTAssertEqual(report.summary.overallMedianElapsedMs, 3000)
  }

  func testOverallMinimumReliabilityJaccardIsMinOfPerImageMinimums() {
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [
        imageReport(id: "a", runs: [perfectRun(0)]),  // min jaccard 1.0
        imageReport(id: "b", runs: [perfectRun(0, elapsedMs: 9000)]),  // min jaccard 1.0
        // Runs [1, 2] vs [1] agree on half the union.
        imageReport(id: "c", runs: [perfectRun(0), perfectRun(1, ids: [1])]),  // 0.5
        imageReport(id: "invalid-a", runs: [erroredRun(0, message: "boom")]),  // nil
      ],
      createdAt: fixedDate()
    )

    XCTAssertNil(report.images.last?.reliabilityMetrics.minJaccardVsFirstValid)
    XCTAssertEqual(
      report.summary.overallMinimumReliabilityJaccard ?? -1,
      0.5,
      accuracy: 0.0001
    )
  }

  // MARK: - Overall status mapping

  func testOverallStatusPrecedenceIsInvalidThenRegressedThenPassed() {
    let passed = imageReport(id: "pass-a", runs: [perfectRun(0)])
    let regressed = imageReport(id: "regress-latency", runs: [perfectRun(0, elapsedMs: 9000)])
    let invalid = imageReport(id: "invalid-a", runs: [erroredRun(0, message: "boom")])

    let mixed = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [passed, regressed, invalid],
      createdAt: fixedDate()
    )
    XCTAssertEqual(mixed.status, .invalid)
    XCTAssertNotNil(mixed.invalidReason)

    let noInvalid = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [passed, regressed],
      createdAt: fixedDate()
    )
    XCTAssertEqual(noInvalid.status, .regressed)
    XCTAssertNil(noInvalid.invalidReason)

    let allPassed = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [passed, passed],
      createdAt: fixedDate()
    )
    XCTAssertEqual(allPassed.status, .passed)
    XCTAssertNil(allPassed.invalidReason)
  }

  func testOverallInvalidReasonComesFromFirstInvalidImageInArrayOrder() {
    let firstInvalid = imageReport(id: "invalid-b", runs: [erroredRun(0, message: "stale cache")])
    let secondInvalid = imageReport(id: "invalid-c", runs: [erroredRun(0, message: "disk full")])
    let passed = imageReport(id: "pass-a", runs: [perfectRun(0)])

    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [passed, firstInvalid, secondInvalid],
      createdAt: fixedDate()
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.invalidReason, "Scan error: stale cache")
  }

  func testMakeReportWithoutImagesIsInvalidWithEmptyAggregates() {
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [],
      createdAt: fixedDate()
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.invalidReason, "No benchmark images were evaluated.")
    XCTAssertEqual(report.summary.imageCount, 0)
    XCTAssertEqual(report.summary.passedImageCount, 0)
    XCTAssertEqual(report.summary.regressedImageCount, 0)
    XCTAssertEqual(report.summary.invalidImageCount, 0)
    XCTAssertNil(report.summary.overallDetectionF1)
    XCTAssertNil(report.summary.overallMinimumReliabilityJaccard)
    XCTAssertNil(report.summary.overallMedianElapsedMs)
  }

  // MARK: - Determinism, dates, Codable, corpus plumbing

  func testReportCodableRoundTripPreservesFullGraph() throws {
    let report = mixedGraphReport()

    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(ScanBenchmarkReport.self, from: data)

    XCTAssertEqual(decoded, report)
  }

  func testCreatedAtISO8601ParsesBackToTheOriginalInstant() {
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [],
      createdAt: fixedDate()
    )

    let parsed = ISO8601DateFormatter().date(from: report.createdAtISO8601)
    XCTAssertEqual(parsed, fixedDate())
  }

  func testIdenticalInputsWithFixedCreatedAtProduceIdenticalReports() {
    XCTAssertEqual(mixedGraphReport(), mixedGraphReport())
  }

  func testCorpusGatesAndIterationsPropagateVerbatimIntoReport() {
    let customGates = ScanBenchmarkGates(
      minimumDetectionF1: 0.77,
      minimumCorrectionCoverage: 0.66,
      minimumOCRFieldAccuracy: 0.55,
      minimumReliabilityJaccard: 0.44,
      targetMedianElapsedMs: 4444
    )
    let image = imageReport(id: "pass-a", runs: [perfectRun(0, elapsedMs: 1200)], gates: customGates)
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(gates: customGates, iterations: 7),
      imageReports: [image],
      createdAt: fixedDate()
    )

    XCTAssertEqual(image.status, .passed)
    XCTAssertEqual(report.gates, customGates)
    XCTAssertEqual(report.iterations, 7)
    XCTAssertEqual(image.latencyMetrics.targetMedianElapsedMs, 4444)
    XCTAssertEqual(image.reliabilityMetrics.requiredJaccard, 0.44, accuracy: 0.0001)
  }

  func testImageReportCarriesCorpusEntryIdentityVerbatim() {
    let report = imageReport(
      id: "photo-42",
      runs: [perfectRun(0, ids: [3, 7, 9])],
      expected: [3, 7, 9],
      scenarioTags: ["ocr", "low-light"]
    )

    XCTAssertEqual(report.id, "photo-42")
    XCTAssertEqual(report.scenarioTags, ["ocr", "low-light"])
    XCTAssertEqual(report.expectedIngredientIds, [3, 7, 9])
    XCTAssertEqual(report.status, .passed)
  }

  // MARK: - Run validity semantics

  func testSingleInvalidRunAmongValidRunsMarksImageInvalid() {
    // Design choice (pinned): one invalid run poisons the whole image even when three
    // valid runs measured cleanly. Raised as a SUSPECTED concern in the fleet report.
    let report = imageReport(
      id: "mixed-validity",
      runs: [
        perfectRun(0, elapsedMs: 1000),
        perfectRun(1, elapsedMs: 2000),
        perfectRun(2, elapsedMs: 3000),
        passErroredRun(3, errors: ["pass 2 failed"], elapsedMs: 9999),
      ]
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.invalidReason, "Scan reported 1 pass error(s).")
    XCTAssertEqual(report.reliabilityMetrics.validRunCount, 3)
    XCTAssertEqual(report.reliabilityMetrics.invalidRunCount, 1)
    XCTAssertEqual(report.detectionMetrics.status, .measured)
    // Latency is measured over valid runs only: the median of [1000, 2000, 3000] is
    // 2000, which also proves the 9999 ms invalid run was excluded.
    XCTAssertEqual(report.latencyMetrics.medianElapsedMs, 2000)
  }

  func testRunLevelInvalidReasonPrecedenceErrorThenPassErrorsThenEmptyDetections() {
    let report = imageReport(
      id: "invalid-runs",
      runs: [
        ScanBenchmarkRunObservation(
          iteration: 0,
          detections: [],
          elapsedMs: 1200,
          passErrors: ["ignored"],
          errorDescription: "boom"
        ),
        ScanBenchmarkRunObservation(
          iteration: 1,
          detections: [detection(1, bucket: .auto), detection(2, bucket: .auto)],
          elapsedMs: 1300,
          passErrors: ["first", "second"]
        ),
        ScanBenchmarkRunObservation(iteration: 2, detections: [], elapsedMs: 1400),
      ]
    )

    XCTAssertEqual(report.runs[0].invalidReason, "Scan error: boom")
    XCTAssertEqual(report.runs[1].invalidReason, "Scan reported 2 pass error(s).")
    XCTAssertEqual(report.runs[2].invalidReason, "Expected non-empty detections but scan returned none.")
    XCTAssertFalse(report.runs[0].valid)
    XCTAssertFalse(report.runs[1].valid)
    XCTAssertFalse(report.runs[2].valid)
  }

  // MARK: - Gate behavior

  func testLatencyGateBoundaryPassesAtTargetAndRegressesStrictlyAbove() {
    let atTarget = imageReport(id: "at-target", runs: [perfectRun(0, elapsedMs: 8000)])
    let aboveTarget = imageReport(id: "above-target", runs: [perfectRun(0, elapsedMs: 8001)])

    XCTAssertEqual(atTarget.status, .passed)
    XCTAssertEqual(aboveTarget.status, .regressed)
    XCTAssertEqual(aboveTarget.latencyMetrics.medianElapsedMs, 8001)
  }

  func testPerfectDetectionsLeaveCorrectionCoverageNotSupported() {
    let report = imageReport(id: "perfect", runs: [perfectRun(0)])

    XCTAssertEqual(report.status, .passed)
    XCTAssertEqual(report.correctionMetrics.status, .notSupported)
    XCTAssertNil(report.correctionMetrics.alternativeCoverageRate)
    XCTAssertEqual(report.correctionMetrics.topPredictionAcceptanceRate ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.correctionMetrics.missedExpectationCount, 0)
  }

  func testFailedNutritionParseCountsAsZeroAccuracyAndCanRegress() {
    let report = imageReport(
      id: "ocr-partial",
      runs: [
        ScanBenchmarkRunObservation(
          iteration: 0,
          detections: [detection(1, bucket: .auto)],
          nutrition: ScanBenchmarkObservedNutrition(
            caloriesPerServing: 210,
            servingSize: "1 cup (240g)",
            servingsPerContainer: 2
          ),
          elapsedMs: 1200
        ),
        ScanBenchmarkRunObservation(
          iteration: 1,
          detections: [detection(1, bucket: .auto)],
          nutrition: nil,
          elapsedMs: 1300
        ),
      ],
      expected: [1],
      nutrition: ScanBenchmarkExpectedNutrition(
        caloriesPerServing: 210,
        servingSize: "1 cup (240g)",
        servingsPerContainer: 2
      )
    )

    XCTAssertEqual(report.ocrMetrics.status, .measured)
    XCTAssertEqual(report.ocrMetrics.parseSuccessRate ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.caloriesAccuracy ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.servingSizeAccuracy ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.servingsPerContainerAccuracy ?? -1, 0.5, accuracy: 0.0001)
    // OCR is the only regressing dimension here: detection, latency, and reliability
    // are all clean, so this pins that OCR alone can regress an image.
    XCTAssertEqual(report.status, .regressed)
  }

  func testCalibrationMetricsAggregatePerBucketAcrossValidRuns() {
    let report = imageReport(
      id: "calibration",
      runs: [
        ScanBenchmarkRunObservation(
          iteration: 0,
          detections: [detection(1, bucket: .auto), detection(99, bucket: .confirm)],
          elapsedMs: 1200
        ),
        ScanBenchmarkRunObservation(
          iteration: 1,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .auto),
            detection(7, bucket: .possible),
          ],
          elapsedMs: 1300
        ),
      ]
    )

    let calibration = report.calibrationMetrics
    XCTAssertEqual(calibration.map(\.bucket), [.auto, .confirm, .possible])
    XCTAssertEqual(calibration[0].sampleCount, 3)
    XCTAssertEqual(calibration[0].matchedCount, 3)
    XCTAssertEqual(calibration[0].precision ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(calibration[1].sampleCount, 1)
    XCTAssertEqual(calibration[1].matchedCount, 0)
    XCTAssertEqual(calibration[1].precision ?? -1, 0, accuracy: 0.0001)
    XCTAssertEqual(calibration[2].sampleCount, 1)
    XCTAssertEqual(calibration[2].matchedCount, 0)
    XCTAssertEqual(calibration[2].precision ?? -1, 0, accuracy: 0.0001)
  }

  func testEvenRunCountMedianTakesUpperMiddleElement() {
    // Pins the current Int-median convention: for an even sample count the scorer
    // reports the upper middle element (2000 for [1000, 2000]), not an interpolated
    // mean. Flagged in the fleet report's SUSPECTED section.
    let image = imageReport(
      id: "even-median",
      runs: [perfectRun(0, elapsedMs: 1000), perfectRun(1, elapsedMs: 2000)]
    )
    let report = ScanBenchmarkScorer.makeReport(
      corpus: corpus(),
      imageReports: [image],
      createdAt: fixedDate()
    )

    XCTAssertEqual(image.latencyMetrics.medianElapsedMs, 2000)
    XCTAssertEqual(report.summary.overallMedianElapsedMs, 2000)
  }

  // MARK: - Builders

  private func mixedGraphReport() -> ScanBenchmarkReport {
    ScanBenchmarkScorer.makeReport(
      corpus: corpus(iterations: 3),
      imageReports: [
        imageReport(id: "pass-a", runs: [perfectRun(0, elapsedMs: 1200)]),
        imageReport(
          id: "ocr-pass",
          runs: [
            ScanBenchmarkRunObservation(
              iteration: 0,
              detections: [detection(1, bucket: .auto)],
              nutrition: ScanBenchmarkObservedNutrition(
                caloriesPerServing: 210,
                servingSize: "1 cup (240g)",
                servingsPerContainer: 2
              ),
              elapsedMs: 1500
            )
          ],
          expected: [1],
          nutrition: ScanBenchmarkExpectedNutrition(
            caloriesPerServing: 210,
            servingSize: "1 cup (240g)",
            servingsPerContainer: 2
          )
        ),
        imageReport(id: "regress-reliability", runs: [perfectRun(0), perfectRun(1, ids: [1])]),
        imageReport(id: "invalid-a", runs: [erroredRun(0, message: "boom")]),
      ],
      createdAt: fixedDate()
    )
  }

  private func imageReport(
    id: String,
    runs: [ScanBenchmarkRunObservation],
    expected: [Int64] = [1, 2],
    scenarioTags: [String] = ["synthetic"],
    nutrition: ScanBenchmarkExpectedNutrition? = nil,
    gates: ScanBenchmarkGates? = nil
  ) -> ScanBenchmarkImageReport {
    ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(id: id, expected: expected, scenarioTags: scenarioTags, nutrition: nutrition),
      runs: runs,
      gates: gates ?? self.gates()
    )
  }

  private func entry(
    id: String,
    expected: [Int64] = [1, 2],
    scenarioTags: [String] = ["synthetic"],
    nutrition: ScanBenchmarkExpectedNutrition? = nil
  ) -> ScanBenchmarkCorpusEntry {
    ScanBenchmarkCorpusEntry(
      id: id,
      resourceName: id,
      resourceExtension: "png",
      scenarioTags: scenarioTags,
      expectedIngredientIds: expected,
      expectedNutrition: nutrition
    )
  }

  private func corpus(
    gates: ScanBenchmarkGates? = nil,
    iterations: Int = 2
  ) -> ScanBenchmarkCorpus {
    ScanBenchmarkCorpus(iterations: iterations, gates: gates ?? self.gates(), images: [])
  }

  private func perfectRun(
    _ iteration: Int,
    ids: [Int64] = [1, 2],
    elapsedMs: Int = 1200
  ) -> ScanBenchmarkRunObservation {
    ScanBenchmarkRunObservation(
      iteration: iteration,
      detections: ids.map { detection($0, bucket: .auto) },
      nutrition: nil,
      elapsedMs: elapsedMs
    )
  }

  private func erroredRun(
    _ iteration: Int,
    message: String,
    elapsedMs: Int = 1200
  ) -> ScanBenchmarkRunObservation {
    ScanBenchmarkRunObservation(
      iteration: iteration,
      detections: [],
      nutrition: nil,
      elapsedMs: elapsedMs,
      passErrors: [],
      errorDescription: message
    )
  }

  private func passErroredRun(
    _ iteration: Int,
    errors: [String],
    ids: [Int64] = [1, 2],
    elapsedMs: Int = 9999
  ) -> ScanBenchmarkRunObservation {
    ScanBenchmarkRunObservation(
      iteration: iteration,
      detections: ids.map { detection($0, bucket: .auto) },
      nutrition: nil,
      elapsedMs: elapsedMs,
      passErrors: errors
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

  private func fixedDate() -> Date {
    Date(timeIntervalSince1970: 1_700_000_000)
  }
}
