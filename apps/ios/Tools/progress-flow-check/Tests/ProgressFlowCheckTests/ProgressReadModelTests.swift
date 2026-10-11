import Foundation
import GRDB
import XCTest

@testable import ProgressFlowCheck

/// Bridges async read-model calls from synchronous test bodies (Linux
/// corelibs-xctest predates async test methods). Strict-concurrency safe:
/// the result travels through a locked box.
final class AsyncResultBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<T, Error>?

  var value: Result<T, Error>? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      stored = newValue
    }
  }

  func get() throws -> T {
    switch value {
    case .success(let value): value
    case .failure(let error): throw error
    case nil: throw ProgressReadFailure.readFailed("async load did not complete")
    }
  }
}

/// Runs `body` to completion on the concurrent pool and returns its result.
/// The test thread blocks on a semaphore; the body never hops to the test
/// thread, so this cannot deadlock.
func syncAwait<T: Sendable>(
  _ body: @escaping @Sendable () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) throws -> T {
  let box = AsyncResultBox<T>()
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    do {
      box.value = .success(try await body())
    } catch {
      box.value = .failure(error)
    }
    done.signal()
  }
  if done.wait(timeout: .now() + 30) == .timedOut {
    XCTFail("async load timed out", file: file, line: line)
    throw ProgressReadFailure.readFailed("async load timed out")
  }
  return try box.get()
}

/// R1/R2/R3: the typed read model over the real persistence layer —
/// provenance, portion/date/profile invalidation, and aggregate-policy
/// semantics. Run with TZ=UTC (see Fixtures).
final class ProgressReadModelTests: XCTestCase {
  // MARK: - R1: portion edits

  func testPortionEditChangesAggregatesAndProgressTokenButNotLegacyToken() throws {
    let stack = try Fixtures.makeStack(#function)
    let historyId = try Fixtures.logMeal(
      stack, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)

    let baseline = try stack.userData.todayMacros()
    XCTAssertEqual(baseline.calories, 100.0, accuracy: 0.5)
    let baselineToken = try ProgressRevisionToken.read(in: stack.queue)
    let legacyBaseline = try Fixtures.legacyDashboardToken(stack.queue)

    // Accepted portion revision: portion_multiplier 1.0 -> 2.0.
    try stack.queue.write { db in
      try db.execute(
        sql: "UPDATE cooking_history SET portion_multiplier = 2.0 WHERE id = ?",
        arguments: [historyId])
    }

    let revised = try stack.userData.todayMacros()
    XCTAssertEqual(revised.calories, 200.0, accuracy: 0.5)
    XCTAssertEqual(revised.protein, 20.0, accuracy: 0.5)

    // The Progress token moves on the portion edit.
    let revisedToken = try ProgressRevisionToken.read(in: stack.queue)
    XCTAssertNotEqual(revisedToken.portionChecksum, baselineToken.portionChecksum)

    // The shared dashboard token does not: count, latest id, rating and
    // servings checksums are all untouched by a portion_multiplier edit,
    // which is why the Progress observer must use the stronger token.
    let legacyRevised = try Fixtures.legacyDashboardToken(stack.queue)
    XCTAssertEqual(legacyRevised.count, legacyBaseline.count)
    XCTAssertEqual(legacyRevised.latestID, legacyBaseline.latestID)
    XCTAssertEqual(legacyRevised.ratingChecksum, legacyBaseline.ratingChecksum)
    XCTAssertEqual(legacyRevised.servingsChecksum, legacyBaseline.servingsChecksum)
  }

  // MARK: - R1: date shifts

  func testDateShiftMovesEntryAcrossDayBucketsAndInvalidates() throws {
    let stack = try Fixtures.makeStack(#function)
    let historyId = try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)

    let readModel = stack.readModel()
    let baselineToken = try ProgressRevisionToken.read(in: stack.queue)

    // Baseline: the meal sits in today's bucket.
    let todayKey = ProgressAggregation.dayKey(Date())
    let baselineWeek = try stack.userData.dailyMacroTotals(lastDays: 7)
    XCTAssertEqual(
      baselineWeek.first { ProgressAggregation.dayKey($0.date) == todayKey }?.calories ?? 0,
      100.0, accuracy: 0.5)

    // Accepted date revision: move the meal to yesterday.
    try Fixtures.redateMeal(stack, historyId: historyId, day: Fixtures.day(1))

    let revisedWeek = try stack.userData.dailyMacroTotals(lastDays: 7)
    let yesterdayKey = ProgressAggregation.dayKey(Fixtures.day(1))
    XCTAssertEqual(
      revisedWeek.first { ProgressAggregation.dayKey($0.date) == yesterdayKey }?.calories ?? 0,
      100.0, accuracy: 0.5)
    XCTAssertEqual(
      revisedWeek.first { ProgressAggregation.dayKey($0.date) == todayKey }?.calories ?? 0,
      0.0, accuracy: 0.5)

    // The known-day set moves with it: today becomes "no data".
    let reading = try syncAwait { try await readModel.loadRange(lastDays: 7) }
    XCTAssertEqual(reading.source, .localJournal)
    XCTAssertEqual(
      reading.days.first { ProgressAggregation.dayKey($0.date) == yesterdayKey }?.isKnown,
      true)
    XCTAssertEqual(
      reading.days.first { ProgressAggregation.dayKey($0.date) == todayKey }?.isKnown,
      false)

    // The Progress token moves on the date shift.
    let revisedToken = try ProgressRevisionToken.read(in: stack.queue)
    XCTAssertNotEqual(revisedToken.cookedAtChecksum, baselineToken.cookedAtChecksum)
    XCTAssertNotEqual(revisedToken.maxCookedAtEpoch, baselineToken.maxCookedAtEpoch)
  }

  func testDateShiftOutOfRangeDropsEntryFromRange() throws {
    let stack = try Fixtures.makeStack(#function)
    let historyId = try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)

    let readModel = stack.readModel()

    // Move the meal 10 days back: outside the 7-day window entirely.
    try Fixtures.redateMeal(stack, historyId: historyId, day: Fixtures.day(10))

    let week = try stack.userData.dailyMacroTotals(lastDays: 7)
    XCTAssertTrue(week.allSatisfy { $0.calories == 0 })

    let reading = try syncAwait { try await readModel.loadRange(lastDays: 7) }
    XCTAssertTrue(reading.days.allSatisfy { !$0.isKnown })
    XCTAssertNil(reading.averageCalories)
  }

  // MARK: - R1: profile / goal changes

  func testProfileGoalChangeInvalidatesGoalDependentOutputs() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.saveOnboardedProfile(stack, goal: .maintenance, dailyCalories: 2200)

    let readModel = stack.readModel()
    let baseline = try syncAwait { try await readModel.loadReading() }
    XCTAssertEqual(baseline.goal.provenance, .confirmedPersonalTarget)
    XCTAssertEqual(baseline.goal.calories, 2200.0, accuracy: 0.5)
    XCTAssertEqual(baseline.goal.proteinGrams, 165.0, accuracy: 0.5)  // 2200 * 0.30 / 4
    let baselineToken = try ProgressRevisionToken.read(in: stack.queue)

    // Profile/goal change: weight-loss goal with a personal 1600 target.
    try Fixtures.saveOnboardedProfile(stack, goal: .weightLoss, dailyCalories: 1600)

    let revised = try syncAwait { try await readModel.loadReading() }
    XCTAssertEqual(revised.goal.provenance, .confirmedPersonalTarget)
    XCTAssertEqual(revised.goal.calories, 1600.0, accuracy: 0.5)
    XCTAssertEqual(revised.goal.proteinGrams, 140.0, accuracy: 0.5)  // 1600 * 0.35 / 4
    XCTAssertEqual(revised.goal.goalName, "Weight Loss")

    let revisedToken = try ProgressRevisionToken.read(in: stack.queue)
    XCTAssertNotEqual(revisedToken.profile, baselineToken.profile)
  }

  func testSuggestedTargetIsDistinctFromConfirmedPersonalTarget() throws {
    // Not onboarded: the app-default profile is a suggested target.
    let stack = try Fixtures.makeStack(#function)
    let readModel = stack.readModel()
    let defaultReading = try syncAwait { try await readModel.loadReading() }
    XCTAssertEqual(defaultReading.goal.provenance, .suggestedTarget)
    XCTAssertEqual(defaultReading.goal.calories, 2000.0, accuracy: 0.5)

    // Onboarded with no saved target: still suggested, from the goal.
    try stack.queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO health_profile (id, display_name, age, goal, daily_calories,
            protein_pct, carbs_pct, fat_pct, dietary_restrictions, allergen_ingredient_ids)
          VALUES (1, 'Sam', 30, 'weight_loss', NULL, 0.35, 0.35, 0.30, '[]', '[]')
          """)
    }
    let nilTargetReading = try syncAwait { try await readModel.loadReading() }
    XCTAssertEqual(nilTargetReading.goal.provenance, .suggestedTarget)
    XCTAssertEqual(nilTargetReading.goal.calories, 1600.0, accuracy: 0.5)  // weightLoss suggested

    // Onboarded with a saved target: confirmed.
    try Fixtures.saveOnboardedProfile(stack, goal: .weightLoss, dailyCalories: 1750)
    let confirmedReading = try syncAwait { try await readModel.loadReading() }
    XCTAssertEqual(confirmedReading.goal.provenance, .confirmedPersonalTarget)
    XCTAssertEqual(confirmedReading.goal.calories, 1750.0, accuracy: 0.5)
  }

  // MARK: - R2: unknown days

  func testUnknownDaysAreNotPresentedAsZeroIntake() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.saveOnboardedProfile(stack)

    // Two meals: today and two days ago. The other five days have no data.
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)
    let olderId = try Fixtures.logMeal(stack, recipeId: 2, servingsConsumed: 1)
    try Fixtures.redateMeal(stack, historyId: olderId, day: Fixtures.day(2))

    let readModel = stack.readModel()
    let reading = try syncAwait { try await readModel.loadRange(lastDays: 7) }

    XCTAssertEqual(reading.days.count, 7)
    XCTAssertEqual(reading.knownDays.count, 2)
    XCTAssertEqual(reading.unknownDayCount, 5)
    XCTAssertEqual(reading.coverageSummary, "2 of 7 days with data")
    XCTAssertTrue(reading.days.filter { !$0.isKnown }.allSatisfy { $0.value == nil })

    // The average covers days with data only: (100 + 100) / 2 = 100.
    // The zero-filled repository window would have yielded 200/7 ~= 28.6.
    XCTAssertEqual(reading.averageCalories ?? 0, 100.0, accuracy: 0.5)
  }

  // MARK: - R2: source switch labelling

  func testHealthSourceIsLabelledAndNeverBlended() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)  // local: 100 kcal

    let health = FakeAppleHealthService(
      status: .authorized,
      todayTotals: AppleHealthNutritionTotals(
        calories: 333.5, proteinGrams: 30, carbsGrams: 20, fatGrams: 10,
        fiberGrams: 0, sugarGrams: 0, sodiumMilligrams: 0),
      dailyDays: [])
    let readModel = stack.readModel(health: health)

    let today = try syncAwait { try await readModel.loadToday() }
    XCTAssertEqual(today.source, .appleHealth)
    XCTAssertEqual(today.totals.calories, 333.5, accuracy: 0.01)
    XCTAssertNil(today.fallbackReason)

    // After an authorization change the reading is local, labelled local,
    // and never blended with the Health data seen before the switch.
    health.status = .notDetermined
    let localToday = try syncAwait { try await readModel.loadToday() }
    XCTAssertEqual(localToday.source, .localJournal)
    XCTAssertEqual(localToday.totals.calories, 100.0, accuracy: 0.5)
    XCTAssertNil(localToday.fallbackReason)
  }

  func testHealthFailureFallsBackToLocalWithVisibleReason() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)  // local: 100 kcal

    let health = FakeAppleHealthService(
      status: .authorized,
      errorToThrow: FakeHealthError.timeout)
    let readModel = stack.readModel(health: health)

    let today = try syncAwait { try await readModel.loadToday() }
    XCTAssertEqual(today.source, .localJournal)
    XCTAssertEqual(today.totals.calories, 100.0, accuracy: 0.5)
    XCTAssertTrue(
      today.fallbackReason?.hasPrefix("Apple Health read failed:") == true,
      "fallback must surface a visible reason, got: \(today.fallbackReason ?? "nil")")

    let week = try syncAwait { try await readModel.loadRange(lastDays: 7) }
    XCTAssertEqual(week.source, .localJournal)
    XCTAssertEqual(week.knownDays.first?.value?.calories ?? 0, 100.0, accuracy: 0.5)
    XCTAssertTrue(
      week.fallbackReason?.hasPrefix("Apple Health read failed:") == true,
      "fallback must surface a visible reason, got: \(week.fallbackReason ?? "nil")")
  }

  func testHealthZeroSampleDaysPresentAsNoData() throws {
    let stack = try Fixtures.makeStack(#function)

    // Health series: today carries samples; two days ago is all zeros (no
    // samples recorded); the rest of the window is absent.
    let twoDaysAgoKey = ProgressAggregation.dayKey(Fixtures.day(2))
    let health = FakeAppleHealthService(
      status: .authorized,
      dailyDays: [
        AppleHealthNutritionDay(
          date: Fixtures.day(0),
          totals: AppleHealthNutritionTotals(
            calories: 480, proteinGrams: 25, carbsGrams: 50, fatGrams: 12,
            fiberGrams: 0, sugarGrams: 0, sodiumMilligrams: 0)),
        AppleHealthNutritionDay(
          date: Fixtures.day(2),
          totals: AppleHealthNutritionTotals(
            calories: 0, proteinGrams: 0, carbsGrams: 0, fatGrams: 0,
            fiberGrams: 0, sugarGrams: 0, sodiumMilligrams: 0)),
      ])
    let readModel = stack.readModel(health: health)

    let week = try syncAwait { try await readModel.loadRange(lastDays: 7) }
    XCTAssertEqual(week.source, .appleHealth)
    XCTAssertEqual(week.knownDays.count, 1)
    XCTAssertNil(week.days.first { ProgressAggregation.dayKey($0.date) == twoDaysAgoKey }?.value)
    XCTAssertEqual(week.averageCalories ?? 0, 480.0, accuracy: 0.01)
  }

  // MARK: - R3: seeded first-log scenario

  func testSeededFirstLogScenarioPresentsHonestEmptyReading() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.saveOnboardedProfile(stack)
    // No meals logged yet: the seeded first-log scenario.

    let readModel = stack.readModel()
    let reading = try syncAwait { try await readModel.loadReading() }

    XCTAssertTrue(reading.recentJournal.isEmpty)
    XCTAssertEqual(reading.stats.totalMealsCooked, 0)
    XCTAssertEqual(reading.stats.currentStreak, 0)
    XCTAssertEqual(reading.today.source, .localJournal)
    XCTAssertEqual(reading.today.totals.calories, 0.0, accuracy: 0.01)
    // No day has data: the average is nil (nothing to average), not 0.
    XCTAssertEqual(reading.weekly.knownDays.count, 0)
    XCTAssertNil(reading.weekly.averageCalories)
    XCTAssertEqual(reading.weekly.coverageSummary, "0 of 7 days with data")
  }

  // MARK: - R3: deletion and observation invalidation

  func testDeletionDropsAggregatesAndInvalidates() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)
    try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)

    let baseline = try stack.userData.todayMacros()
    XCTAssertEqual(baseline.calories, 200.0, accuracy: 0.5)
    let baselineToken = try ProgressRevisionToken.read(in: stack.queue)

    try stack.queue.write { db in
      try db.execute(sql: "DELETE FROM cooking_history WHERE id = ?", arguments: [Int64(1)])
    }

    let revised = try stack.userData.todayMacros()
    XCTAssertEqual(revised.calories, 100.0, accuracy: 0.5)
    let revisedToken = try ProgressRevisionToken.read(in: stack.queue)
    XCTAssertNotEqual(revisedToken, baselineToken)
  }

  /// The real invalidation contract: the observation fires with a changed
  /// token on portion edits, date shifts, and profile/goal changes.
  func testObservationFiresOnPortionDateAndProfileRevisions() throws {
    let stack = try Fixtures.makeStack(#function)
    try Fixtures.saveOnboardedProfile(stack)
    let historyId = try Fixtures.logMeal(stack, recipeId: 1, servingsConsumed: 1)

    // The seeded state, read before the observation starts.
    let seeded = try ProgressRevisionToken.read(in: stack.queue)

    let changed = LockedFlag()

    let cancellable = ProgressRevisionToken.observation().start(
      in: stack.queue,
      scheduling: .async(onQueue: DispatchQueue(label: "test.revision-observation")),
      onError: { error in
        XCTFail("observation failed: \(error)")
      },
      onChange: { token in
        if token != seeded {
          changed.set()
        }
      })
    defer { cancellable.cancel() }

    // Apply all three revision kinds; each must invalidate.
    try stack.queue.write { db in
      try db.execute(
        sql: "UPDATE cooking_history SET portion_multiplier = 2.0 WHERE id = ?",
        arguments: [historyId])
    }
    try Fixtures.redateMeal(stack, historyId: historyId, day: Fixtures.day(1))
    try Fixtures.saveOnboardedProfile(stack, goal: .weightLoss, dailyCalories: 1600)

    // Poll without a run loop; the observation fires on its own queue.
    for _ in 0..<300 {
      if changed.isSet() { return }
      Thread.sleep(forTimeInterval: 0.02)
    }
    XCTFail("timed out waiting for observation delivery after revisions")
  }
}

/// A thread-safe boolean for observing callbacks from polling tests
/// (corelibs-xctest keeps `XCTestExpectation.isFulfilled` private).
final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func isSet() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

// MARK: - Helpers

/// Queue-level read convenience: the canonical `read(in:)` takes a
/// `Database`; this wraps a synchronous `DatabaseQueue.read`.
extension ProgressRevisionToken {
  static func read(in queue: DatabaseQueue) throws -> ProgressRevisionToken {
    try queue.read { db in
      try ProgressRevisionToken.read(in: db)
    }
  }
}

enum FakeHealthError: Error, CustomStringConvertible {
  case timeout

  var description: String { "timeout" }

  var localizedDescription: String { "timeout" }
}

extension Fixtures {
  static func saveOnboardedProfile(
    _ stack: Stack,
    goal: HealthGoal = .maintenance,
    dailyCalories: Int? = 2200
  ) throws {
    let split = goal.defaultMacroSplit
    let profile = HealthProfile(
      displayName: "Sam",
      age: 30,
      goal: goal,
      dailyCalories: dailyCalories,
      proteinPct: split.protein,
      carbsPct: split.carbs,
      fatPct: split.fat,
      dietaryRestrictions: "[]",
      allergenIngredientIds: "[]",
      updatedAt: Date())
    try stack.userData.saveHealthProfile(profile)
  }
}
