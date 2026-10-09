import FLFeatureLogic
import XCTest

/// Hardening tests for `DemoFallbackPolicy` (pure demo-fallback decision logic).
///
/// Pins the complete public behavior contract so any structural change to the
/// policy surfaces as a targeted CI failure:
/// - the full 8-combination truth table of `shouldUseLiveVision`
/// - boundary behavior of `detectionCount` (0 vs 1, negative, large)
/// - structural invariants of `DemoFallbackDecision` from `fallbackDecision`
///
/// The starter path reporting `usedBundledFixture == true` (even though no
/// bundled fixture detections were used) is pinned by DemoFallbackPolicyTests
/// (testFallbackDecisionUsesStarterWhenFixtureMissing) and is deliberately NOT
/// re-asserted here; the semantic concern is tracked in the fleet bug-hunt
/// report under SUSPECTED.
final class DemoFallbackPolicyHardeningTests: XCTestCase {
  // MARK: - shouldUseLiveVision truth table

  private struct LiveVisionRow {
    let scenarioIsDefault: Bool
    let hasDemoImage: Bool
    let detectionCount: Int
    let expected: Bool
  }

  /// Expected values are the pinned contract: live vision is used only for the
  /// default scenario, when a demo image is present, and the live scan found at
  /// least one detection. Written as literal bools (not recomputed from the
  /// same expression) so any change to the conjunction structure in the
  /// implementation fails here with a named combination.
  private static let liveVisionTruthTable: [LiveVisionRow] = [
    LiveVisionRow(scenarioIsDefault: true, hasDemoImage: true, detectionCount: 0, expected: false),
    LiveVisionRow(scenarioIsDefault: true, hasDemoImage: true, detectionCount: 1, expected: true),
    LiveVisionRow(scenarioIsDefault: true, hasDemoImage: false, detectionCount: 0, expected: false),
    LiveVisionRow(scenarioIsDefault: true, hasDemoImage: false, detectionCount: 1, expected: false),
    LiveVisionRow(scenarioIsDefault: false, hasDemoImage: true, detectionCount: 0, expected: false),
    LiveVisionRow(scenarioIsDefault: false, hasDemoImage: true, detectionCount: 1, expected: false),
    LiveVisionRow(scenarioIsDefault: false, hasDemoImage: false, detectionCount: 0, expected: false),
    LiveVisionRow(scenarioIsDefault: false, hasDemoImage: false, detectionCount: 1, expected: false),
  ]

  func testShouldUseLiveVisionTruthTableAllEightCombinations() {
    for (index, row) in Self.liveVisionTruthTable.enumerated() {
      let actual = DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: row.scenarioIsDefault,
        hasDemoImage: row.hasDemoImage,
        detectionCount: row.detectionCount
      )
      XCTAssertEqual(
        actual,
        row.expected,
        "row \(index): scenarioIsDefault=\(row.scenarioIsDefault), "
          + "hasDemoImage=\(row.hasDemoImage), detectionCount=\(row.detectionCount)"
      )
    }
  }

  // MARK: - detectionCount boundaries

  func testShouldUseLiveVisionRejectsZeroDetectionsAtBoundary() {
    // 0 is the largest rejected count: guards a `>` → `>=` regression. A live
    // scan that succeeds but recognizes nothing must not become the demo
    // payload; the curated fixture keeps the demo meaningful instead.
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: true,
        detectionCount: 0
      )
    )
  }

  func testShouldUseLiveVisionAcceptsSingleDetectionAtBoundary() {
    // 1 is the smallest accepted count: guards a `>` → `> 1` regression where a
    // nearly-empty live scan would silently stop being used.
    XCTAssertTrue(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: true,
        detectionCount: 1
      )
    )
  }

  func testShouldUseLiveVisionRejectsNegativeDetectionCounts() {
    // The contract is "at least one", so every non-positive count is rejected;
    // guards a `> 0` → `!= 0` regression.
    for count in [-1, -100, Int.min] {
      XCTAssertFalse(
        DemoFallbackPolicy.shouldUseLiveVision(
          scenarioIsDefault: true,
          hasDemoImage: true,
          detectionCount: count
        ),
        "detectionCount=\(count) must be rejected"
      )
    }
  }

  func testShouldUseLiveVisionAcceptsLargeDetectionCounts() {
    // No upper bound on detections: guards an accidental cap (== 1, < 10, ...).
    XCTAssertTrue(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: true,
        detectionCount: 1_000
      )
    )
  }

  // MARK: - individual gates

  func testShouldUseLiveVisionRejectsNonDefaultScenarioDespiteStrongScan() {
    // Scenario-specific demo runs are deterministic fixture replays; the live
    // pipeline is reserved for the default scenario regardless of scan quality.
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: false,
        hasDemoImage: true,
        detectionCount: 50
      )
    )
  }

  func testShouldUseLiveVisionRejectsMissingDemoImageDespiteDetections() {
    // Without a demo image there is nothing to scan, so the live path is out
    // even when the scan produced detections.
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: false,
        detectionCount: 7
      )
    )
  }

  // MARK: - DemoFallbackDecision invariants

  func testFallbackDecisionStarterFallbackImpliesBundledFixture() {
    // Pinned per current design: a decision that used the starter fallback also
    // reports the bundled content path, i.e. (usedBundledFixture: false,
    // usedStarterFallback: true) is unreachable from the policy. If the
    // starter-path naming semantics ever change (see SUSPECTED in the fleet
    // report), revisit this invariant deliberately.
    for hasFixtureDetections in [true, false] {
      let decision = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: hasFixtureDetections)
      XCTAssertFalse(
        decision.usedStarterFallback && !decision.usedBundledFixture,
        "usedStarterFallback without usedBundledFixture for hasFixtureDetections=\(hasFixtureDetections)"
      )
    }
  }

  func testFallbackDecisionAlwaysReportsBundledContentOnFallbackPath() {
    // The policy is only consulted once the live path was not taken, so both
    // outcomes report bundled content (fixture detections or the starter set).
    // The live path itself bypasses this policy in DemoScanService with
    // usedBundledFixture=false, usedStarterFallback=false.
    for hasFixtureDetections in [true, false] {
      let decision = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: hasFixtureDetections)
      XCTAssertTrue(
        decision.usedBundledFixture,
        "expected bundled content on the fallback path for hasFixtureDetections=\(hasFixtureDetections)"
      )
    }
  }

  func testFallbackDecisionStarterFlagDistinguishesTheTwoPaths() {
    // Complete two-row decision table: fixture detections present → starter
    // flag false; fixture detections missing → starter flag true. The starter
    // flag is the only field that differs between the two outcomes.
    let withFixture = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: true)
    XCTAssertTrue(withFixture.usedBundledFixture)
    XCTAssertFalse(withFixture.usedStarterFallback)

    let withoutFixture = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: false)
    XCTAssertTrue(withoutFixture.usedBundledFixture)
    XCTAssertTrue(withoutFixture.usedStarterFallback)
  }

  func testFallbackDecisionIsDeterministicAcrossRepeatedCalls() {
    // Pure function: repeated evaluation of the same input must not drift
    // (no hidden state, memoization, or randomness).
    for hasFixtureDetections in [true, false] {
      let first = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: hasFixtureDetections)
      for _ in 0..<2 {
        let again = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: hasFixtureDetections)
        XCTAssertEqual(first.usedBundledFixture, again.usedBundledFixture)
        XCTAssertEqual(first.usedStarterFallback, again.usedStarterFallback)
      }
    }
  }

  // MARK: - concurrency contract

  /// Compile-time pin: the body only type-checks when `DemoFallbackDecision`
  /// conforms to `Sendable` (Swift 6 strict concurrency). If this file stops
  /// compiling here, `Sendable` was dropped from the type.
  private func requireSendable<T: Sendable>(_ value: T) -> T { value }

  func testDemoFallbackDecisionRemainsSendable() {
    let decision = requireSendable(
      DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: false)
    )
    XCTAssertTrue(decision.usedStarterFallback)
  }
}
