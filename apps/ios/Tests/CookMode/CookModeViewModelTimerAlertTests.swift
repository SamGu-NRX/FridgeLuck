import XCTest

@testable import FridgeLuck

/// Review finding 3 (Greptile 5542992530): resuming or adjusting a timer must re-arm the device
/// alert. The store's scheduling effect carries only the timer id and deadline — the
/// notification content comes from the timer's own label — so the view model must pass the
/// stored label into the effect run. A `label: nil` call silently dropped the schedule: a
/// paused-then-resumed timer had no alert at all, and an adjusted timer kept its stale alert.
///
/// macOS-CI-only: the view model imports UserNotifications through the real scheduler, so this
/// file cannot compile in the portable Linux harness.
@MainActor
final class CookModeViewModelTimerAlertTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

  private final class SpyScheduler: CookTimerScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduledStorage: [(id: String, label: String, deadline: Date)] = []
    private var cancelledStorage: [String] = []

    var scheduled: [(id: String, label: String, deadline: Date)] {
      lock.lock()
      defer { lock.unlock() }
      return scheduledStorage
    }

    var cancelledIDs: [String] {
      lock.lock()
      defer { lock.unlock() }
      return cancelledStorage
    }

    func schedule(id: String, label: String, deadline: Date) {
      lock.lock()
      defer { lock.unlock() }
      scheduledStorage.append((id, label, deadline))
    }

    func cancel(id: String) {
      lock.lock()
      defer { lock.unlock() }
      cancelledStorage.append(id)
    }
  }

  private func makeViewModel(scheduler: SpyScheduler) -> CookModeViewModel {
    CookModeViewModel(
      recipe: Recipe(
        id: 1, title: "Udon", timeMinutes: 20, servings: 2,
        instructions: "1. Boil the broth\n2. Add the noodles\n3. Serve hot", tags: 0,
        source: .bundled, createdAt: nil),
      logsMeal: false,
      dependencies: .init(
        store: nil,
        substitutionOptions: { _ in [] },
        substituteIsAllergen: { _ in nil },
        logMeal: { _, _, _, _ in },
        scaleLines: { [] },
        now: { self.t0 },
        newID: { UUID().uuidString.lowercased() },
        scheduler: scheduler))
  }

  func testResumedAndAdjustedTimersReArmTheirAlertWithTheStoredLabel() {
    let scheduler = SpyScheduler()
    let vm = makeViewModel(scheduler: scheduler)
    vm.startOrResume()

    XCTAssertTrue(vm.addTimer(seconds: 60, label: "Eggs"))
    XCTAssertEqual(scheduler.scheduled.count, 1, "creating the timer arms its alert")
    XCTAssertEqual(scheduler.scheduled.first?.label, "Eggs")
    let timerID = scheduler.scheduled.first?.id ?? ""

    vm.pauseTimer(id: timerID)
    XCTAssertEqual(scheduler.cancelledIDs, [timerID], "pausing cancels the alert")
    XCTAssertEqual(scheduler.scheduled.count, 1)

    vm.resumeTimer(id: timerID)
    XCTAssertEqual(
      scheduler.scheduled.count, 2,
      "resuming must re-arm the alert — the dropped schedule left a resumed timer silent")
    XCTAssertEqual(scheduler.scheduled.last?.label, "Eggs", "the re-armed alert keeps the label")
    XCTAssertEqual(
      scheduler.scheduled.last?.deadline.timeIntervalSince(t0) ?? 0, 60, accuracy: 0.001)

    XCTAssertTrue(vm.adjustTimer(id: timerID, seconds: 120))
    XCTAssertEqual(
      scheduler.scheduled.count, 3,
      "adjusting recomputes the deadline and must re-arm the alert with it")
    XCTAssertEqual(scheduler.scheduled.last?.label, "Eggs")
    XCTAssertEqual(
      scheduler.scheduled.last?.deadline.timeIntervalSince(t0) ?? 0, 120, accuracy: 0.001)
  }
}
