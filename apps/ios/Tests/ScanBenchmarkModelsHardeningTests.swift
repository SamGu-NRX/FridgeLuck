import FLFeatureLogic
import Foundation
import XCTest

/// Hardening tests for the scan-benchmark model layer (`ScanBenchmarkModels.swift`) and the
/// real `apps/ios/Resources/benchmark_manifest.json` that `ScanBenchmarkRunner.defaultCorpus`
/// decodes. Covers: manifest invariants (iteration count, rate gates, latency target, unique
/// image ids), Codable roundtrips for every public struct (optionals nil and non-nil, empty
/// arrays), and decode tolerance (omitted optional-shaped fields, unknown JSON keys).
final class ScanBenchmarkModelsHardeningTests: XCTestCase {

  // MARK: - Real manifest invariants

  func testManifestDecodesAsCorpusWithValidInvariants() throws {
    let corpus = try decodeManifestCorpus()

    XCTAssertGreaterThanOrEqual(
      corpus.iterations, 1, "manifest iterations must be >= 1, got \(corpus.iterations)")
    XCTAssertGreaterThan(
      corpus.gates.targetMedianElapsedMs, 0,
      "manifest targetMedianElapsedMs must be positive, got \(corpus.gates.targetMedianElapsedMs)")
    XCTAssertFalse(corpus.images.isEmpty, "benchmark corpus must contain at least one image")

    let namedRates: [(name: String, rate: Double)] = [
      ("minimumDetectionF1", corpus.gates.minimumDetectionF1),
      ("minimumCorrectionCoverage", corpus.gates.minimumCorrectionCoverage),
      ("minimumOCRFieldAccuracy", corpus.gates.minimumOCRFieldAccuracy),
      ("minimumReliabilityJaccard", corpus.gates.minimumReliabilityJaccard),
    ]
    for gate in namedRates {
      XCTAssertTrue(
        gate.rate >= 0 && gate.rate <= 1,
        "\(gate.name) must be within 0...1, got \(gate.rate)")
    }
  }

  func testManifestImageEntriesHaveUniqueIdsAndNonEmptyRequiredFields() throws {
    let corpus = try decodeManifestCorpus()

    var seenIds = Set<String>()
    for entry in corpus.images {
      XCTAssertTrue(
        seenIds.insert(entry.id).inserted,
        "duplicate benchmark image id in manifest: \(entry.id)")
      XCTAssertFalse(entry.id.isEmpty, "\(entry.id): id must be non-empty")
      XCTAssertFalse(entry.resourceName.isEmpty, "\(entry.id): resourceName must be non-empty")
      XCTAssertFalse(
        entry.resourceExtension.isEmpty, "\(entry.id): resourceExtension must be non-empty")
      XCTAssertFalse(
        entry.expectedIngredientIds.isEmpty,
        "\(entry.id): expectedIngredientIds must be non-empty")
    }
  }

  // MARK: - Decode tolerance

  func testRunObservationDecodesWithOmittedOptionalFields() throws {
    // `ScanBenchmarkRunObservation.init` defaults `passErrors` to [] (and `nutrition` /
    // `errorDescription` are Optionals), so observations serialized by callers that omit
    // defaulted/optional fields must still decode. Synthesized Decodable is stricter than
    // the public initializer: it throws keyNotFound for the non-optional-but-defaulted
    // `passErrors` array, which is why the model customizes decoding of that field.
    let data = Data(#"{"iteration": 0, "detections": [], "elapsedMs": 750}"#.utf8)
    let decoded = try JSONDecoder().decode(ScanBenchmarkRunObservation.self, from: data)

    XCTAssertEqual(decoded.iteration, 0)
    XCTAssertTrue(decoded.detections.isEmpty)
    XCTAssertNil(decoded.nutrition)
    XCTAssertTrue(decoded.passErrors.isEmpty)
    XCTAssertNil(decoded.errorDescription)
    XCTAssertEqual(decoded.elapsedMs, 750)
  }

  func testObservedDetectionDecodesWithOmittedAlternativeIngredientIds() throws {
    // Same shape as `passErrors`: the public init defaults `alternativeIngredientIds` to [],
    // so decoding must tolerate the key being omitted rather than throw keyNotFound.
    let data = Data(#"{"ingredientId": 3, "bucket": "possible"}"#.utf8)
    let decoded = try JSONDecoder().decode(ScanBenchmarkObservedDetection.self, from: data)

    XCTAssertEqual(decoded.ingredientId, 3)
    XCTAssertTrue(decoded.alternativeIngredientIds.isEmpty)
    XCTAssertEqual(decoded.bucket, .possible)
  }

  func testDecodersIgnoreUnknownJSONKeys() throws {
    // Forward compatibility: newer encoders may add keys (schemaVersion, thermal state,
    // new gates); the model layer must ignore them instead of failing the decode.
    let observationJSON = Data(
      #"{"iteration": 1, "detections": [], "elapsedMs": 10, "passErrors": [], "errorDescription": null, "deviceThermalState": "nominal", "futureField": {"a": 1}}"#
        .utf8
    )
    let observation = try JSONDecoder().decode(
      ScanBenchmarkRunObservation.self, from: observationJSON)
    XCTAssertEqual(
      observation, ScanBenchmarkRunObservation(iteration: 1, detections: [], elapsedMs: 10))

    let corpusJSON = Data(
      #"{"iterations": 3, "gates": {"minimumDetectionF1": 0.5, "minimumCorrectionCoverage": 0.2, "minimumOCRFieldAccuracy": 0.8, "minimumReliabilityJaccard": 0.8, "targetMedianElapsedMs": 1000, "newGate": 0.9}, "images": [], "schemaVersion": 7}"#
        .utf8
    )
    let corpus = try JSONDecoder().decode(ScanBenchmarkCorpus.self, from: corpusJSON)
    XCTAssertEqual(corpus.iterations, 3)
    XCTAssertTrue(corpus.images.isEmpty)
  }

  // MARK: - Codable roundtrips

  func testStatusAndBucketEnumsRoundtripAllCasesWithStableRawValues() throws {
    // Report consumers and archived reports key on these raw-value spellings; a rename
    // (e.g. notSupported -> not_supported) would silently break them.
    let metricStatuses: [(ScanBenchmarkMetricStatus, String)] = [
      (.measured, "measured"), (.failed, "failed"), (.notSupported, "notSupported"),
    ]
    for (status, raw) in metricStatuses {
      XCTAssertEqual(status.rawValue, raw)
      XCTAssertEqual(try JSONEncoder().encode(status), Data("\"\(raw)\"".utf8))
      XCTAssertEqual(
        try JSONDecoder().decode(ScanBenchmarkMetricStatus.self, from: Data("\"\(raw)\"".utf8)),
        status)
    }

    let statuses: [(ScanBenchmarkStatus, String)] = [
      (.passed, "passed"), (.regressed, "regressed"), (.invalid, "invalid"),
    ]
    for (status, raw) in statuses {
      XCTAssertEqual(status.rawValue, raw)
      XCTAssertEqual(
        try JSONDecoder().decode(ScanBenchmarkStatus.self, from: Data("\"\(raw)\"".utf8)),
        status)
    }

    let buckets: [(ScanBenchmarkDetectionBucket, String)] = [
      (.auto, "auto"), (.confirm, "confirm"), (.possible, "possible"), (.unknown, "unknown"),
    ]
    for (bucket, raw) in buckets {
      XCTAssertEqual(bucket.rawValue, raw)
      XCTAssertEqual(
        try JSONDecoder().decode(ScanBenchmarkDetectionBucket.self, from: Data("\"\(raw)\"".utf8)),
        bucket)
    }
  }

  func testGatesRoundtrips() throws {
    let decoded = assertRoundtrips(sampleGates())
    XCTAssertEqual(decoded?.targetMedianElapsedMs, 8000)
  }

  func testExpectedNutritionRoundtripsWithNilAndNonNilOptionals() {
    assertRoundtrips(ScanBenchmarkExpectedNutrition())
    assertRoundtrips(
      ScanBenchmarkExpectedNutrition(
        caloriesPerServing: 210,
        servingSize: "1 cup (240g)",
        servingsPerContainer: 2
      ))
  }

  func testObservedNutritionRoundtripsWithNilAndNonNilOptionals() {
    assertRoundtrips(ScanBenchmarkObservedNutrition())
    assertRoundtrips(
      ScanBenchmarkObservedNutrition(
        caloriesPerServing: 0,
        servingSize: "",
        servingsPerContainer: 1.5
      ))
  }

  func testCorpusEntryRoundtripsWithOptionalSubdirectoryAndEmptyArrays() {
    assertRoundtrips(
      ScanBenchmarkCorpusEntry(
        id: "empty",
        resourceName: "empty",
        resourceExtension: "png",
        scenarioTags: [],
        expectedIngredientIds: []
      ))

    let decoded = assertRoundtrips(
      ScanBenchmarkCorpusEntry(
        id: "full",
        resourceName: "full",
        resourceExtension: "jpg",
        resourceSubdirectory: "demo",
        scenarioTags: ["tutorial", "real_scan"],
        expectedIngredientIds: [1, 2, 3],
        expectedNutrition: ScanBenchmarkExpectedNutrition(
          caloriesPerServing: 100,
          servingSize: "1 bowl",
          servingsPerContainer: 1
        )
      ))
    XCTAssertEqual(decoded?.resourceSubdirectory, "demo")
    XCTAssertEqual(decoded?.expectedIngredientIds, [1, 2, 3])
  }

  func testCorpusRoundtripsWithEmptyAndPopulatedImages() {
    assertRoundtrips(ScanBenchmarkCorpus(iterations: 1, gates: sampleGates(), images: []))
    assertRoundtrips(
      ScanBenchmarkCorpus(
        iterations: 5,
        gates: sampleGates(),
        images: [
          ScanBenchmarkCorpusEntry(
            id: "one",
            resourceName: "one",
            resourceExtension: "png",
            scenarioTags: ["synthetic"],
            expectedIngredientIds: [1]
          )
        ]))
  }

  func testObservedDetectionRoundtripsWithEmptyAndNonEmptyAlternatives() {
    assertRoundtrips(
      ScanBenchmarkObservedDetection(ingredientId: 7, alternativeIngredientIds: [], bucket: .auto))
    assertRoundtrips(
      ScanBenchmarkObservedDetection(
        ingredientId: 7, alternativeIngredientIds: [8, 9], bucket: .confirm))
    assertRoundtrips(
      ScanBenchmarkObservedDetection(ingredientId: 7, bucket: .unknown))
  }

  func testRunObservationRoundtripsFullyPopulatedAndMinimal() {
    assertRoundtrips(
      ScanBenchmarkRunObservation(
        iteration: 2,
        detections: [
          ScanBenchmarkObservedDetection(
            ingredientId: 1, alternativeIngredientIds: [2], bucket: .auto)
        ],
        nutrition: ScanBenchmarkObservedNutrition(
          caloriesPerServing: 350,
          servingSize: "1 slice",
          servingsPerContainer: 8
        ),
        elapsedMs: 1250,
        passErrors: ["nutrition parse failed"],
        errorDescription: "transient Vision error"
      ))

    assertRoundtrips(
      ScanBenchmarkRunObservation(iteration: 0, detections: [], elapsedMs: 900))
  }

  func testRunReportRoundtripsWithNilAndNonNilReasons() {
    assertRoundtrips(
      ScanBenchmarkRunReport(
        iteration: 0,
        ingredientIds: [1, 2],
        alternativeIngredientIds: [3],
        elapsedMs: 800,
        valid: false,
        invalidReason: "Scan error: boom",
        errorDescription: "boom",
        passErrors: ["a"]
      ))
    assertRoundtrips(
      ScanBenchmarkRunReport(
        iteration: 1,
        ingredientIds: [],
        alternativeIngredientIds: [],
        elapsedMs: 10,
        valid: true,
        invalidReason: nil,
        errorDescription: nil,
        passErrors: []
      ))
  }

  func testDetectionAndCorrectionMetricsRoundtripsWithNilAndMeasuredScores() {
    assertRoundtrips(
      ScanBenchmarkDetectionMetrics(
        status: .measured,
        precision: 0.75,
        recall: 0.5,
        f1: 0.6,
        expectedIngredientCount: 4,
        averageDetectedCount: 3.25
      ))
    assertRoundtrips(
      ScanBenchmarkDetectionMetrics(
        status: .failed,
        precision: nil,
        recall: nil,
        f1: nil,
        expectedIngredientCount: 4,
        averageDetectedCount: nil
      ))

    assertRoundtrips(
      ScanBenchmarkCorrectionMetrics(
        status: .measured,
        topPredictionAcceptanceRate: 2.0 / 3.0,
        alternativeCoverageRate: 0.5,
        missedExpectationCount: 2
      ))
    assertRoundtrips(
      ScanBenchmarkCorrectionMetrics(
        status: .notSupported,
        topPredictionAcceptanceRate: nil,
        alternativeCoverageRate: nil,
        missedExpectationCount: 0
      ))
  }

  func testCalibrationAndOCRMetricsRoundtrips() {
    assertRoundtrips(
      ScanBenchmarkCalibrationMetric(
        bucket: .confirm, status: .measured, sampleCount: 10, matchedCount: 8, precision: 0.8))
    assertRoundtrips(
      ScanBenchmarkCalibrationMetric(
        bucket: .possible, status: .notSupported, sampleCount: 0, matchedCount: 0, precision: nil))

    assertRoundtrips(
      ScanBenchmarkOCRMetrics(
        status: .measured,
        parseSuccessRate: 1,
        caloriesAccuracy: 1,
        servingSizeAccuracy: 0,
        servingsPerContainerAccuracy: nil
      ))
    assertRoundtrips(
      ScanBenchmarkOCRMetrics(
        status: .notSupported,
        parseSuccessRate: nil,
        caloriesAccuracy: nil,
        servingSizeAccuracy: nil,
        servingsPerContainerAccuracy: nil
      ))
  }

  func testLatencyAndReliabilityMetricsRoundtrips() {
    assertRoundtrips(
      ScanBenchmarkLatencyMetrics(
        status: .measured, medianElapsedMs: 812, p90ElapsedMs: 1200, targetMedianElapsedMs: 8000))
    assertRoundtrips(
      ScanBenchmarkLatencyMetrics(
        status: .failed, medianElapsedMs: nil, p90ElapsedMs: nil, targetMedianElapsedMs: 8000))

    assertRoundtrips(
      ScanBenchmarkReliabilityMetrics(
        status: .measured,
        validRunCount: 5,
        invalidRunCount: 0,
        meanJaccardVsFirstValid: 0.95,
        minJaccardVsFirstValid: 0.8,
        requiredJaccard: 0.8
      ))
    assertRoundtrips(
      ScanBenchmarkReliabilityMetrics(
        status: .failed,
        validRunCount: 0,
        invalidRunCount: 3,
        meanJaccardVsFirstValid: nil,
        minJaccardVsFirstValid: nil,
        requiredJaccard: 0.8
      ))
  }

  func testUnsupportedMetricRoundtrips() {
    assertRoundtrips(
      ScanBenchmarkUnsupportedMetric(
        name: "vision_localization", status: .notSupported, reason: "bounding boxes unavailable"))
  }

  func testImageReportRoundtripsWithPassedAndInvalidVariants() {
    assertRoundtrips(sampleImageReport(id: "ok", status: .passed, invalidReason: nil))
    assertRoundtrips(
      sampleImageReport(id: "bad", status: .invalid, invalidReason: "No valid benchmark runs completed."))
  }

  func testReportSummaryAndFullReportRoundtrips() {
    assertRoundtrips(
      ScanBenchmarkReportSummary(
        imageCount: 2,
        passedImageCount: 1,
        regressedImageCount: 0,
        invalidImageCount: 1,
        overallDetectionF1: 0.9,
        overallMinimumReliabilityJaccard: 0.85,
        overallMedianElapsedMs: 950
      ))
    assertRoundtrips(
      ScanBenchmarkReportSummary(
        imageCount: 0,
        passedImageCount: 0,
        regressedImageCount: 0,
        invalidImageCount: 0,
        overallDetectionF1: nil,
        overallMinimumReliabilityJaccard: nil,
        overallMedianElapsedMs: nil
      ))

    let passed = sampleImageReport(id: "ok", status: .passed, invalidReason: nil)
    let invalid = sampleImageReport(id: "bad", status: .invalid, invalidReason: "No valid benchmark runs completed.")
    assertRoundtrips(
      ScanBenchmarkReport(
        createdAtISO8601: "2026-10-09T00:00:00Z",
        iterations: 5,
        gates: sampleGates(),
        status: .passed,
        invalidReason: nil,
        summary: ScanBenchmarkReportSummary(
          imageCount: 1,
          passedImageCount: 1,
          regressedImageCount: 0,
          invalidImageCount: 0,
          overallDetectionF1: 1,
          overallMinimumReliabilityJaccard: 1,
          overallMedianElapsedMs: 900
        ),
        images: [passed]
      ))
    assertRoundtrips(
      ScanBenchmarkReport(
        createdAtISO8601: "2026-10-09T00:00:00Z",
        iterations: 5,
        gates: sampleGates(),
        status: .invalid,
        invalidReason: "No valid benchmark runs completed.",
        summary: ScanBenchmarkReportSummary(
          imageCount: 2,
          passedImageCount: 1,
          regressedImageCount: 0,
          invalidImageCount: 1,
          overallDetectionF1: 1,
          overallMinimumReliabilityJaccard: 1,
          overallMedianElapsedMs: 900
        ),
        images: [passed, invalid]
      ))
  }

  // MARK: - Helpers

  /// Encodes and decodes `value` through JSON, asserting equality across the roundtrip.
  /// Returns the decoded value so callers can pin specific fields.
  @discardableResult
  private func assertRoundtrips<T: Codable & Equatable>(
    _ value: T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> T? {
    let data: Data
    do {
      data = try JSONEncoder().encode(value)
    } catch {
      XCTFail("encoding \(T.self) failed: \(error)", file: file, line: line)
      return nil
    }
    let decoded: T
    do {
      decoded = try JSONDecoder().decode(T.self, from: data)
    } catch {
      XCTFail("decoding \(T.self) failed: \(error)", file: file, line: line)
      return nil
    }
    XCTAssertEqual(
      decoded, value, "\(T.self) changed across a JSON roundtrip", file: file, line: line)
    return decoded
  }

  /// Walks up from this source file to the repo root looking for the benchmark manifest.
  /// `#filePath` is the source-tree path, which is present for SPM and xcodebuild CI runs.
  private func locateManifest() -> URL? {
    let relativePath = "apps/ios/Resources/benchmark_manifest.json"
    var directory = URL(fileURLWithPath: #filePath)
    for _ in 0..<8 {
      directory.deleteLastPathComponent()
      let candidate = directory.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private func decodeManifestCorpus(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> ScanBenchmarkCorpus {
    let url = try XCTUnwrap(
      locateManifest(),
      "benchmark_manifest.json not found by walking up from \(#filePath)",
      file: file,
      line: line)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(ScanBenchmarkCorpus.self, from: data)
  }

  private func sampleGates() -> ScanBenchmarkGates {
    ScanBenchmarkGates(
      minimumDetectionF1: 0.45,
      minimumCorrectionCoverage: 0.2,
      minimumOCRFieldAccuracy: 0.8,
      minimumReliabilityJaccard: 0.8,
      targetMedianElapsedMs: 8000
    )
  }

  private func sampleImageReport(
    id: String,
    status: ScanBenchmarkStatus,
    invalidReason: String?
  ) -> ScanBenchmarkImageReport {
    ScanBenchmarkImageReport(
      id: id,
      scenarioTags: ["synthetic"],
      expectedIngredientIds: [1],
      runs: [
        ScanBenchmarkRunReport(
          iteration: 0,
          ingredientIds: [1],
          alternativeIngredientIds: [],
          elapsedMs: 900,
          valid: status != .invalid,
          invalidReason: invalidReason,
          errorDescription: nil,
          passErrors: []
        )
      ],
      status: status,
      invalidReason: invalidReason,
      detectionMetrics: ScanBenchmarkDetectionMetrics(
        status: .measured, precision: 1, recall: 1, f1: 1,
        expectedIngredientCount: 1, averageDetectedCount: 1),
      correctionMetrics: ScanBenchmarkCorrectionMetrics(
        status: .notSupported, topPredictionAcceptanceRate: 1,
        alternativeCoverageRate: nil, missedExpectationCount: 0),
      calibrationMetrics: [
        ScanBenchmarkCalibrationMetric(
          bucket: .auto, status: .measured, sampleCount: 1, matchedCount: 1, precision: 1)
      ],
      ocrMetrics: ScanBenchmarkOCRMetrics(
        status: .notSupported, parseSuccessRate: nil, caloriesAccuracy: nil,
        servingSizeAccuracy: nil, servingsPerContainerAccuracy: nil),
      latencyMetrics: ScanBenchmarkLatencyMetrics(
        status: .measured, medianElapsedMs: 900, p90ElapsedMs: 900, targetMedianElapsedMs: 8000),
      reliabilityMetrics: ScanBenchmarkReliabilityMetrics(
        status: .measured, validRunCount: 1, invalidRunCount: 0,
        meanJaccardVsFirstValid: 1, minJaccardVsFirstValid: 1, requiredJaccard: 0.8),
      localizationMetric: ScanBenchmarkUnsupportedMetric(
        name: "vision_localization", status: .notSupported, reason: "not implemented"),
      amountMetric: ScanBenchmarkUnsupportedMetric(
        name: "image_amount_detection", status: .notSupported, reason: "not implemented")
    )
  }
}
