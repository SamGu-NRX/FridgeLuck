import XCTest

@testable import FridgeLuck

/// Regression coverage for the spotlight overlay's dismissal/navigation policy.
///
/// The headline race: Skip fades the card out and schedules the unmount 240 ms later
/// (`dismissDelay`); a Next or Back tap inside that window cancels the scheduled unmount
/// without restoring visibility, leaving the tour mounted at opacity 0 with its
/// full-screen dimming layer still in the hit-testing chain — the app reads as frozen.
final class SpotlightOverlayStateTransitionsTests: XCTestCase {
  private let stepCount = 7

  private var visibleTour: SpotlightOverlayStateTransitions.State {
    SpotlightOverlayStateTransitions.State(
      stepIndex: 1,
      appeared: true,
      isPresented: true,
      isDismissalPending: false
    )
  }

  // MARK: Skip followed by navigation inside the unmount delay

  func testNextAfterSkipAlwaysEndsUnmountedOrVisible() {
    let afterSkip = applyEvent(.dismissRequested, from: visibleTour)
    let afterNext = applyEvent(.navigate(stepIndex: 2), from: afterSkip)
    let afterUnmountDelay = applyEvent(.dismissDelayElapsed, from: afterNext)

    XCTAssertFalse(
      afterUnmountDelay.isPresented && !afterUnmountDelay.appeared,
      "Skip then Next left the overlay mounted at opacity 0: \(afterUnmountDelay)"
    )
    XCTAssertFalse(
      afterUnmountDelay.isPresented,
      "Once dismissal begins the scheduled unmount must still fire: \(afterUnmountDelay)"
    )
  }

  func testBackAfterSkipAlwaysEndsUnmountedOrVisible() {
    let afterSkip = applyEvent(.dismissRequested, from: visibleTour)
    let afterBack = applyEvent(.navigate(stepIndex: 0), from: afterSkip)
    let afterUnmountDelay = applyEvent(.dismissDelayElapsed, from: afterBack)

    XCTAssertFalse(
      afterUnmountDelay.isPresented && !afterUnmountDelay.appeared,
      "Skip then Back left the overlay mounted at opacity 0: \(afterUnmountDelay)"
    )
    XCTAssertFalse(
      afterUnmountDelay.isPresented,
      "Once dismissal begins the scheduled unmount must still fire: \(afterUnmountDelay)"
    )
  }

  // MARK: Behavior that must not change

  func testNavigationWithoutPendingDismissalKeepsTheTourVisible() {
    let outcome = applyEvent(.navigate(stepIndex: 2), from: visibleTour)

    XCTAssertEqual(outcome.stepIndex, 2)
    XCTAssertTrue(outcome.appeared)
    XCTAssertTrue(outcome.isPresented)
    XCTAssertFalse(outcome.isDismissalPending)
  }

  func testSkipThenUnmountDelayClearsThePresentation() {
    let afterSkip = applyEvent(.dismissRequested, from: visibleTour)

    XCTAssertFalse(afterSkip.appeared)
    XCTAssertTrue(afterSkip.isPresented)
    XCTAssertTrue(afterSkip.isDismissalPending)

    let afterDelay = applyEvent(.dismissDelayElapsed, from: afterSkip)

    XCTAssertFalse(afterDelay.isPresented)
    XCTAssertFalse(afterDelay.isDismissalPending)
  }

  func testUnmountDelayWithoutPendingDismissalIsIgnored() {
    XCTAssertEqual(applyEvent(.dismissDelayElapsed, from: visibleTour), visibleTour)
  }

  func testNavigationOutsideTheStepRangeIsIgnored() {
    XCTAssertEqual(applyEvent(.navigate(stepIndex: -1), from: visibleTour), visibleTour)
    XCTAssertEqual(applyEvent(.navigate(stepIndex: stepCount), from: visibleTour), visibleTour)
  }

  private func applyEvent(
    _ event: SpotlightOverlayStateTransitions.Event,
    from state: SpotlightOverlayStateTransitions.State
  ) -> SpotlightOverlayStateTransitions.State {
    SpotlightOverlayStateTransitions.next(state, after: event, stepCount: stepCount)
  }
}
