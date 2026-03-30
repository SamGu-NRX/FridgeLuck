import Foundation
import XCTest

@testable import FridgeLuck

@MainActor
final class SpotlightAnchorUpdateTests: XCTestCase {
  func testUpdateAnchorsNormalizesRectsAndDropsInvalidEntries() async {
    let coordinator = SpotlightCoordinator()

    coordinator.updateAnchors([
      "hero": CGRect(x: 10.24, y: 20.26, width: 100.74, height: 200.76),
      "empty": .zero,
    ])
    await settleCoordinatorUpdates()

    XCTAssertEqual(
      coordinator.anchors["hero"],
      CGRect(x: 10.0, y: 20.5, width: 100.5, height: 201.0)
    )
    XCTAssertNil(coordinator.anchors["empty"])
  }

  func testUpdateAnchorsCanMergeOrReplaceExistingValues() async {
    let coordinator = SpotlightCoordinator()

    coordinator.updateAnchors(["first": CGRect(x: 0, y: 0, width: 40, height: 40)])
    await settleCoordinatorUpdates()
    XCTAssertEqual(Set(coordinator.anchors.keys), ["first"])

    coordinator.updateAnchors(
      ["second": CGRect(x: 60, y: 60, width: 24, height: 24)],
      retainingExistingValues: true
    )
    await settleCoordinatorUpdates()
    XCTAssertEqual(Set(coordinator.anchors.keys), ["first", "second"])

    coordinator.updateAnchors(["replacement": CGRect(x: 8, y: 8, width: 16, height: 16)])
    await settleCoordinatorUpdates()
    XCTAssertEqual(Set(coordinator.anchors.keys), ["replacement"])
  }

  func testDismissActivePresentationInvokesCallbackAndClearsPresentation() {
    let coordinator = SpotlightCoordinator()
    var dismissedSource: String?

    coordinator.onDismissPresentation = { presentation in
      dismissedSource = presentation.source
    }

    coordinator.present(steps: SpotlightStep.completion, source: "completion")
    XCTAssertEqual(coordinator.activePresentation?.steps, SpotlightStep.completion)

    coordinator.dismissActivePresentation()

    XCTAssertNil(coordinator.activePresentation)
    XCTAssertEqual(dismissedSource, "completion")
  }

  func testCompletionPresentationStillTargetsMyRhythmAnchor() {
    let anchorIDs = SpotlightStep.completion.compactMap(\.anchorID)
    XCTAssertTrue(anchorIDs.contains("myRhythm"))
  }

  private func settleCoordinatorUpdates() async {
    await Task.yield()
    await Task.yield()
  }
}
