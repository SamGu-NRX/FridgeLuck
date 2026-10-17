import FLFeatureLogic
import XCTest

@testable import FridgeLuck

/// The cooking guide's "Start 20-second timer" started a timer the guide never showed, so the
/// screen didn't change and each further tap stacked another silent timer (2026-10-16 walk at
/// alpha af85600, shots -10 and -11).
@MainActor
final class CookGuideStepTimerTests: XCTestCase {
  private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
  }

  private func makeSession(_ clock: Clock) -> CookModeViewModel {
    let recipe = Recipe(
      id: 1, title: "Garlic rice", timeMinutes: 10, servings: 2,
      instructions: """
        1. Rinse the rice.
        2. Fry the garlic for 2 minutes.
        3. Serve.
        """,
      tags: 0, source: .bundled, createdAt: nil)
    let vm = CookModeViewModel(
      recipe: recipe, logsMeal: false, dependencies: .ephemeral(now: { clock.now }))
    vm.startOrResume()
    return vm
  }

  func testStartingAStepTimerShowsACountdownForThatStep() {
    let clock = Clock()
    let vm = makeSession(clock)
    XCTAssertNil(vm.timerSeconds(forStep: 0), "a step without a stated time offers no timer")
    XCTAssertEqual(vm.timerSeconds(forStep: 1), 120)
    XCTAssertNil(vm.activeTimer(forStep: 1), "nothing runs before the tap")

    XCTAssertTrue(vm.startStepTimer(step: 1))
    let timer = try? XCTUnwrap(vm.activeTimer(forStep: 1))
    XCTAssertEqual(timer?.remainingSeconds, 120)
    XCTAssertEqual(timer?.isFired, false)
    XCTAssertEqual(CookingGuideTimerFormat.clock(timer?.remainingSeconds ?? -1), "2:00")
    XCTAssertNil(vm.activeTimer(forStep: 0), "the timer belongs to its own step")
  }

  func testASecondTapDoesNotStartADuplicate() {
    let vm = makeSession(Clock())
    XCTAssertTrue(vm.startStepTimer(step: 1))
    XCTAssertFalse(vm.startStepTimer(step: 1))
    vm.startSuggestedTimer()
    XCTAssertEqual(vm.state.timers.count, 1)
  }

  func testCancelThenStartAgain() {
    let vm = makeSession(Clock())
    vm.startStepTimer(step: 1)
    vm.removeTimer(id: try! XCTUnwrap(vm.activeTimer(forStep: 1)).id)
    XCTAssertNil(vm.activeTimer(forStep: 1))
    XCTAssertTrue(vm.startStepTimer(step: 1), "a cancelled timer can be started again")
  }

  /// The timer belongs to the session, not the page, so it keeps counting after the cook moves
  /// on, and it stays up as "Time's up" until dismissed.
  func testTimerOutlivesTheStepAndStaysUpUntilDismissed() {
    let clock = Clock()
    let vm = makeSession(clock)
    vm.advance()
    vm.startSuggestedTimer()
    XCTAssertNotNil(vm.activeTimer(forStep: 1))
    vm.advance()

    clock.now.addTimeInterval(45)
    vm.toggleCompleted()  // any intent refreshes state at the new clock
    XCTAssertEqual(vm.activeTimer(forStep: 1)?.remainingSeconds, 75)

    clock.now.addTimeInterval(100)
    vm.toggleCompleted()
    let fired = vm.activeTimer(forStep: 1)
    XCTAssertEqual(fired?.isFired, true)
    XCTAssertEqual(fired?.remainingSeconds, 0)
    XCTAssertFalse(vm.startStepTimer(step: 1), "a finished timer still shows until dismissed")

    vm.acknowledgeTimer(id: fired!.id)
    XCTAssertNil(vm.activeTimer(forStep: 1))
    XCTAssertTrue(vm.startStepTimer(step: 1))
  }

  func testClockFormat() {
    XCTAssertEqual(CookingGuideTimerFormat.clock(20), "0:20")
    XCTAssertEqual(CookingGuideTimerFormat.clock(725), "12:05")
    XCTAssertEqual(CookingGuideTimerFormat.clock(3723), "1:02:03")
  }
}
