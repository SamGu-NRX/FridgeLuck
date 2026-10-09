import FLFeatureLogic
import XCTest

// Gap-filling suite audit. Every test below covers an input class, enum case, or
// error path that the existing FeatureLogic test files never exercise (or only
// exercise tautologically). Each test names the file whose gap it fills and the
// regression it is meant to catch. This file intentionally adds no source changes.

final class FeatureLogicSuiteGapTests: XCTestCase {
  // MARK: - AppFlowPolicy (gaps in AppFlowPolicyTests)

  // AppFlowPolicyTests covers progressEntryRoute for (false,false), (true,false), and
  // (true,true) but never (false,true). If the onboarding guard is ever reordered
  // below the tutorial check, a not-yet-onboarded user with a completed tutorial
  // would land in the progress tab. Pin the guard precedence.
  func testProgressEntryRouteStaysEmptyWhenTutorialCompleteButNotOnboarded() {
    XCTAssertEqual(
      AppFlowPolicy.progressEntryRoute(hasOnboarded: false, isTutorialComplete: true),
      .emptyState
    )
  }

  // tutorialKeysToClear is only tested with the preserved key present in the list.
  // The call site (ContentView reset) passes TutorialStorageKeys.all preserving
  // .progress; a regression that assumes the preserved key exists (e.g. dropping the
  // filter or misusing firstIndex) must not silently clear every stored key.
  func testResetPolicyKeepsAllKeysWhenPreservedKeyIsAbsent() {
    XCTAssertEqual(
      ResetPolicy.tutorialKeysToClear(
        allKeys: ["onboarding_seen", "spotlight_shown", "scan_hint"],
        preserving: "does_not_exist"
      ),
      ["onboarding_seen", "spotlight_shown", "scan_hint"]
    )
  }

  // MARK: - PermissionMapping (gaps in AppPermissionCenterTests)

  // Every mapper has an .unknown input case, but no existing test exercises it on any
  // surface. The app layer funnels @unknown-default OS cases into .unknown
  // (AppPermissionCenter.swift mapCameraAuthorizationState and siblings), so unknown
  // must degrade to .unavailable everywhere — including photo REQUEST results, where
  // unknown must never be treated as granted.
  func testUnknownAuthorizationStatesMapToUnavailableForEverySurface() {
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(cameraAvailable: true, authorizationState: .unknown),
      .unavailable
    )
    XCTAssertEqual(PermissionMapping.mapMicrophoneStatus(.unknown), .unavailable)
    XCTAssertEqual(PermissionMapping.mapPhotoStatus(.unknown), .unavailable)
    XCTAssertEqual(PermissionMapping.mapPhotoRequestResult(.unknown), .unavailable)
    XCTAssertEqual(PermissionMapping.mapNotificationStatus(.unknown), .unavailable)
  }

  // Camera unavailability is only tested with .authorized; nothing pins that hardware
  // unavailability wins over the authorization state. A reorder that checks the auth
  // state first would report denied/notDetermined hardware as usable.
  func testCameraUnavailableShortCircuitsBeforeAuthorizationState() {
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(cameraAvailable: false, authorizationState: .denied),
      .unavailable
    )
    XCTAssertEqual(
      PermissionMapping.mapCameraStatus(cameraAvailable: false, authorizationState: .notDetermined),
      .unavailable
    )
  }

  // MARK: - CookingGuideStateTransitions (gaps in CookingGuideStateTransitionsTests)

  // Existing toggle tests start from single-element sets only; nothing proves a
  // toggle leaves unrelated entries intact (e.g. a regression that rebuilds the set
  // from the toggled element alone).
  func testTogglesPreserveUnrelatedEntriesInCheckedAndCompletedSets() {
    var checked: Set<Int64> = [42, 43]
    CookingGuideStateTransitions.toggleIngredient(42, checkedIngredients: &checked)
    XCTAssertEqual(checked, [43])
    CookingGuideStateTransitions.toggleIngredient(44, checkedIngredients: &checked)
    XCTAssertEqual(checked, [43, 44])

    var completed: Set<Int> = [1, 2]
    CookingGuideStateTransitions.toggleCompletedStep(1, completedSteps: &completed)
    XCTAssertEqual(completed, [2])
    CookingGuideStateTransitions.toggleCompletedStep(3, completedSteps: &completed)
    XCTAssertEqual(completed, [2, 3])
  }

  // The call site (CookingGuideSections) maps a missing ingredient id to -1, so -1 is
  // a real value that flows through toggleIngredient and must behave like any other id.
  func testToggleIngredientHandlesNegativeSentinelIngredientID() {
    var checked: Set<Int64> = []
    CookingGuideStateTransitions.toggleIngredient(-1, checkedIngredients: &checked)
    XCTAssertEqual(checked, [-1])
    CookingGuideStateTransitions.toggleIngredient(-1, checkedIngredients: &checked)
    XCTAssertTrue(checked.isEmpty)
  }

  // 0 is a legitimate ingredient id and must map to substitution slot 0; only nil maps
  // to the -1 sentinel. A regression that collapses 0 into the nil branch (e.g.
  // `x <= 0 ? -1 : x`) would collide every zero id onto a single substitution slot.
  func testSubstitutionSlotTreatsZeroAsValidIngredientNotSentinel() {
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: 0), 0)
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: nil), -1)
  }

  // MARK: - DemoFallbackPolicy (gap in DemoFallbackPolicyTests)

  // Only detectionCount 0 is tested on the boundary; a `!= 0` rewrite of the gate
  // would admit negative counts into live vision.
  func testLiveVisionRejectedForNegativeDetectionCounts() {
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: true,
        detectionCount: -1
      )
    )
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: false,
        hasDemoImage: false,
        detectionCount: -1
      )
    )
  }

  // MARK: - RecommendationPolicy (replaces a tautological test in RecommendationPolicyTests)

  // RecommendationPolicyTests asserts effectiveIngredientIDs(from: []) equals
  // RecommendationPolicy.fallbackIngredientIDs — the constant compared with itself, so
  // drift in the actual fallback ids would go unnoticed. The ids are seeded ingredient
  // keys in apps/ios/Resources/data.json (1=egg, 2=rice, 5=onion, 6=garlic); pin the
  // literal set end to end.
  func testFallbackIngredientIDsPinTheSeededIngredientSet() {
    XCTAssertEqual(RecommendationPolicy.fallbackIngredientIDs, Set([1, 2, 5, 6]))
    XCTAssertEqual(RecommendationPolicy.effectiveIngredientIDs(from: []), Set([1, 2, 5, 6]))
  }

  // MARK: - LiveAssistantPanelLayout (gaps in LiveAssistantPanelLayoutTests)

  // testClampedHeightNeverDropsBelowPeek compares clampedHeight against the very same
  // height(in:) call, so drift in the detent height constants would go unnoticed. Pin
  // the actual metrics: peek is a fixed 116pt regardless of screen height, step is 38%
  // and full is 72% of the screen height.
  func testDetentHeightsPinPeekConstantAndScaledStepFull() {
    XCTAssertEqual(LiveAssistantPanelDetent.peek.height(in: 900), 116, accuracy: 0.001)
    XCTAssertEqual(LiveAssistantPanelDetent.peek.height(in: 500), 116, accuracy: 0.001)
    XCTAssertEqual(LiveAssistantPanelDetent.step.height(in: 1000), 380, accuracy: 0.001)
    XCTAssertEqual(LiveAssistantPanelDetent.full.height(in: 1000), 720, accuracy: 0.001)
  }

  // The lower clamp is tested but the upper clamp never is. Dragging up far past the
  // top must never exceed the full detent height; zero translation must return the
  // detent height unchanged.
  func testClampedHeightCapsAtFullPanelHeightWhenDraggingUp() {
    XCTAssertEqual(
      LiveAssistantPanelLayout.clampedHeight(for: .full, translation: -500, screenHeight: 900),
      648,
      accuracy: 0.001
    )
    XCTAssertEqual(
      LiveAssistantPanelLayout.clampedHeight(for: .step, translation: 0, screenHeight: 900),
      342,
      accuracy: 0.001
    )
  }

  // A gesture that ends without movement must not change the detent: current and
  // projected heights both equal the detent height, so any weighting that does not
  // preserve identity (sign flip, non-convex blend, clamp error) is caught.
  func testResolvedDetentStaysPutWithoutDrag() {
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .step,
        translation: 0,
        predictedEndTranslation: 0,
        screenHeight: 900
      ),
      .step
    )
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .full,
        translation: 0,
        predictedEndTranslation: 0,
        screenHeight: 900
      ),
      .full
    )
  }

  // A violent upward flick from peek must saturate at .full rather than skip past the
  // detent model; this relies on both height clamps feeding resolvedDetent.
  func testResolvedDetentSnapsToFullWhenFlickedFarUp() {
    XCTAssertEqual(
      LiveAssistantPanelLayout.resolvedDetent(
        from: .peek,
        translation: -2000,
        predictedEndTranslation: -2000,
        screenHeight: 900
      ),
      .full
    )
  }

  // MARK: - ScanBenchmarkScorer (gaps in ScanBenchmarkScorerTests)

  // The latency gate never fires in existing tests (every run uses elapsedMs 1200
  // against an 8000ms target), so dropping the median-latency check from isRegressed
  // would pass CI. A perfect-detection run over target proves latency alone regresses.
  func testLatencyGateRegressesWhenMedianElapsedExceedsTarget() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(expectedIngredientIds: [1, 2]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto), gapDetection(2, bucket: .confirm)],
          elapsedMs: 9000
        )
      ],
      gates: standardGates()
    )

    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.latencyMetrics.status, .measured)
    XCTAssertEqual(report.latencyMetrics.medianElapsedMs, 9000)
    XCTAssertEqual(report.latencyMetrics.p90ElapsedMs, 9000)
    XCTAssertEqual(report.status, .regressed)
  }

  // Run invalidation from passErrors and errorDescription is never exercised; existing
  // invalid-image tests only use empty detections. A run with detections but a scan
  // error (or pass errors) must still invalidate, with the reason preserved on both
  // the run report and the image report.
  func testRunInvalidationCoversScanErrorsAndPassErrors() {
    let errorReport = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "scan-error", expectedIngredientIds: [1]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto)],
          errorDescription: "camera busy"
        )
      ],
      gates: standardGates()
    )
    XCTAssertEqual(errorReport.status, .invalid)
    XCTAssertEqual(errorReport.runs.first?.valid, false)
    XCTAssertEqual(errorReport.runs.first?.invalidReason, "Scan error: camera busy")
    XCTAssertEqual(errorReport.invalidReason, "Scan error: camera busy")

    let passErrorReport = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "pass-error", expectedIngredientIds: [1]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto)],
          passErrors: ["ocr pass failed"]
        )
      ],
      gates: standardGates()
    )
    XCTAssertEqual(passErrorReport.status, .invalid)
    XCTAssertEqual(passErrorReport.runs.first?.valid, false)
    XCTAssertEqual(passErrorReport.runs.first?.invalidReason, "Scan reported 1 pass error(s).")
  }

  // OCR metric status for images with no valid runs is never asserted. With expected
  // nutrition present, a fully errored image must mark OCR .failed (not .notSupported);
  // a corpus entry without expected nutrition must mark OCR .notSupported even when
  // the image passes.
  func testOCRStatusFailsOrFallsBackDependingOnExpectedNutrition() {
    let nutrition = ScanBenchmarkExpectedNutrition(
      caloriesPerServing: 200,
      servingSize: "1 cup",
      servingsPerContainer: 2
    )
    let failedReport = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(
        id: "ocr-failed",
        expectedIngredientIds: [1],
        expectedNutrition: nutrition
      ),
      runs: [
        gapRun(iteration: 0, detections: [gapDetection(1, bucket: .auto)], errorDescription: "boom")
      ],
      gates: standardGates()
    )
    XCTAssertEqual(failedReport.status, .invalid)
    XCTAssertEqual(failedReport.ocrMetrics.status, .failed)
    XCTAssertNil(failedReport.ocrMetrics.parseSuccessRate)

    let unsupportedReport = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "ocr-none", expectedIngredientIds: [1]),
      runs: [
        gapRun(iteration: 0, detections: [gapDetection(1, bucket: .auto)])
      ],
      gates: standardGates()
    )
    XCTAssertEqual(unsupportedReport.status, .passed)
    XCTAssertEqual(unsupportedReport.ocrMetrics.status, .notSupported)
    XCTAssertNil(unsupportedReport.ocrMetrics.parseSuccessRate)
  }

  // Precision/recall are never asserted separately for a mixed run (the existing
  // partial-miss test has symmetric 2/3 for both). A false positive with perfect
  // recall pins which formula is which: precision 0.5, recall 1.0.
  func testDetectionMetricsKeepPrecisionAndRecallDistinct() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "pr", expectedIngredientIds: [1]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto), gapDetection(99, bucket: .possible)]
        )
      ],
      gates: standardGates()
    )

    XCTAssertEqual(report.detectionMetrics.precision ?? -1, 0.5, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.recall ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.f1 ?? -1, 2.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(report.detectionMetrics.averageDetectedCount ?? -1, 2, accuracy: 0.0001)
    XCTAssertEqual(report.status, .regressed)
  }

  // calibrationMetrics are entirely untested. Bucket precision, sample counts, and the
  // exclusion of the .unknown bucket (detections in .unknown contribute to no
  // calibration row) are all pinned here.
  func testCalibrationMetricsBucketPrecisionPerDetectionBucket() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "calib", expectedIngredientIds: [1, 2]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [
            gapDetection(1, bucket: .auto),
            gapDetection(99, bucket: .confirm),
            gapDetection(2, bucket: .possible),
            gapDetection(7, bucket: .unknown),
          ]
        )
      ],
      gates: standardGates()
    )

    let auto = report.calibrationMetrics.first { $0.bucket == .auto }
    let confirm = report.calibrationMetrics.first { $0.bucket == .confirm }
    let possible = report.calibrationMetrics.first { $0.bucket == .possible }

    XCTAssertEqual(auto?.status, .measured)
    XCTAssertEqual(auto?.sampleCount, 1)
    XCTAssertEqual(auto?.matchedCount, 1)
    XCTAssertEqual(auto?.precision ?? -1, 1, accuracy: 0.0001)

    XCTAssertEqual(confirm?.status, .measured)
    XCTAssertEqual(confirm?.sampleCount, 1)
    XCTAssertEqual(confirm?.matchedCount, 0)
    XCTAssertEqual(confirm?.precision ?? -1, 0, accuracy: 0.0001)

    XCTAssertEqual(possible?.status, .measured)
    XCTAssertEqual(possible?.sampleCount, 1)
    XCTAssertEqual(possible?.matchedCount, 1)
    XCTAssertEqual(possible?.precision ?? -1, 1, accuracy: 0.0001)
  }

  // Overall report status precedence is untested: invalid must beat regressed, and a
  // regressed-only report must surface .regressed with a nil invalid reason.
  func testMakeReportInvalidTakesPrecedenceOverRegressed() {
    let gates = standardGates()
    let regressedImage = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "regressed", expectedIngredientIds: [1, 2]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto), gapDetection(2, bucket: .confirm)],
          elapsedMs: 9000
        )
      ],
      gates: gates
    )
    let invalidImage = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "invalid", expectedIngredientIds: [1]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto)],
          errorDescription: "sensor failure"
        )
      ],
      gates: gates
    )
    XCTAssertEqual(regressedImage.status, .regressed)
    XCTAssertEqual(invalidImage.status, .invalid)

    let corpus = ScanBenchmarkCorpus(iterations: 1, gates: gates, images: [])
    let mixed = ScanBenchmarkScorer.makeReport(
      corpus: corpus,
      imageReports: [regressedImage, invalidImage]
    )
    XCTAssertEqual(mixed.status, .invalid)
    XCTAssertEqual(mixed.invalidReason, "Scan error: sensor failure")
    XCTAssertEqual(mixed.summary.imageCount, 2)
    XCTAssertEqual(mixed.summary.regressedImageCount, 1)
    XCTAssertEqual(mixed.summary.invalidImageCount, 1)
    XCTAssertEqual(mixed.summary.passedImageCount, 0)

    let regressedOnly = ScanBenchmarkScorer.makeReport(
      corpus: corpus,
      imageReports: [regressedImage]
    )
    XCTAssertEqual(regressedOnly.status, .regressed)
    XCTAssertNil(regressedOnly.invalidReason)
  }

  // Summary aggregation is only tested on all-valid input. An invalid image contributes
  // nil metrics that must be excluded from the means (not treated as zero): overall F1,
  // overall median latency, and overall minimum Jaccard come only from valid images.
  func testMakeReportOverallF1ExcludesInvalidImages() {
    let gates = standardGates()
    let passedImage = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "passed", expectedIngredientIds: [1, 2]),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto), gapDetection(2, bucket: .confirm)]
        )
      ],
      gates: gates
    )
    let invalidImage = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(id: "invalid", expectedIngredientIds: [1]),
      runs: [
        gapRun(iteration: 0, detections: [gapDetection(1, bucket: .auto)], errorDescription: "boom")
      ],
      gates: gates
    )

    let report = ScanBenchmarkScorer.makeReport(
      corpus: ScanBenchmarkCorpus(iterations: 1, gates: gates, images: []),
      imageReports: [passedImage, invalidImage]
    )

    XCTAssertEqual(report.summary.passedImageCount, 1)
    XCTAssertEqual(report.summary.invalidImageCount, 1)
    XCTAssertEqual(report.summary.overallDetectionF1 ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.summary.overallMedianElapsedMs, 1200)
    XCTAssertEqual(report.summary.overallMinimumReliabilityJaccard ?? -1, 1, accuracy: 0.0001)
  }

  // The scorer intentionally normalizes OCR strings (case-insensitive, whitespace
  // collapsed) before comparing against expected serving sizes. Exact-string matching
  // would be a behavior regression that existing tests cannot see.
  func testOCRServingSizeAccuracyNormalizesCaseAndWhitespace() {
    let report = ScanBenchmarkScorer.evaluateImage(
      corpusEntry: gapEntry(
        id: "ocr-normalize",
        expectedIngredientIds: [1],
        expectedNutrition: ScanBenchmarkExpectedNutrition(
          caloriesPerServing: 200,
          servingSize: "1 cup (240g)",
          servingsPerContainer: 2
        )
      ),
      runs: [
        gapRun(
          iteration: 0,
          detections: [gapDetection(1, bucket: .auto)],
          nutrition: ScanBenchmarkObservedNutrition(
            caloriesPerServing: 200,
            servingSize: "1  CUP  (240g)",
            servingsPerContainer: 2
          )
        )
      ],
      gates: standardGates()
    )

    XCTAssertEqual(report.ocrMetrics.status, .measured)
    XCTAssertEqual(report.ocrMetrics.servingSizeAccuracy ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.ocrMetrics.caloriesAccuracy ?? -1, 1, accuracy: 0.0001)
    XCTAssertEqual(report.status, .passed)
  }

  // MARK: - Builders

  private func gapEntry(
    id: String = "gap",
    expectedIngredientIds: [Int64],
    expectedNutrition: ScanBenchmarkExpectedNutrition? = nil
  ) -> ScanBenchmarkCorpusEntry {
    ScanBenchmarkCorpusEntry(
      id: id,
      resourceName: id,
      resourceExtension: "png",
      scenarioTags: ["synthetic"],
      expectedIngredientIds: expectedIngredientIds,
      expectedNutrition: expectedNutrition
    )
  }

  private func gapRun(
    iteration: Int,
    detections: [ScanBenchmarkObservedDetection],
    nutrition: ScanBenchmarkObservedNutrition? = nil,
    elapsedMs: Int = 1200,
    passErrors: [String] = [],
    errorDescription: String? = nil
  ) -> ScanBenchmarkRunObservation {
    ScanBenchmarkRunObservation(
      iteration: iteration,
      detections: detections,
      nutrition: nutrition,
      elapsedMs: elapsedMs,
      passErrors: passErrors,
      errorDescription: errorDescription
    )
  }

  private func gapDetection(
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

  private func standardGates() -> ScanBenchmarkGates {
    ScanBenchmarkGates(
      minimumDetectionF1: 0.8,
      minimumCorrectionCoverage: 0.5,
      minimumOCRFieldAccuracy: 0.8,
      minimumReliabilityJaccard: 0.8,
      targetMedianElapsedMs: 8000
    )
  }
}
