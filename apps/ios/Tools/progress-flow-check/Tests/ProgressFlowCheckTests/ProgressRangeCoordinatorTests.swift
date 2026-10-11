import Foundation
import GRDB
import XCTest

@testable import ProgressFlowCheck

/// Polls until `condition` holds, failing the test on timeout.
func pollUntil(
  _ condition: @autoclosure () -> Bool,
  _ message: String = "",
  timeout: TimeInterval = 10,
  file: StaticString = #filePath,
  line: UInt = #line
) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return }
    Thread.sleep(forTimeInterval: 0.02)
  }
  XCTFail("condition not met within \(timeout)s: \(message)", file: file, line: line)
  throw ProgressReadFailure.readFailed("poll timed out")
}

/// A load that never completes on its own: it parks in a cancellable sleep
/// and records whether cancellation was actually observed.
final class SlowLoad: @unchecked Sendable {
  private let lock = NSLock()
  private var _started = 0
  private var _cancelledObserved = false

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _started
  }

  var cancelledObserved: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _cancelledObserved
  }

  // Sync mutators: NSLock is unavailable directly inside async bodies.
  private func recordStart() {
    lock.lock()
    defer { lock.unlock() }
    _started += 1
  }

  private func recordCancelled() {
    lock.lock()
    defer { lock.unlock() }
    _cancelledObserved = true
  }

  func run(_ range: ChartRange) async throws -> ProgressRangeReading {
    recordStart()
    do {
      try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 s: never completes in tests
    } catch {
      recordCancelled()
      throw error
    }
    return ProgressRangeReading(lastDays: range.rawValue, source: .localJournal, days: [])
  }
}

/// Counts loads and delegates to a real loader.
final class LoadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return _count
  }

  // Sync mutator: NSLock is unavailable directly inside async bodies.
  private func bump() {
    lock.lock()
    defer { lock.unlock() }
    _count += 1
  }

  func wrapping(
    _ load: @escaping @Sendable (ChartRange) async throws -> ProgressRangeReading
  ) -> @Sendable (ChartRange) async throws -> ProgressRangeReading {
    { range in
      self.bump()
      return try await load(range)
    }
  }
}

/// R2: state ownership — cancellation on input change and view close, and
/// explicit refresh when the revision token moves.
final class ProgressRangeCoordinatorTests: XCTestCase {
  func testSelectCancelsInFlightReadAndDropsItsResult() throws {
    let slow = SlowLoad()
    let coordinator = ProgressRangeCoordinator(load: slow.run)

    coordinator.select(.week)
    try pollUntil(slow.startedCount == 1, "the week load should start")

    // Input changes mid-read: the week read must be cancelled, and its
    // result (which never arrives) must not leak into the month state.
    coordinator.select(.month)
    try pollUntil(slow.cancelledObserved, "the superseded load should be cancelled")

    XCTAssertEqual(coordinator.state.selectedRange, ChartRange.month)
    XCTAssertTrue(coordinator.state.isLoading)
    XCTAssertNil(coordinator.state.shown)
    coordinator.stop()
  }

  func testStopCancelsInFlightReadAndStopsObservation() throws {
    let stack = try Fixtures.makeStack(#function)
    let slow = SlowLoad()
    let coordinator = ProgressRangeCoordinator(
      load: slow.run,
      queue: stack.queue,
      observationScheduling: .async(onQueue: DispatchQueue(label: "test.stop-observation")))

    // Starting the observation delivers the initial token, which refreshes.
    coordinator.startObservation()
    try pollUntil(slow.startedCount == 1, "the initial refresh should start a load")

    coordinator.stop()
    try pollUntil(slow.cancelledObserved, "stop() should cancel the in-flight load")

    let startsAtStop = slow.startedCount
    // A journal revision after close must not start more work.
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(
      slow.startedCount, startsAtStop,
      "no load may start after the view closed")
  }

  func testTokenRevisionsTriggerExplicitRefreshThroughRealLoader() throws {
    let stack = try Fixtures.makeStack(#function)
    let readModel = stack.readModel()
    let counter = LoadCounter()
    let coordinator = ProgressRangeCoordinator(
      load: counter.wrapping { range in
        try await readModel.loadRange(lastDays: range.rawValue)
      },
      queue: stack.queue,
      observationScheduling: .async(onQueue: DispatchQueue(label: "test.refresh-observation")))

    coordinator.startObservation()
    try pollUntil(
      counter.count >= 1 && coordinator.state.shown != nil && !coordinator.state.isLoading,
      "the initial load should complete")

    // Journal revision: a meal lands in today's bucket; Progress refreshes
    // on its own and the new aggregate is visible without user action.
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)
    try pollUntil(
      counter.count >= 2 && !coordinator.state.isLoading,
      "the journal revision should trigger a refresh")
    XCTAssertEqual(coordinator.state.shown?.source, ProgressNutritionSource.localJournal)
    XCTAssertEqual(coordinator.state.shown?.knownDays.count, 1)
    XCTAssertEqual(coordinator.state.shown?.knownDays.first?.value?.calories ?? 0, 100.0, accuracy: 0.5)

    // Profile/goal change: same explicit-refresh contract.
    try Fixtures.saveOnboardedProfile(stack, goal: .weightLoss, dailyCalories: 1600)
    try pollUntil(
      counter.count >= 3 && !coordinator.state.isLoading,
      "the profile change should trigger a refresh")

    coordinator.stop()
  }

  func testFailureThroughCoordinatorKeepsLastGoodReading() throws {
    let counter = LoadCounter()
    let goodReading = ProgressRangeReading(
      lastDays: 7,
      source: .localJournal,
      days: [
        ProgressDayPoint(
          date: Date(),
          source: .localJournal,
          value: MacroTotals(calories: 120, protein: 12, carbs: 12, fat: 12))
      ])

    var coordinator: ProgressRangeCoordinator!
    coordinator = ProgressRangeCoordinator(
      load: counter.wrapping { range in
        if counter.count == 1 {
          return goodReading
        }
        throw ProgressReadFailure.readFailed("database busy")
      })

    coordinator.select(.week)
    try pollUntil(!coordinator.state.isLoading && coordinator.state.shown != nil)
    XCTAssertNil(coordinator.state.errorMessage)

    coordinator.refresh()
    try pollUntil(!coordinator.state.isLoading && coordinator.state.errorMessage != nil)
    XCTAssertEqual(coordinator.state.errorMessage, "database busy")
    XCTAssertEqual(
      coordinator.state.shown?.knownDays.first?.value?.calories ?? 0, 120.0, accuracy: 0.5,
      "the failure must not erase the last good reading")
    coordinator.stop()
  }
}
