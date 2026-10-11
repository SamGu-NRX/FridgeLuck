import FLFeatureLogic
import Foundation
import XCTest

/// Parity tests for the shipped reverse-meal signal and hard-failure calculation.
///
/// These tests exercise the same composition `ReverseScanService.analyzeMealPhoto` runs in
/// production: the mean detection confidence from Float32 confidences, then the confidence
/// signals and hard-failure reasons from the ranked candidate facts. Expectations come from
/// the committed reverse-meal-v1 evaluation fixtures — the same committed files the Swift
/// evaluator and the TypeScript runner consume — loaded relative to this file. Missing,
/// duplicate, or mismatched cases fail loudly; nothing is skipped.
final class ReverseScanFeatureLogicTests: XCTestCase {
  // MARK: - Fixture decoding

  private struct FixtureCandidate: Decodable {
    let id: Int
    let confidenceScore: Double
    let matchedRequired: Int
    let totalRequired: Int
    let missingRequiredCount: Int

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(Int.self, forKey: .id)
      confidenceScore = try container.decode(Double.self, forKey: .confidenceScore)
      matchedRequired = try container.decode(Int.self, forKey: .matchedRequired)
      totalRequired = try container.decode(Int.self, forKey: .totalRequired)
      missingRequiredCount = try container.decode(Int.self, forKey: .missingRequiredCount)
    }

    enum CodingKeys: String, CodingKey {
      case id
      case confidenceScore = "confidence_score"
      case matchedRequired = "matched_required"
      case totalRequired = "total_required"
      case missingRequiredCount = "missing_required_count"
    }
  }

  private struct FixtureProducerState: Decodable {
    let detectionConfidences: [Double]
    let rankedCandidates: [FixtureCandidate]

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      detectionConfidences = try container.decode([Double].self, forKey: .detectionConfidences)
      rankedCandidates = try container.decode([FixtureCandidate].self, forKey: .rankedCandidates)
    }

    enum CodingKeys: String, CodingKey {
      case detectionConfidences = "detection_confidences"
      case rankedCandidates = "ranked_candidates"
    }
  }

  private struct FixtureStateRow: Decodable {
    let caseId: String
    let producerState: FixtureProducerState

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      caseId = try container.decode(String.self, forKey: .caseId)
      producerState = try container.decode(FixtureProducerState.self, forKey: .producerState)
    }

    enum CodingKeys: String, CodingKey {
      case caseId = "case_id"
      case producerState = "producer_state"
    }
  }

  private struct FixtureSignal: Decodable {
    let key: String
    let rawScore: Double
    let weight: Double
    let reason: String
  }

  private struct FixtureRequest: Decodable {
    let hardFailReasons: [String]
    let signals: [FixtureSignal]
  }

  private struct FixtureProjectionRow: Decodable {
    let caseId: String
    let request: FixtureRequest

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      caseId = try container.decode(String.self, forKey: .caseId)
      request = try container.decode(FixtureRequest.self, forKey: .request)
    }

    enum CodingKeys: String, CodingKey {
      case caseId = "case_id"
      case request
    }
  }

  // MARK: - Fixture loading

  private enum FixtureLoader {
    struct LoadFailure: Error, CustomStringConvertible {
      let description: String
    }

    static func url(relativeToSourceFile sourceFile: String, _ relativePath: String) throws -> URL {
      let sourceDirectory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
      let primary = sourceDirectory.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: primary.path) {
        return primary
      }

      // A relocated copy of this file (for example, a Linux parity harness outside the
      // usual test target) still resolves the committed fixtures by walking up toward the
      // repository root. A genuinely missing fixture still fails: nothing is ignored.
      var directory = sourceDirectory
      while directory.path != "/" {
        let candidate = directory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: candidate.path) {
          return candidate
        }
        directory = directory.deletingLastPathComponent()
      }
      throw LoadFailure(
        description:
          "Committed fixture not found: \(relativePath) (searched from \(sourceDirectory.path) upward)"
      )
    }
  }

  private func loadStates() throws -> [FixtureStateRow] {
    let url = try FixtureLoader.url(
      relativeToSourceFile: #filePath,
      "../../../backend/gemini-agent/evaluation-fixtures/reverse-meal-states-v1.jsonl"
    )
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      try decoder.decode(FixtureStateRow.self, from: Data(line.utf8))
    }
  }

  private func loadProjections() throws -> [FixtureProjectionRow] {
    let url = try FixtureLoader.url(
      relativeToSourceFile: #filePath,
      "../../../backend/gemini-agent/evaluation-output/reverse-meal-v1/projected-requests.jsonl"
    )
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      try decoder.decode(FixtureProjectionRow.self, from: Data(line.utf8))
    }
  }

  private func assertFixtureIntegrity(
    states: [FixtureStateRow],
    projections: [FixtureProjectionRow]
  ) {
    XCTAssertEqual(
      states.count, 16,
      "The committed reverse-meal evaluation pins 16 producer states; the fixture changed shape."
    )
    XCTAssertEqual(
      projections.count, 16,
      "The committed projected requests pin 16 cases; the output changed shape."
    )
    let stateIds = states.map(\.caseId)
    let projectionIds = projections.map(\.caseId)
    XCTAssertEqual(
      Set(stateIds).count, stateIds.count,
      "Duplicate producer-state case ids: \(stateIds)"
    )
    XCTAssertEqual(
      Set(projectionIds).count, projectionIds.count,
      "Duplicate projection case ids: \(projectionIds)"
    )
    XCTAssertEqual(
      Set(stateIds), Set(projectionIds),
      "Producer states and projected requests cover different cases; missing cases are not ignorable."
    )
  }

  // MARK: - Production composition

  /// The exact composition `ReverseScanService.analyzeMealPhoto` runs: Float32 confidences
  /// feed the mean, ranked candidates become facts, and the facts feed both the signals and
  /// the hard-failure reasons. Candidate order is supplied by the caller and preserved.
  private func runProductionCalculation(
    producerState: FixtureProducerState
  ) -> (signals: [ReverseScanSignal], hardFailReasons: [String]) {
    let confidences = producerState.detectionConfidences.map { Float($0) }
    let candidates = producerState.rankedCandidates.map { candidate in
      ReverseScanCandidateFacts(
        confidenceScore: candidate.confidenceScore,
        matchedRequired: candidate.matchedRequired,
        totalRequired: candidate.totalRequired,
        missingRequiredCount: candidate.missingRequiredCount
      )
    }
    let mean = ReverseScanFeatureLogic.meanDetectionConfidence(confidences)
    return (
      ReverseScanFeatureLogic.confidenceSignals(
        overallDetectionConfidence: mean,
        candidates: candidates
      ),
      ReverseScanFeatureLogic.hardFailReasons(candidates: candidates)
    )
  }

  private func assertNear(_ actual: Double, _ expected: Double, _ label: String) {
    let finite = actual.isFinite && expected.isFinite
    XCTAssertTrue(finite, "\(label): non-finite value, actual=\(actual), expected=\(expected)")
    guard finite else { return }
    let delta = abs(actual - expected)
    XCTAssertTrue(
      delta <= 1e-12,
      "\(label): |actual - expected| = \(delta) exceeds 1e-12 "
        + "(actual=\(String(format: "%.17g", actual)), expected=\(String(format: "%.17g", expected)))"
    )
  }

  private func facts(
    _ confidenceScore: Double,
    matched: Int = 3,
    total: Int = 3,
    missing: Int = 0
  ) -> ReverseScanCandidateFacts {
    ReverseScanCandidateFacts(
      confidenceScore: confidenceScore,
      matchedRequired: matched,
      totalRequired: total,
      missingRequiredCount: missing
    )
  }

  private func marginScore(top: Double, second: Double) -> Double {
    ReverseScanFeatureLogic.confidenceSignals(
      overallDetectionConfidence: 0.8,
      candidates: [facts(top), facts(second)]
    )[3].rawScore
  }

  private func hardFails(top: Double, second: Double) -> [String] {
    ReverseScanFeatureLogic.hardFailReasons(candidates: [facts(top), facts(second)])
  }

  // MARK: - Committed fixture parity

  func testCommittedProducerStatesProjectExactly() throws {
    let states = try loadStates()
    let projections = try loadProjections()
    assertFixtureIntegrity(states: states, projections: projections)

    let projectionsById = Dictionary(
      projections.map { ($0.caseId, $0.request) },
      uniquingKeysWith: { current, _ in current }
    )

    for state in states {
      let expected = try XCTUnwrap(
        projectionsById[state.caseId],
        "No committed projection for \(state.caseId); missing cases are not ignorable."
      )
      let computed = runProductionCalculation(producerState: state.producerState)

      XCTAssertEqual(
        computed.signals.count, expected.signals.count,
        "\(state.caseId): signal count diverged"
      )
      for (index, actualSignal) in computed.signals.enumerated()
      where index < expected.signals.count {
        let expectedSignal = expected.signals[index]
        XCTAssertEqual(actualSignal.key, expectedSignal.key, "\(state.caseId) [\(index)]: key")
        XCTAssertEqual(
          actualSignal.reason, expectedSignal.reason,
          "\(state.caseId) [\(index)] \(expectedSignal.key): reason"
        )
        assertNear(
          actualSignal.rawScore, expectedSignal.rawScore,
          "\(state.caseId) [\(index)] \(expectedSignal.key) rawScore"
        )
        assertNear(
          actualSignal.weight, expectedSignal.weight,
          "\(state.caseId) [\(index)] \(expectedSignal.key) weight"
        )
      }
      XCTAssertEqual(
        computed.hardFailReasons, expected.hardFailReasons,
        "\(state.caseId): hard-fail reasons"
      )
    }
  }

  // MARK: - Shipped rules, pinned independently of the fixtures

  func testMeanConvertsFloat32BeforeDoubleAccumulation() {
    // The RM-02 confidences. Each Float32 confidence widens to Double before the
    // accumulation, so the mean is pinned to 0.9399999976158142 — not the naive binary64
    // mean of the decimal values. The tolerance itself proves the conversion: the two
    // means differ by far more than 1e-12.
    let mean = ReverseScanFeatureLogic.meanDetectionConfidence([
      Float(0.95), Float(0.94), Float(0.93),
    ])
    assertNear(mean, 0.9399999976158142, "float32-first mean")
    let naiveMean = (0.95 + 0.94 + 0.93) / 3
    XCTAssertGreaterThan(
      abs(naiveMean - mean), 1e-12,
      "The Float32 conversion must stay observable in the mean."
    )
  }

  func testMeanClampsEachConfidenceAndHandlesEmpty() {
    XCTAssertEqual(
      ReverseScanFeatureLogic.meanDetectionConfidence([]), 0,
      "No detections ship a zero mean."
    )
    assertNear(
      ReverseScanFeatureLogic.meanDetectionConfidence([Float(1.5), Float(-0.5)]), 0.5,
      "per-value clamp"
    )
  }

  func testSignalKeysWeightsAndReasonsAreFixed() {
    let signals = ReverseScanFeatureLogic.confidenceSignals(
      overallDetectionConfidence: 0.7,
      candidates: []
    )
    XCTAssertEqual(
      signals.map(\.key),
      [
        "reverse_scan.vision_detection",
        "reverse_scan.recipe_match",
        "reverse_scan.required_coverage",
        "reverse_scan.candidate_margin",
      ]
    )
    XCTAssertEqual(
      signals.map(\.reason),
      [
        "ingredient detection", "recipe match", "required ingredient coverage",
        "candidate ambiguity",
      ]
    )
    assertNear(signals[0].weight, 0.32, "vision_detection weight")
    assertNear(signals[1].weight, 0.30, "recipe_match weight")
    assertNear(signals[2].weight, 0.23, "required_coverage weight")
    assertNear(signals[3].weight, 0.15, "candidate_margin weight")
    // Weights stay at or above the learner's 0.05 input floor, so the learner's clamping
    // stays a no-op for these signals.
    XCTAssertTrue(signals.allSatisfy { $0.weight >= 0.05 })
    // With no candidates the vision signal keeps the mean and the other three are zero.
    assertNear(signals[0].rawScore, 0.7, "vision_detection keeps the mean")
    assertNear(signals[1].rawScore, 0, "recipe_match with no candidates")
    assertNear(signals[2].rawScore, 0, "required_coverage with no candidates")
    assertNear(signals[3].rawScore, 0, "candidate_margin with no candidates")
  }

  func testRequiredCoverageFloorsTheDivisorAtOne() {
    // totalRequired floors at 1 and the raw coverage is not clamped at this layer — the
    // learner's ConfidenceSignalInput clamps rawScore at construction, as shipped.
    let signals = ReverseScanFeatureLogic.confidenceSignals(
      overallDetectionConfidence: 0.5,
      candidates: [facts(0.9, matched: 2, total: 0)]
    )
    assertNear(signals[2].rawScore, 2.0, "coverage divisor floor")
  }

  func testSingleCandidateMarginIsFixedAt082() {
    let single = ReverseScanFeatureLogic.confidenceSignals(
      overallDetectionConfidence: 0.9,
      candidates: [facts(0.91)]
    )
    assertNear(single[3].rawScore, 0.82, "single-candidate margin")
    XCTAssertTrue(
      ReverseScanFeatureLogic.hardFailReasons(candidates: [facts(0.91)]).isEmpty,
      "A single healthy candidate does not hard-fail."
    )
    // The margin stays 0.82 even when a different rule hard-fails.
    let failing = ReverseScanFeatureLogic.confidenceSignals(
      overallDetectionConfidence: 0.9,
      candidates: [facts(0.91, matched: 1, total: 4, missing: 3)]
    )
    assertNear(failing[3].rawScore, 0.82, "single-candidate margin under hard failure")
    XCTAssertEqual(
      ReverseScanFeatureLogic.hardFailReasons(candidates: [
        facts(0.91, matched: 1, total: 4, missing: 3)
      ]),
      ["Too many required ingredients are missing."]
    )
  }

  func testTwoCandidateMarginClampsAndTiesScoreHalf() {
    assertNear(marginScore(top: 0.9, second: 0.2), 1.0, "0.5 + 0.7 clamps to 1")
    assertNear(marginScore(top: 0.5, second: 0.5), 0.5, "a tie is a 0 gap")
    XCTAssertEqual(
      hardFails(top: 0.5, second: 0.5),
      ["Top recipe candidates are highly ambiguous."],
      "A tie is also an ambiguity hard failure."
    )
  }

  func testAmbiguityRuleUsesStrictBinary64Gap() {
    // RM-10: 0.86 - 0.80 is 0.05999999999999994 in binary64, below 0.06, so the shipped
    // rule hard-fails with no epsilon and no decimal rounding.
    XCTAssertLessThan(0.86 - 0.80, 0.06)
    XCTAssertEqual(
      hardFails(top: 0.86, second: 0.80), ["Top recipe candidates are highly ambiguous."])
    // RM-11: 0.87 - 0.80 stays at or above 0.06, so no hard failure.
    XCTAssertEqual(hardFails(top: 0.87, second: 0.80), [])
  }

  func testHardFailPrecedenceFollowsShippedOrder() {
    XCTAssertEqual(
      ReverseScanFeatureLogic.hardFailReasons(candidates: []),
      ["No confident recipe candidate."],
      "No candidates outranks every other failure."
    )
    XCTAssertEqual(
      ReverseScanFeatureLogic.hardFailReasons(
        candidates: [
          facts(0.5, matched: 0, total: 4, missing: 3),
          facts(0.5, matched: 0, total: 4, missing: 3),
        ]
      ),
      ["Too many required ingredients are missing."],
      "Missing required outranks ambiguity."
    )
  }

  func testMissingRequiredBoundaryIsStrictlyAboveTwo() {
    XCTAssertEqual(
      ReverseScanFeatureLogic.hardFailReasons(candidates: [
        facts(0.9, matched: 2, total: 4, missing: 2)
      ]),
      [],
      "Exactly two missing required ingredients do not hard-fail."
    )
    XCTAssertEqual(
      ReverseScanFeatureLogic.hardFailReasons(candidates: [
        facts(0.9, matched: 2, total: 4, missing: 3)
      ]),
      ["Too many required ingredients are missing."]
    )
  }

  func testSuppliedCandidateOrderIsConsumedAsGiven() {
    // Ranked input: wide gap, margin clamps to 1, no failure.
    let ranked = [facts(0.9), facts(0.2)]
    XCTAssertTrue(ReverseScanFeatureLogic.hardFailReasons(candidates: ranked).isEmpty)
    assertNear(
      ReverseScanFeatureLogic.confidenceSignals(
        overallDetectionConfidence: 0.8, candidates: ranked)[3]
        .rawScore, 1.0, "ranked wide gap"
    )
    // Unranked input: the margin floors at 0.5 while the raw negative gap still triggers
    // the ambiguity failure. The calculation never re-sorts what it is given.
    let unranked = [facts(0.2), facts(0.9)]
    XCTAssertEqual(
      ReverseScanFeatureLogic.hardFailReasons(candidates: unranked),
      ["Top recipe candidates are highly ambiguous."]
    )
    assertNear(
      ReverseScanFeatureLogic.confidenceSignals(
        overallDetectionConfidence: 0.8, candidates: unranked)[3]
        .rawScore, 0.5, "unranked negative gap"
    )
  }
}
