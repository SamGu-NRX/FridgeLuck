import FLFeatureLogic
import XCTest

final class CookingLaunchFlowTests: XCTestCase {
  func testStartWaitsForPreviewToDismissBeforeOpeningGuide() {
    var flow = CookingLaunchFlow<Int>()

    flow.requestStart(7)
    XCTAssertNil(flow.cooking)

    flow.previewDidDismiss()
    XCTAssertEqual(flow.cooking, 7)
  }

  func testDismissingPreviewWithoutStartingDoesNotOpenGuide() {
    var flow = CookingLaunchFlow<Int>()

    flow.previewDidDismiss()

    XCTAssertNil(flow.cooking)
  }

  func testRequestIsConsumedOnce() {
    var flow = CookingLaunchFlow<Int>()
    flow.requestStart(7)
    flow.previewDidDismiss()
    _ = flow.guideDidDismiss()

    flow.previewDidDismiss()

    XCTAssertNil(flow.cooking)
  }

  func testCompletedGuideReturnsHome() {
    var flow = CookingLaunchFlow<Int>()
    flow.requestStart(7)
    flow.previewDidDismiss()

    flow.guideCompleted()

    XCTAssertTrue(flow.guideDidDismiss())
    XCTAssertNil(flow.cooking)
  }

  func testClosingGuideEarlyStaysOnResults() {
    var flow = CookingLaunchFlow<Int>()
    flow.requestStart(7)
    flow.previewDidDismiss()

    XCTAssertFalse(flow.guideDidDismiss())
    XCTAssertNil(flow.cooking)
  }

  func testCompletionDoesNotCarryIntoNextSession() {
    var flow = CookingLaunchFlow<Int>()
    flow.requestStart(7)
    flow.previewDidDismiss()
    flow.guideCompleted()
    _ = flow.guideDidDismiss()

    flow.requestStart(8)
    flow.previewDidDismiss()

    XCTAssertEqual(flow.cooking, 8)
    XCTAssertFalse(flow.guideDidDismiss())
  }
}
