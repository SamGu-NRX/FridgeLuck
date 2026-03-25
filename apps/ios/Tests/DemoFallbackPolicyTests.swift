import FLFeatureLogic
import XCTest

final class DemoFallbackPolicyTests: XCTestCase {
  func testLiveVisionUsedOnlyForDefaultScenarioWithImageAndDetections() {
    XCTAssertTrue(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: true,
        detectionCount: 1
      )
    )
  }

  func testLiveVisionRejectedForScenarioSpecificRuns() {
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: false,
        hasDemoImage: true,
        detectionCount: 3
      )
    )
  }

  func testLiveVisionRejectedWithoutImageOrDetections() {
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: false,
        detectionCount: 4
      )
    )
    XCTAssertFalse(
      DemoFallbackPolicy.shouldUseLiveVision(
        scenarioIsDefault: true,
        hasDemoImage: true,
        detectionCount: 0
      )
    )
  }

  func testFallbackDecisionUsesFixtureWhenAvailable() {
    let decision = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: true)
    XCTAssertTrue(decision.usedBundledFixture)
    XCTAssertFalse(decision.usedStarterFallback)
  }

  func testFallbackDecisionUsesStarterWhenFixtureMissing() {
    let decision = DemoFallbackPolicy.fallbackDecision(hasFixtureDetections: false)
    XCTAssertTrue(decision.usedBundledFixture)
    XCTAssertTrue(decision.usedStarterFallback)
  }
}
