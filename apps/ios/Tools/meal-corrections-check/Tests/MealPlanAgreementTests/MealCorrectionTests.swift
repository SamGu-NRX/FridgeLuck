import GRDB
import XCTest

@testable import FridgeLuck

/// Deliberate single-entry corrections and deletions: accepted revisions, compensation
/// bounded by this meal's own claims, idempotent retries, streak-day moves, and the
/// invariant that corrections and deletions never record confidence-study outcomes.
final class MealCorrectionTests: XCTestCase {
  // MARK: - Recording compensating double

  /// Stands in for the inventory-maintenance stream's compensating operation: records
  /// every request and echoes the deltas back (the "fully applied" case), so tests can
  /// pin what the correction service asks for — and that it never asks twice.
  /// Internally locked; Sendable by construction of the lock.
  private final class RecordingCompensator: InventoryCompensating, @unchecked Sendable {
    struct Call: Equatable {
      var sourceRef: String
      var deltas: [InventoryCompensationDelta]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _errorToThrow: (any Error)?

    var calls: [Call] {
      lock.lock()
      defer { lock.unlock() }
      return _calls
    }

    var errorToThrow: (any Error)? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return _errorToThrow
      }
      set {
        lock.lock()
        defer { lock.unlock() }
        _errorToThrow = newValue
      }
    }

    func compensate(
      in db: Database, deltas: [InventoryCompensationDelta], sourceRef: String
    ) throws -> [InventoryCompensationDelta] {
      lock.lock()
      let error = _errorToThrow
      lock.unlock()
      if let error { throw error }
      lock.lock()
      _calls.append(Call(sourceRef: sourceRef, deltas: deltas))
      lock.unlock()
      return deltas
    }
  }

  // MARK: - Fixture helpers

  private func assertEqual(
    _ actual: [Double], _ expected: [Double], accuracy: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard actual.count == expected.count else {
      XCTFail("count mismatch: \(actual.count) vs \(expected.count)", file: file, line: line)
      return
    }
    for (index, (a, e)) in zip(actual, expected).enumerated() {
      guard abs(a - e) <= accuracy else {
        XCTFail("element \(index): \(a) != \(e) ±\(accuracy)", file: file, line: line)
        return
      }
    }
  }

  /// Logs recipe 1 (Egg Fried Rice, serves 2) once at the given servings with plentiful
  /// stock and returns the log outcome.
  private func loggedMeal(
    db: DatabaseQueue, servingsConsumed: Int = 1, inventory: InventoryRepository? = nil
  ) throws -> MealLogService.Outcome {
    let inventory = inventory ?? InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 2_000), (2, 2_000), (3, 2_000)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)
    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: servingsConsumed, portionMultiplier: 1.0)
    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    return try log.logMeal(
      recipe: recipe, servingsConsumed: servingsConsumed, portionMultiplier: 1.0,
      sourceRefPrefix: "reverse_scan", plan: plan)
  }

  private func revisionCount(_ db: DatabaseQueue, above: Int) throws -> Int {
    try db.read {
      try Int.fetchOne(
        $0, sql: "SELECT COUNT(*) FROM cooking_history WHERE accepted_revision > ?",
        arguments: [above]) ?? 0
    }
  }

  private func confidenceEventCount(_ db: DatabaseQueue) throws -> Int {
    try db.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM confidence_signal_events") ?? 0
    }
  }

  private func streakCount(_ db: DatabaseQueue, day: String) throws -> Int {
    try db.read {
      try Int.fetchOne($0, sql: "SELECT meals_cooked FROM streaks WHERE date = ?", arguments: [day])
        ?? 0
    }
  }

  // MARK: - Correction persists an accepted revision

  func testCorrectionBumpsRevisionAndPersistsTheEditedPlanWithoutStockWrites() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    let outcome = try loggedMeal(db: db, servingsConsumed: 1, inventory: inventory)
    let corrections = MealCorrectionService(db: db)

    // Accepted: 150 g rice, 50 g egg, 10 g scallion applied. Edit rice to exactly
    // 137.5 g and scale the meal to two servings; the rice edit stays user-verified.
    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    ).rescaled(servingsConsumed: 2, portionMultiplier: 1.0)
    corrected.lines[0].plannedGrams = 137.5
    corrected.lines[0].provenance = .userVerified

    let result = try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: corrected)
    XCTAssertTrue(result.changed)
    XCTAssertEqual(result.acceptedRevision, 2)
    XCTAssertFalse(result.compensationIntegrated)  // seam unimplemented on this branch

    // The row carries the revision, the edited plan, and the new servings.
    let row = try XCTUnwrap(
      try db.read {
        try Row.fetchOne(
          $0, sql: "SELECT * FROM cooking_history WHERE id = ?", arguments: [outcome.historyId])
      })
    XCTAssertEqual(row["accepted_revision"] as Int?, 2)
    XCTAssertEqual(row["servings_consumed"] as Int?, 2)
    let accepted = try XCTUnwrap(MealConsumptionPlan.decode(from: row["accepted_plan_json"]))
    assertEqual(accepted.lines.map(\.plannedGrams), [137.5, 100, 20], accuracy: 0.001)
    // While the compensating seam is unimplemented the stored applied grams keep the
    // Kitchen's reality: what this meal actually took when it was logged.
    assertEqual(accepted.lines.map(\.appliedGrams), [150, 50, 10], accuracy: 0.001)
    XCTAssertEqual(accepted.lines[0].provenance, .userVerified)

    // No blind stock writes: the consume event trail is exactly as the log left it.
    XCTAssertEqual(try PlanFixture.eventCount(db), 3)
    let eventGrams = try PlanFixture.eventGramsByIngredient(db)
    XCTAssertEqual(eventGrams[1] ?? 0, 150, accuracy: 0.001)
    XCTAssertEqual(eventGrams[2] ?? 0, 50, accuracy: 0.001)
    XCTAssertEqual(eventGrams[3] ?? 0, 10, accuracy: 0.001)
  }

  // MARK: - Compensation bounded by this meal's own claims

  /// Seam contract: a correction's compensation request is bounded by THIS
  /// meal's own accepted claims. Consumption by later meals is never restored,
  /// stock is never reset, and unrelated rows/events stay intact — regardless
  /// of how the sibling operation implements compensation.
  func testCorrectionRequestsExactlyThisMealsOwnClaims() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)

    // Two meals logged after the first. Meal B consumes rice after meal A; correcting A
    // must ask for A's own grams only — never B's consumption, never a stock reset.
    let mealA = try loggedMeal(db: db, servingsConsumed: 1, inventory: inventory)
    let mealB = try loggedMeal(db: db, servingsConsumed: 2, inventory: inventory)

    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: mealA.historyId)?["accepted_plan_json"])
    )
    corrected.lines[0].plannedGrams = 0  // the user ate no rice after all
    let result = try corrections.correctMeal(historyId: mealA.historyId, correctedPlan: corrected)

    XCTAssertTrue(result.compensationIntegrated)
    XCTAssertEqual(compensator.calls.count, 1)
    XCTAssertEqual(
      compensator.calls.first?.sourceRef, "meal_correction:\(mealA.historyId):2")
    let request = try XCTUnwrap(compensator.calls.first?.deltas)
    XCTAssertEqual(request.count, 1)
    XCTAssertEqual(request.first?.ingredientId, 1)
    XCTAssertEqual(try XCTUnwrap(request.first?.grams), 150, accuracy: 0.001)  // meal A's own claim

    // Meal B is untouched: its row, its plan and its recorded consumption.
    let rowB = try XCTUnwrap(
      try db.read {
        try Row.fetchOne(
          $0, sql: "SELECT * FROM cooking_history WHERE id = ?", arguments: [mealB.historyId])
      })
    XCTAssertEqual(rowB["accepted_revision"] as Int?, 1)
    let planB = try XCTUnwrap(MealConsumptionPlan.decode(from: rowB["accepted_plan_json"]))
    assertEqual(planB.lines.map(\.appliedGrams), [300, 100, 20], accuracy: 0.001)
    XCTAssertEqual(try PlanFixture.eventCount(db), 6)  // 3 lines per meal, both intact
  }

  // MARK: - Idempotent retries

  /// Seam contract: retrying the same correction request must not compensate
  /// twice and must not bump the accepted revision twice — idempotence holds
  /// no matter how the sibling operation behaves.
  func testCorrectionRetryIsIdempotent() throws {
    let db = try PlanFixture.makeDatabase()
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)
    let outcome = try loggedMeal(db: db)

    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    corrected.lines[0].plannedGrams = 137.5
    let first = try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: corrected)
    let second = try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: corrected)

    XCTAssertTrue(first.changed)
    XCTAssertFalse(second.changed)  // same request repeated: no-op
    XCTAssertEqual(second.acceptedRevision, first.acceptedRevision)
    XCTAssertEqual(compensator.calls.count, 1)  // no second compensation request
    XCTAssertEqual(try revisionCount(db, above: 1), 1)  // no double revision bump
  }

  // MARK: - Deletion

  func testDeletionReturnsThisMealsClaimsAndDeletesExactlyOneRow() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)

    let mealA = try loggedMeal(db: db, servingsConsumed: 1, inventory: inventory)
    _ = try loggedMeal(db: db, servingsConsumed: 2, inventory: inventory)
    let today = PersonalizationService.formatDate(Date())
    XCTAssertEqual(try streakCount(db, day: today), 2)

    let result = try corrections.deleteMeal(historyId: mealA.historyId)

    XCTAssertTrue(result.changed)
    XCTAssertTrue(result.compensationIntegrated)
    XCTAssertEqual(compensator.calls.count, 1)
    XCTAssertEqual(compensator.calls.first?.sourceRef, "meal_delete:\(mealA.historyId)")
    let request = try XCTUnwrap(compensator.calls.first?.deltas)
    // Exactly meal A's own consumption, positive = back to the Kitchen.
    assertEqual(request.map(\.grams), [150, 50, 10], accuracy: 0.001)
    XCTAssertEqual(request.map(\.ingredientId), [1, 2, 3])

    // Exactly one row deleted; the other meal's row and both meals' event trails intact.
    XCTAssertEqual(try PlanFixture.historyCount(db), 1)
    XCTAssertEqual(try PlanFixture.eventCount(db), 6)
    // The day's streak count dropped by this one meal, floored at zero.
    XCTAssertEqual(try streakCount(db, day: today), 1)
  }

  /// Seam contract: a repeated deletion must not compensate twice — exactly
  /// one request, then a no-op with no events and no throw.
  func testRepeatedDeletionIsANoOp() throws {
    let db = try PlanFixture.makeDatabase()
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)
    let outcome = try loggedMeal(db: db)

    let first = try corrections.deleteMeal(historyId: outcome.historyId)
    let second = try corrections.deleteMeal(historyId: outcome.historyId)

    XCTAssertTrue(first.changed)
    XCTAssertFalse(second.changed)
    XCTAssertFalse(second.compensationIntegrated)
    XCTAssertEqual(compensator.calls.count, 1)  // no events, no throw on the retry
    XCTAssertEqual(try PlanFixture.historyCount(db), 0)
  }

  // MARK: - Transaction-failure results

  func testUnknownMealThrowsAndWritesNothing() throws {
    let db = try PlanFixture.makeDatabase()
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)
    _ = try loggedMeal(db: db)

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    XCTAssertThrowsError(try corrections.correctMeal(historyId: 999, correctedPlan: plan)) {
      error in
      XCTAssertTrue(error is MealCorrectionService.MealCorrectionError)
    }
    XCTAssertNoThrow(try corrections.deleteMeal(historyId: 999))

    XCTAssertEqual(try revisionCount(db, above: 1), 0)
    XCTAssertEqual(compensator.calls.count, 0)
    XCTAssertEqual(try PlanFixture.historyCount(db), 1)
  }

  func testNonFinitePlannedGramsWriteNothing() throws {
    let db = try PlanFixture.makeDatabase()
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)
    let outcome = try loggedMeal(db: db)

    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    corrected.lines[0].plannedGrams = .nan
    XCTAssertThrowsError(
      try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: corrected)
    ) { error in
      guard case MealCorrectionService.MealCorrectionError.invalidPlannedGrams = error else {
        return XCTFail("expected invalidPlannedGrams, got \(error)")
      }
    }

    // Nothing written: revision, plan JSON and event trail are as the log left them.
    XCTAssertEqual(try revisionCount(db, above: 1), 0)
    XCTAssertEqual(compensator.calls.count, 0)
    let row = try XCTUnwrap(
      try db.read {
        try Row.fetchOne(
          $0, sql: "SELECT accepted_plan_json FROM cooking_history WHERE id = ?",
          arguments: [outcome.historyId])
      })
    let accepted = try XCTUnwrap(MealConsumptionPlan.decode(from: row["accepted_plan_json"]))
    assertEqual(accepted.lines.map(\.plannedGrams), [150, 50, 10], accuracy: 0.001)
  }

  func testLegacyRowWithoutPlanCannotBeCorrectedButCanBeDeleted() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    let compensator = RecordingCompensator()
    let corrections = MealCorrectionService(db: db, inventoryCompensating: compensator)
    _ = try loggedMeal(db: db, inventory: inventory)

    // A row logged before plans existed, via the same transaction-scoped insert the
    // Cooking Celebration path uses: no accepted plan JSON, but the streak incremented.
    let personalization = PersonalizationService(db: db)
    let legacyId: Int64 = try db.write { db in
      try personalization.recordCooking(in: db, recipeId: 1)
      return try Int64.fetchOne(
        db, sql: "SELECT MAX(id) FROM cooking_history WHERE accepted_plan_json IS NULL") ?? 0
    }
    let legacyDay = PersonalizationService.formatDate(Date())
    XCTAssertEqual(try streakCount(db, day: legacyDay), 2)

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    XCTAssertThrowsError(
      try corrections.correctMeal(historyId: legacyId, correctedPlan: plan)
    ) { error in
      guard case MealCorrectionService.MealCorrectionError.mealWithoutAcceptedPlan = error else {
        return XCTFail("expected mealWithoutAcceptedPlan, got \(error)")
      }
    }

    // Deletion still works for the legacy row; with no accepted plan there are no
    // computable claims, so nothing is requested from the compensating seam.
    let result = try corrections.deleteMeal(historyId: legacyId)
    XCTAssertTrue(result.changed)
    XCTAssertFalse(result.compensationIntegrated)
    XCTAssertEqual(compensator.calls.count, 0)
    XCTAssertEqual(try PlanFixture.historyCount(db), 1)
    // The legacy day's streak count still dropped, floored at zero.
    XCTAssertEqual(try streakCount(db, day: legacyDay), 1)
  }

  // MARK: - Streak days and date edits

  func testStreakCountsMoveWithTheEditedDay() throws {
    let db = try PlanFixture.makeDatabase()
    let corrections = MealCorrectionService(db: db)
    let outcome = try loggedMeal(db: db)

    let today = PersonalizationService.formatDate(Date())
    let yesterday = PersonalizationService.formatDate(
      Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    XCTAssertEqual(try streakCount(db, day: today), 1)
    XCTAssertEqual(try streakCount(db, day: yesterday), 0)

    // Move the meal to yesterday: a missing day row is inserted, today floors at zero.
    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    _ = try corrections.correctMeal(
      historyId: outcome.historyId, correctedPlan: corrected,
      editedCookedAt: Calendar.current.date(byAdding: .day, value: -1, to: Date()))
    XCTAssertEqual(try streakCount(db, day: today), 0)
    XCTAssertEqual(try streakCount(db, day: yesterday), 1)

    // And moving it back restores today, flooring yesterday. The date edit must be
    // explicit: an unchanged request would be the idempotent no-op instead.
    corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    _ = try corrections.correctMeal(
      historyId: outcome.historyId, correctedPlan: corrected, editedCookedAt: Date())
    XCTAssertEqual(try streakCount(db, day: today), 1)
    XCTAssertEqual(try streakCount(db, day: yesterday), 0)
  }

  func testDateOnlyEditPreservesTimeOfDay() throws {
    let db = try PlanFixture.makeDatabase()
    let corrections = MealCorrectionService(db: db)
    let outcome = try loggedMeal(db: db)

    // Pin the log to Oct 9, 18:30 local time, then edit only the day.
    var components = DateComponents()
    (components.year, components.month, components.day, components.hour, components.minute) =
      (2026, 10, 9, 18, 30)
    let original = try XCTUnwrap(Calendar.current.date(from: components))
    try db.write {
      try $0.execute(
        sql: "UPDATE cooking_history SET cooked_at = ? WHERE id = ?",
        arguments: [original, outcome.historyId])
    }

    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    _ = try corrections.correctMeal(
      historyId: outcome.historyId, correctedPlan: corrected,
      editedCookedAt: Calendar.current.date(byAdding: .day, value: 1, to: original))

    let stored: Date = try XCTUnwrap(
      try db.read {
        try Date.fetchOne(
          $0, sql: "SELECT cooked_at FROM cooking_history WHERE id = ?",
          arguments: [outcome.historyId])
      })
    XCTAssertEqual(Calendar.current.component(.day, from: stored), 10)
    XCTAssertEqual(Calendar.current.component(.hour, from: stored), 18)
    XCTAssertEqual(Calendar.current.component(.minute, from: stored), 30)
  }

  // MARK: - Fixed swap set

  func testCorrectionsMayNotChangeTheSwapSet() throws {
    let db = try PlanFixture.makeDatabase()
    let corrections = MealCorrectionService(db: db)
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 2_000), (2, 2_000), (4, 2_000)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)
    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0,
      swaps: [IngredientSwap(originalIngredientId: 3, substituteIngredientId: 4, ratio: 0.5)])
    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    let outcome = try log.logMeal(
      recipe: recipe, servingsConsumed: 1, portionMultiplier: 1.0,
      sourceRefPrefix: "reverse_scan", plan: plan)

    // Quantities-only correction of the same (swapped) plan is fine.
    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    corrected.lines[2].plannedGrams = 3.5
    XCTAssertNoThrow(try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: corrected))

    // A rebuilt plan with different swaps is a different plan, not a revision: the
    // identity guard rejects it first.
    let rebuilt = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0,
      swaps: [IngredientSwap(originalIngredientId: 3, substituteIngredientId: 2, ratio: 0.5)])
    XCTAssertThrowsError(
      try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: rebuilt)
    ) { error in
      guard
        case MealCorrectionService.MealCorrectionError.correctedPlanIdentityMismatch = error
      else {
        return XCTFail("expected correctedPlanIdentityMismatch, got \(error)")
      }
    }

    // A revision that kept the identity but points a line at a different ingredient is
    // a swap-set change: rejected as such.
    var tampered = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    tampered.lines[2].resolvedIngredientId = 2  // scallion→soy line, re-pointed at egg
    XCTAssertThrowsError(
      try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: tampered)
    ) { error in
      guard case MealCorrectionService.MealCorrectionError.swapSetChanged = error else {
        return XCTFail("expected swapSetChanged, got \(error)")
      }
    }
    XCTAssertEqual(try revisionCount(db, above: 2), 0)
  }

  // MARK: - Confidence-study invariant

  func testCorrectionsAndDeletionsNeverRecordConfidenceOutcomes() throws {
    let db = try PlanFixture.makeDatabase()
    let corrections = MealCorrectionService(db: db)
    let outcome = try loggedMeal(db: db)

    var corrected = try XCTUnwrap(
      MealConsumptionPlan.decode(from: PlanFixture.acceptedRow(db, historyId: outcome.historyId)?["accepted_plan_json"])
    )
    corrected.lines[0].plannedGrams = 100
    _ = try corrections.correctMeal(historyId: outcome.historyId, correctedPlan: corrected)
    _ = try corrections.deleteMeal(historyId: outcome.historyId)

    // Only the original log may record an outcome; corrections, deletions and retries
    // (covered by the idempotency tests above) never do.
    XCTAssertEqual(try confidenceEventCount(db), 0)
  }
}
