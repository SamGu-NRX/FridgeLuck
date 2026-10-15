import FLFeatureLogic
import XCTest

final class MealPhotoConfirmationPolicyTests: XCTestCase {
  func testExactIsOneTap() {
    XCTAssertTrue(MealPhotoConfirmationPolicy.preselectsTopCandidate(for: .exact))
    XCTAssertFalse(MealPhotoConfirmationPolicy.asksToCheckBeforeLogging(for: .exact))
  }

  func testReviewPreselectsButAsksForACheck() {
    XCTAssertTrue(MealPhotoConfirmationPolicy.preselectsTopCandidate(for: .reviewRequired))
    XCTAssertTrue(MealPhotoConfirmationPolicy.asksToCheckBeforeLogging(for: .reviewRequired))
  }

  func testEstimateNeverPreselectsADish() {
    XCTAssertFalse(MealPhotoConfirmationPolicy.preselectsTopCandidate(for: .estimateOnly))
    XCTAssertTrue(MealPhotoConfirmationPolicy.asksToCheckBeforeLogging(for: .estimateOnly))
  }
}
