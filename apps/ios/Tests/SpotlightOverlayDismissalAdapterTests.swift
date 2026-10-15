import XCTest

@testable import FridgeLuck

/// Regression coverage for the overlay's real dismissal machinery: the callbacks the
/// view's Skip/Next/Back buttons call (`SpotlightOverlayDismissalAdapter`), the scheduled
/// unmount task, and the presentation binding write — not just the pure policy decisions.
///
/// The headline race: Skip fades the card out and schedules the unmount 240 ms later
/// (`dismissDelay`); a Next or Back tap inside that window cancelled the scheduled task
/// without restoring visibility, leaving the tour mounted at opacity 0 with its
/// full-screen dimming layer still in the hit-testing chain — the app reads as frozen.
final class SpotlightOverlayDismissalAdapterTests: XCTestCase {
  private let stepCount = 7
  private let dismissDelay: Duration = .milliseconds(100)

  /// Harness mirroring the view's wiring: plain stored state in place of `@State` and the
  /// presentation binding, no SwiftUI runtime involved. The adapter cannot tell the
  /// difference — it only ever touches the overlay through `Wiring`.
  @MainActor
  private final class Harness {
    let stepCount: Int
    private(set) var appeared = true
    private(set) var presented = true
    private(set) var renderedAppearedChanges: [Bool] = []

    init(stepCount: Int, dismissDelay: Duration) {
      self.stepCount = stepCount
      adapter = SpotlightOverlayDismissalAdapter(dismissDelay: dismissDelay)
    }

    let adapter: SpotlightOverlayDismissalAdapter

    /// Fresh per event, like the view's computed wiring.
    var wiring: SpotlightOverlayDismissalAdapter.Wiring {
      .init(
        stepCount: stepCount,
        currentAppeared: { [self] in appeared },
        setAppeared: { [self] visible in
          appeared = visible
          renderedAppearedChanges.append(visible)
        },
        currentPresented: { [self] in presented },
        setPresented: { [self] mounted in presented = mounted }
      )
    }
  }

  /// Polls until `condition` holds or the timeout lapses, yielding the main actor between
  /// polls so the adapter's scheduled unmount task can run.
  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  // MARK: Skip followed by navigation inside the unmount delay

  func testNextAfterSkipStillUnmountsThroughTheScheduledTask() async {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    harness.adapter.dismissRequested(harness.wiring)
    XCTAssertFalse(harness.appeared, "Skip fades the card out immediately")
    XCTAssertTrue(harness.presented, "Skip leaves unmounting to the scheduled task")

    let outcome = harness.adapter.navigationRequested(to: 2, harness.wiring)
    XCTAssertEqual(outcome?.stepIndex, 2, "Next inside the dismiss window is still accepted")

    let unmounted = await waitUntil { !harness.presented }
    XCTAssertTrue(
      unmounted,
      "the scheduled unmount must survive Skip then Next and clear the presentation binding"
    )
    XCTAssertFalse(
      harness.presented && !harness.appeared,
      "the tour must not stay mounted at opacity 0"
    )
  }

  func testBackAfterSkipStillUnmountsThroughTheScheduledTask() async {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    harness.adapter.dismissRequested(harness.wiring)
    let outcome = harness.adapter.navigationRequested(to: 0, harness.wiring)
    XCTAssertEqual(outcome?.stepIndex, 0, "Back inside the dismiss window is still accepted")

    let unmounted = await waitUntil { !harness.presented }
    XCTAssertTrue(
      unmounted,
      "the scheduled unmount must survive Skip then Back and clear the presentation binding"
    )
    XCTAssertFalse(
      harness.presented && !harness.appeared,
      "the tour must not stay mounted at opacity 0"
    )
  }

  // MARK: Single-interaction behavior

  func testSkipAloneUnmountsAfterTheDelay() async {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    harness.adapter.dismissRequested(harness.wiring)
    XCTAssertFalse(harness.appeared)
    XCTAssertTrue(harness.presented, "the unmount is scheduled, not immediate")

    let unmounted = await waitUntil { !harness.presented }
    XCTAssertTrue(unmounted, "the scheduled unmount task must write the binding false")
    XCTAssertEqual(harness.renderedAppearedChanges, [false])
  }

  func testNextWithoutPendingDismissalKeepsTheTourMounted() async {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    let outcome = harness.adapter.navigationRequested(to: 2, harness.wiring)
    XCTAssertEqual(outcome?.stepIndex, 2)

    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(harness.presented, "navigation alone must never unmount the tour")
    XCTAssertTrue(harness.appeared)
  }

  func testOutOfRangeNavigationIsRejected() async {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    XCTAssertNil(harness.adapter.navigationRequested(to: -1, harness.wiring))
    XCTAssertNil(harness.adapter.navigationRequested(to: stepCount, harness.wiring))

    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(harness.presented)
    XCTAssertTrue(harness.appeared)
  }

  func testTeardownCancelsThePendingUnmount() async {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    harness.adapter.dismissRequested(harness.wiring)
    harness.adapter.cancelPendingUnmount()

    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(
      harness.presented,
      "a torn-down overlay's scheduled unmount must not fire after cancellation"
    )
  }

  func testRestartedPresentationResetsTheAcceptedStep() {
    let harness = Harness(stepCount: stepCount, dismissDelay: dismissDelay)

    _ = harness.adapter.navigationRequested(to: 3, harness.wiring)
    XCTAssertEqual(harness.adapter.acceptedStepIndex, 3)

    harness.adapter.resetForNewPresentation()
    XCTAssertEqual(harness.adapter.acceptedStepIndex, 0)
    XCTAssertTrue(harness.presented)
  }
}
