import XCTest

@testable import FridgeLuck

/// Skip sits in the tour card, so it is reachable on every screen the tour runs on. It must be
/// offered on every step except the last, where "Let's go" ends the tour.
final class SpotlightTourProgressTests: XCTestCase {
  func testSkipIsOfferedOnEveryStepBeforeTheLast() {
    let offered = (0..<7).map { SpotlightTourProgress.offersSkip(at: $0, of: 7) }
    XCTAssertEqual(offered, [true, true, true, true, true, true, false])
  }

  func testSingleStepTourEndsWithItsOnlyButton() {
    XCTAssertTrue(SpotlightTourProgress.isLastStep(0, of: 1))
    XCTAssertFalse(SpotlightTourProgress.offersSkip(at: 0, of: 1))
  }

  func testLastStepIsTheFinalIndex() {
    XCTAssertFalse(SpotlightTourProgress.isLastStep(5, of: 7))
    XCTAssertTrue(SpotlightTourProgress.isLastStep(6, of: 7))
  }
}
