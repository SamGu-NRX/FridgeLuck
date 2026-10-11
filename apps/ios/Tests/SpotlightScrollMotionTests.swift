import SwiftUI
import XCTest

@testable import FridgeLuck

/// Tutorials scroll the next highlighted element into view. With Reduce Motion on, that scroll
/// must jump rather than animate.
final class SpotlightScrollMotionTests: XCTestCase {
  func testReduceMotionScrollsWithoutAnimation() {
    XCTAssertNil(AppMotion.spotlightScroll(reduceMotion: true))
  }

  func testDefaultScrollUsesTheSpotlightMove() {
    XCTAssertEqual(AppMotion.spotlightScroll(reduceMotion: false), AppMotion.spotlightMove)
  }
}
