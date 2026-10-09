import FLFeatureLogic
import Foundation
import XCTest

/// Hardening tests for the scoring half of `ScanBenchmarkScorer` (run reports,
/// detection/correction/calibration metrics, harmonic mean, invalid reasons).
/// All behavior is driven through the public `evaluateImage` entry point.
final class ScanBenchmarkScoringDetectionHardeningTests: XCTestCase {
  // MARK: - Correction metrics vs duplicate detections

  /// BUG PROOF (fails against current code): duplicate detections of the same
  /// expected ingredient inflate `topPredictionAcceptanceRate` because the
  /// numerator and denominator count raw detection instances, while
  /// `detectionMetrics.precision` deduplicates via `Set`. Two detections of
  /// ingredient 1 plus one miss currently score 2/3 acceptance against a
  /// precision of 1/2 — correction metrics look better than detection metrics
  /// purely because of duplication. One repeated detection of an ingredient is
  /// one top prediction, not two acceptance opportunities.
  func testDuplicateDetectionsDoNotInflateTopPredictionAcceptanceRate() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(1, bucket: .confirm),
            detection(99, bucket: .possible),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.correctionMetrics.topPredictionAcceptanceRate ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(
      report.correctionMetrics.topPredictionAcceptanceRate ?? -1,
      report.detectionMetrics.precision ?? -2,
      accuracy: 0.0001
    )
    // Duplication must not distort alternative coverage either: the only miss
    // (ingredient 2) is not covered by any alternative.
    XCTAssertEqual(report.correctionMetrics.alternativeCoverageRate ?? -1, 0, accuracy: 0.0001)
  }

  /// Duplicated *unexpected* detections must not drag the acceptance rate below
  /// the deduplicated precision either: [1, 99, 99] is one correct prediction
  /// out of two distinct ones (0.5), not one out of three instances (0.333…).
  func testDuplicateUnexpectedDetectionsDoNotDistortTopPredictionAcceptanceRate() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(99, bucket: .confirm),
            detection(99, bucket: .confirm),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.correctionMetrics.topPredictionAcceptanceRate ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(
      report.correctionMetrics.topPredictionAcceptanceRate ?? -1,
      report.detectionMetrics.precision ?? -2,
      accuracy: 0.0001
    )
  }

  /// Intentional pin: with zero missed expectations there is nothing for
  /// alternatives to cover, so the coverage dimension is reported as
  /// `.notSupported` (with a nil rate) instead of a vacuous 100%. The
  /// top-prediction acceptance rate is still measured.
  func testPerfectDetectionReportsCorrectionCoverageAsNotSupported() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
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

    XCTAssertEqual(report.correctionMetrics.status, .notSupported)
    XCTAssertNil(report.correctionMetrics.alternativeCoverageRate)
    XCTAssertEqual(report.correctionMetrics.topPredictionAcceptanceRate ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.correctionMetrics.missedExpectationCount, 0)
  }

  /// Alternative coverage is averaged per run over only the runs that missed
  /// something; runs with full detection contribute no coverage sample. The
  /// missed-expectation count accumulates across all valid runs.
  func testCorrectionCoverageIsAveragedPerRunWithMisses() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2, 3]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, alternatives: [3], bucket: .confirm),
          ]),
        run(
          iteration: 1,
          detections: [
            detection(1, alternatives: [2], bucket: .auto)
          ]),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.correctionMetrics.status, .measured)
    // Run 0: misses {3}, covered → 1.0. Run 1: misses {2, 3}, covers {2} → 0.5.
    XCTAssertEqual(report.correctionMetrics.alternativeCoverageRate ?? -1, 0.75, accuracy: 0.0001)
    // Run 0: 2/2 top predictions expected. Run 1: 1/1.
    XCTAssertEqual(report.correctionMetrics.topPredictionAcceptanceRate ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.correctionMetrics.missedExpectationCount, 3)
  }

  // MARK: - Calibration metrics

  /// Intentional pin: the runner's `mapBucket` exhaustively maps the three
  /// `ConfidenceBucket` cases, so calibration covers exactly the buckets the
  /// pipeline can emit, with per-bucket sample/match/precision accounting.
  func testCalibrationMetricsMeasureOnlyRunnerEmittableBuckets() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
            detection(99, bucket: .possible),
          ]),
        run(
          iteration: 1,
          detections: [
            detection(1, bucket: .auto),
            detection(99, bucket: .confirm),
          ]),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.calibrationMetrics.count, 3)
    XCTAssertEqual(report.calibrationMetrics.map(\.bucket), [.auto, .confirm, .possible])

    let auto = report.calibrationMetrics[0]
    XCTAssertEqual(auto.status, .measured)
    XCTAssertEqual(auto.sampleCount, 2)
    XCTAssertEqual(auto.matchedCount, 2)
    XCTAssertEqual(auto.precision ?? -1, 1, accuracy: 0.0001)

    let confirm = report.calibrationMetrics[1]
    XCTAssertEqual(confirm.status, .measured)
    XCTAssertEqual(confirm.sampleCount, 2)
    XCTAssertEqual(confirm.matchedCount, 1)
    XCTAssertEqual(confirm.precision ?? -1, 0.5, accuracy: 0.0001)

    let possible = report.calibrationMetrics[2]
    XCTAssertEqual(possible.status, .measured)
    XCTAssertEqual(possible.sampleCount, 1)
    XCTAssertEqual(possible.matchedCount, 0)
    XCTAssertEqual(possible.precision ?? -1, 0, accuracy: 0.0001)
  }

  /// A bucket with no detections is `.notSupported` with a nil precision, not
  /// a zero-precision measured row.
  func testCalibrationMetricsMarkEmptyBucketsAsNotSupported() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(99, bucket: .possible),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.calibrationMetrics[0].status, .measured)
    XCTAssertEqual(report.calibrationMetrics[0].precision ?? -1, 1, accuracy: 0.0001)

    XCTAssertEqual(report.calibrationMetrics[1].bucket, .confirm)
    XCTAssertEqual(report.calibrationMetrics[1].status, .notSupported)
    XCTAssertEqual(report.calibrationMetrics[1].sampleCount, 0)
    XCTAssertNil(report.calibrationMetrics[1].precision)

    XCTAssertEqual(report.calibrationMetrics[2].status, .measured)
    XCTAssertEqual(report.calibrationMetrics[2].precision ?? -1, 0, accuracy: 0.0001)
  }

  // MARK: - Invalid reasons and precedence

  /// Intentional pin of invalid-reason precedence: within a run, a fatal scan
  /// error description outranks pass errors; across runs, the first invalid run
  /// supplies the image-level reason.
  func testScanErrorBeatsPassErrorsInInvalidReason() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(
          iteration: 0,
          detections: [],
          passErrors: ["pass A failed"],
          errorDescription: "vision crashed"
        ),
        run(iteration: 1, detections: [detection(1, bucket: .auto)], passErrors: ["pass B failed"]),
      ],
      gates: gates()
    )

    XCTAssertFalse(report.runs[0].valid)
    XCTAssertEqual(report.runs[0].invalidReason, "Scan error: vision crashed")
    XCTAssertFalse(report.runs[1].valid)
    XCTAssertEqual(report.runs[1].invalidReason, "Scan reported 1 pass error(s).")
    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.invalidReason, "Scan error: vision crashed")
  }

  /// Pass errors invalidate a run even when detections came back, and the run
  /// is excluded from the valid-run metric set.
  func testPassErrorsInvalidateRunEvenWithDetections() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1]),
      runs: [
        run(iteration: 0, detections: [detection(1, bucket: .auto)], passErrors: ["bbox decode failed"]),
      ],
      gates: gates()
    )

    XCTAssertFalse(report.runs[0].valid)
    XCTAssertEqual(report.runs[0].invalidReason, "Scan reported 1 pass error(s).")
    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.detectionMetrics.status, .failed)
    XCTAssertEqual(report.correctionMetrics.status, .failed)
    XCTAssertEqual(report.reliabilityMetrics.status, .failed)
  }

  /// Intentional pin: pass errors outrank the empty-detections reason, so an
  /// errored run that also returned nothing reports the pass-error count, not
  /// the "expected non-empty detections" message.
  func testPassErrorsOutrankEmptyDetectionsInInvalidReason() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(iteration: 0, detections: [], passErrors: ["p1", "p2"]),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.runs[0].invalidReason, "Scan reported 2 pass error(s).")
  }

  // MARK: - Empty-expectation conventions

  /// Intentional pin: a corpus entry with no expected ingredients produces
  /// valid runs even when the scan detects things, and recall is vacuously 1
  /// (nothing could be missed). Precision is 0 because nothing detected can
  /// match an empty expectation set. The resulting f1 of 0 flags such entries
  /// as regressed via the detection gate — see the hardening report.
  func testExpectedEmptyEntryWithDetectionsIsValidWithVacuousRecall() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: []),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(99, bucket: .confirm),
          ])
      ],
      gates: gates()
    )

    XCTAssertTrue(report.runs[0].valid)
    XCTAssertNil(report.runs[0].invalidReason)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 0, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 0, accuracy: 0.0001)
  }

  /// Expected-empty entry with an empty scan is still a valid run (nothing was
  /// expected, nothing arrived), scoring precision 0 / recall 1 and therefore
  /// f1 = harmonicMean(0, 1) = 0. Pins the harmonic-mean convention for a
  /// zero argument paired with a positive one.
  func testExpectedEmptyEntryWithNoDetectionsIsValid() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: []),
      runs: [
        run(iteration: 0, detections: [])
      ],
      gates: gates()
    )

    XCTAssertTrue(report.runs[0].valid)
    XCTAssertNil(report.runs[0].invalidReason)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 0, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 0, accuracy: 0.0001)
    // Empty detections in a valid run contribute a 0 acceptance sample.
    XCTAssertEqual(report.correctionMetrics.topPredictionAcceptanceRate ?? -1, 0, accuracy: 0.0001)
  }

  // MARK: - F1 as harmonic mean

  /// harmonicMean(0, 0) == 0: fully disjoint detections score zero precision,
  /// zero recall, and zero F1 — no division-by-zero, no spurious positive.
  func testDisjointDetectionsScoreZeroF1() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(3, bucket: .auto),
            detection(4, bucket: .auto),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 0, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 0, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 0, accuracy: 0.0001)
  }

  /// F1 must equal the harmonic mean of precision and recall: 2·P·R / (P+R).
  /// P = 2/3, R = 2/4 → F1 = 4/7 ≈ 0.5714. Guards the arithmetic of the
  /// harmonic-mean helper against regressions.
  func testPartialOverlapScoresF1AsHarmonicMean() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2, 3, 4]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(1, bucket: .auto),
            detection(2, bucket: .confirm),
            detection(99, bucket: .possible),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 2.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 4.0 / 7.0, accuracy: 0.0001)
  }

  // MARK: - Valid/invalid run isolation

  /// Invalid runs must be excluded from every valid-run metric: detection
  /// precision/recall, calibration samples, correction counts, and reliability
  /// all reflect only the valid runs, while the image itself is invalidated.
  func testInvalidRunsAreExcludedFromAllValidRunMetrics() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
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
            detection(99, bucket: .auto),
            detection(3, bucket: .possible),
          ],
          errorDescription: "boom"
        ),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.invalidReason, "Scan error: boom")

    // If the invalid run leaked in, precision would average to ~0.667.
    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 1, accuracy: 0.0001)

    // If the invalid run leaked in, the auto bucket would hold 3 samples
    // (2 matched) and the possible bucket 1 sample.
    XCTAssertEqual(report.calibrationMetrics[0].sampleCount, 1)
    XCTAssertEqual(report.calibrationMetrics[0].matchedCount, 1)
    XCTAssertEqual(report.calibrationMetrics[2].sampleCount, 0)

    // If the invalid run leaked in, ingredient 2 would count as missed.
    XCTAssertEqual(report.correctionMetrics.missedExpectationCount, 0)

    XCTAssertEqual(report.reliabilityMetrics.validRunCount, 1)
    XCTAssertEqual(report.reliabilityMetrics.invalidRunCount, 1)
  }

  /// When every run is invalid, calibration falls back to the default shape:
  /// one `.notSupported` row per runner-emittable bucket with zero samples and
  /// nil precision.
  func testDefaultCalibrationShapeWhenAllRunsInvalid() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(iteration: 0, detections: [], passErrors: ["p"]),
        run(iteration: 1, detections: [], passErrors: ["q"]),
      ],
      gates: gates()
    )

    XCTAssertEqual(report.status, .invalid)
    XCTAssertEqual(report.calibrationMetrics.count, 3)
    XCTAssertEqual(report.calibrationMetrics.map(\.bucket), [.auto, .confirm, .possible])
    for metric in report.calibrationMetrics {
      XCTAssertEqual(metric.status, .notSupported)
      XCTAssertEqual(metric.sampleCount, 0)
      XCTAssertEqual(metric.matchedCount, 0)
      XCTAssertNil(metric.precision)
    }
  }

  // MARK: - Run report shaping

  /// Run reports sort ingredient ids, sort and deduplicate alternative ids
  /// across detections, and carry the iteration and elapsed time through.
  func testRunReportSortsIngredientIdsAndDeduplicatesAlternatives() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: entry(expected: [1, 2]),
      runs: [
        run(
          iteration: 0,
          detections: [
            detection(9, alternatives: [8, 8], bucket: .auto),
            detection(1, alternatives: [3, 3, 2], bucket: .confirm),
          ])
      ],
      gates: gates()
    )

    XCTAssertEqual(report.runs.count, 1)
    XCTAssertEqual(report.runs[0].ingredientIds, [1, 9])
    XCTAssertEqual(report.runs[0].alternativeIngredientIds, [2, 3, 8])
    XCTAssertEqual(report.runs[0].iteration, 0)
    XCTAssertEqual(report.runs[0].elapsedMs, 1200)
    XCTAssertTrue(report.runs[0].valid)
  }

  // MARK: - Helpers

  private func entry(expected: [Int64]) -> ScanBenchmarkCorpusEntry {
    ScanBenchmarkCorpusEntry(
      id: "hardening",
      resourceName: "hardening",
      resourceExtension: "png",
      scenarioTags: ["synthetic"],
      expectedIngredientIds: expected
    )
  }

  private func run(
    iteration: Int,
    detections: [ScanBenchmarkObservedDetection],
    passErrors: [String] = [],
    errorDescription: String? = nil
  ) -> ScanBenchmarkRunObservation {
    ScanBenchmarkRunObservation(
      iteration: iteration,
      detections: detections,
      nutrition: nil,
      elapsedMs: 1200,
      passErrors: passErrors,
      errorDescription: errorDescription
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
