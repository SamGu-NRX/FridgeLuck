import FLFeatureLogic
import XCTest

final class LiveAssistantPanelLayoutTests: XCTestCase {
  func testDraggingUpFromPeekResolvesToStep() {
    let detent = LiveAssistantPanelLayout.resolvedDetent(
      from: .peek,
      translation: -170,
      predictedEndTranslation: -210,
      screenHeight: 900
    )

    XCTAssertEqual(detent, .step)
  }

  func testDraggingDownFromFullResolvesToStep() {
    let detent = LiveAssistantPanelLayout.resolvedDetent(
      from: .full,
      translation: 210,
      predictedEndTranslation: 250,
      screenHeight: 900
    )

    XCTAssertEqual(detent, .step)
  }

  func testClampedHeightNeverDropsBelowPeek() {
    let height = LiveAssistantPanelLayout.clampedHeight(
      for: .peek,
      translation: 300,
      screenHeight: 900
    )

    XCTAssertEqual(height, LiveAssistantPanelDetent.peek.height(in: 900))
  }
}
