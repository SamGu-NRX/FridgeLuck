import GRDB
import XCTest

@testable import FridgeLuck

/// The Health sync coordinator must keep Apple Health in step with corrections and
/// deletions using stable identifiers and revisions, tolerate repeats, and never let a
/// Health failure disturb the local (authoritative) state.
///
/// The coordinator is main-actor isolated, so each test hops to the main actor and
/// builds its coordinator there; the plain GRDB fixtures stay nonisolated.
final class MealHealthSyncTests: XCTestCase {
  private var db: DatabaseQueue!
  private var inventory: InventoryRepository!
  private var log: MealLogService!
  private var corrections: MealCorrectionService!
  private var health: FakeAppleHealthServicing!

  override func setUpWithError() throws {
    db = try PlanFixture.makeDatabase()
    inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 2_000), (2, 1_200), (3, 200)])
    log = PlanFixture.makeMealLogService(db: db, inventory: inventory)
    corrections = MealCorrectionService(
      db: db, nutritionSnapshotting: NutritionSnapshotService(db: db))
    health = FakeAppleHealthServicing()
  }

  @MainActor
  private func makeCoordinator() -> MealLogSyncCoordinator {
    MealLogSyncCoordinator(
      appleHealthService: health,
      nutritionSnapshotService: NutritionSnapshotService(db: db))
  }

  /// Logs one meal from a freshly built plan and returns both the outcome and the
  /// accepted plan — corrections must edit the accepted plan, not rebuild from scratch.
  private func logMeal(servings: Int = 1, portion: Double = 1.0) throws
    -> (outcome: MealLogService.Outcome, plan: MealConsumptionPlan)
  {
    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: servings, portionMultiplier: portion)
    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    let outcome = try log.logMeal(
      recipe: recipe, servingsConsumed: servings, portionMultiplier: portion,
      sourceRefPrefix: "reverse_scan", plan: plan)
    return (outcome, plan)
  }

  private func storedRevision(historyId: Int64) throws -> Int? {
    try db.read {
      try Int.fetchOne(
        $0, sql: "SELECT accepted_revision FROM cooking_history WHERE id = ?",
        arguments: [historyId])
    }
  }

  // MARK: - Replacement (correction = delete then write, same identifier)

  @MainActor
  func testCorrectionReplacesRecordUnderSameIdentifierWithRevisionAndDate() async throws {
    let coordinator = makeCoordinator()
    let (outcome, plan) = try logMeal()
    await coordinator.syncLoggedMeal(
      historyId: outcome.historyId, recipeId: 1, mealTitle: "Egg Fried Rice",
      servingsConsumed: 1)
    let before = try XCTUnwrap(health.meal(forHistoryId: outcome.historyId))
    XCTAssertEqual(before.syncVersion, 1)

    let corrected = HealthSyncProbe.correctedPlan(from: plan)
    let recordedAt = Date(timeIntervalSince1970: 1_760_000_000)
    await coordinator.syncCorrectedMeal(
      historyId: outcome.historyId, mealTitle: "Egg Fried Rice", correctedPlan: corrected,
      acceptedRevision: 2, recordedAt: recordedAt)

    // Exactly one record, same identifier, bumped version, recorded date.
    let after = try XCTUnwrap(health.meal(forHistoryId: outcome.historyId))
    XCTAssertEqual(after.syncIdentifier, "samgu.FridgeLuck.cooking_history.\(outcome.historyId)")
    XCTAssertEqual(after.syncVersion, 2)
    XCTAssertEqual(after.date, recordedAt)
    XCTAssertEqual(
      health.records.values.filter { $0.syncIdentifier == after.syncIdentifier }.count, 1)
    // Replacement went through the initial log write, then delete-then-write on the
    // same identifier.
    XCTAssertEqual(
      health.calls,
      [
        .write("samgu.FridgeLuck.cooking_history.\(outcome.historyId)"),
        .delete("samgu.FridgeLuck.cooking_history.\(outcome.historyId)"),
        .write("samgu.FridgeLuck.cooking_history.\(outcome.historyId)"),
      ])
  }

  @MainActor
  func testCorrectedRecordCarriesCorrectedMacroTotals() async throws {
    let coordinator = makeCoordinator()
    let (outcome, plan) = try logMeal()
    let corrected = HealthSyncProbe.correctedPlan(from: plan)
    await coordinator.syncCorrectedMeal(
      historyId: outcome.historyId, mealTitle: "Egg Fried Rice", correctedPlan: corrected,
      acceptedRevision: 2, recordedAt: Date())

    let record = try XCTUnwrap(health.meal(forHistoryId: outcome.historyId))
    // Corrected 137.5 g rice + unchanged 50 g egg + unchanged 10 g scallion, each at its
    // per-100 g fixture value.
    XCTAssertEqual(record.calories, 137.5 * 1.30 + 50 * 1.55 + 10 * 0.32, accuracy: 0.001)
    XCTAssertEqual(record.proteinGrams, 137.5 * 0.027 + 50 * 0.13 + 10 * 0.018, accuracy: 0.001)
  }

  // MARK: - Removal (deletion removes exactly one meal)

  @MainActor
  func testRemovalDeletesExactlyThatMeal() async throws {
    let coordinator = makeCoordinator()
    let (first, _) = try logMeal()
    let (second, _) = try logMeal()
    await coordinator.syncLoggedMeal(
      historyId: first.historyId, recipeId: 1, mealTitle: "Egg Fried Rice", servingsConsumed: 1)
    await coordinator.syncLoggedMeal(
      historyId: second.historyId, recipeId: 1, mealTitle: "Egg Fried Rice", servingsConsumed: 1)

    await coordinator.removeLoggedMeal(historyId: first.historyId)

    XCTAssertNil(health.meal(forHistoryId: first.historyId))
    let remaining = try XCTUnwrap(health.meal(forHistoryId: second.historyId))
    XCTAssertEqual(
      remaining.syncIdentifier, "samgu.FridgeLuck.cooking_history.\(second.historyId)")
    XCTAssertEqual(health.deleteCallCount(forHistoryId: first.historyId), 1)
    XCTAssertEqual(health.deleteCallCount(forHistoryId: second.historyId), 0)
  }

  @MainActor
  func testRemovalRepeatedStaysTolerantWhenNothingFound() async throws {
    let coordinator = makeCoordinator()
    let (outcome, _) = try logMeal()
    await coordinator.removeLoggedMeal(historyId: outcome.historyId)
    await coordinator.removeLoggedMeal(historyId: outcome.historyId)

    // Both attempts were issued; nothing-found is not an error and the record stays gone.
    XCTAssertEqual(health.deleteCallCount(forHistoryId: outcome.historyId), 2)
    XCTAssertNil(health.meal(forHistoryId: outcome.historyId))
  }

  @MainActor
  func testCorrectionSyncRepeatedSettlesAtTheSameRecord() async throws {
    let coordinator = makeCoordinator()
    let (outcome, plan) = try logMeal()
    let corrected = HealthSyncProbe.correctedPlan(from: plan)
    let recordedAt = Date(timeIntervalSince1970: 1_760_000_100)
    await coordinator.syncCorrectedMeal(
      historyId: outcome.historyId, mealTitle: "Egg Fried Rice", correctedPlan: corrected,
      acceptedRevision: 2, recordedAt: recordedAt)
    await coordinator.syncCorrectedMeal(
      historyId: outcome.historyId, mealTitle: "Egg Fried Rice", correctedPlan: corrected,
      acceptedRevision: 2, recordedAt: recordedAt)

    let record = try XCTUnwrap(health.meal(forHistoryId: outcome.historyId))
    XCTAssertEqual(record.syncVersion, 2)
    XCTAssertEqual(record.date, recordedAt)
    XCTAssertEqual(
      health.records.values.filter { $0.syncIdentifier == record.syncIdentifier }.count, 1)
  }

  // MARK: - Failure isolation (local state is authoritative)

  @MainActor
  func testFailedHealthWriteNeverDisturbsLocalCorrection() async throws {
    let coordinator = makeCoordinator()
    let (outcome, plan) = try logMeal()
    health.writeError = SyncFailure()
    await coordinator.syncLoggedMeal(
      historyId: outcome.historyId, recipeId: 1, mealTitle: "Egg Fried Rice",
      servingsConsumed: 1)
    // No throw; the failed write simply never stored the record.
    XCTAssertNil(health.meal(forHistoryId: outcome.historyId))

    // The real correction still lands locally while Health is failing…
    let corrected = HealthSyncProbe.correctedPlan(from: plan)
    let revisionOutcome = try corrections.correctMeal(
      historyId: outcome.historyId, correctedPlan: corrected, editedCookedAt: nil)
    XCTAssertEqual(revisionOutcome.acceptedRevision, 2)
    XCTAssertEqual(try storedRevision(historyId: outcome.historyId), 2)

    // …and the one-shot error has been consumed, so the correction sync writes the
    // corrected record and Health catches up.
    await coordinator.syncCorrectedMeal(
      historyId: outcome.historyId, mealTitle: "Egg Fried Rice", correctedPlan: corrected,
      acceptedRevision: 2, recordedAt: Date(timeIntervalSince1970: 1_760_000_200))
    let caught = try XCTUnwrap(health.meal(forHistoryId: outcome.historyId))
    XCTAssertEqual(caught.syncVersion, 2)
  }

  @MainActor
  func testFailedHealthDeleteNeverRollsBackLocalDeletion() async throws {
    let coordinator = makeCoordinator()
    let (outcome, _) = try logMeal()
    await coordinator.syncLoggedMeal(
      historyId: outcome.historyId, recipeId: 1, mealTitle: "Egg Fried Rice", servingsConsumed: 1)
    XCTAssertNotNil(health.meal(forHistoryId: outcome.historyId))

    health.deleteError = SyncFailure()
    let deleteOutcome = try corrections.deleteMeal(historyId: outcome.historyId)
    XCTAssertTrue(deleteOutcome.changed)
    await coordinator.removeLoggedMeal(historyId: outcome.historyId)

    // The local deletion stands; the failed Health delete left the stale record behind.
    let storedCount = try await db.read {
      try Int.fetchOne(
        $0, sql: "SELECT COUNT(*) FROM cooking_history WHERE id = ?", arguments: [outcome.historyId])
    }
    XCTAssertEqual(storedCount, 0)
    XCTAssertNotNil(health.meal(forHistoryId: outcome.historyId))

    // The next removal succeeds once the failure has passed.
    await coordinator.removeLoggedMeal(historyId: outcome.historyId)
    XCTAssertNil(health.meal(forHistoryId: outcome.historyId))
  }

  // MARK: - Authorization gates

  @MainActor
  func testSyncNoOpsWhenUnauthorized() async throws {
    let coordinator = makeCoordinator()
    let (outcome, plan) = try logMeal()
    health.isAuthorized = false

    await coordinator.syncLoggedMeal(
      historyId: outcome.historyId, recipeId: 1, mealTitle: "Egg Fried Rice",
      servingsConsumed: 1)
    await coordinator.syncCorrectedMeal(
      historyId: outcome.historyId, mealTitle: "Egg Fried Rice",
      correctedPlan: HealthSyncProbe.correctedPlan(from: plan), acceptedRevision: 2,
      recordedAt: Date())
    await coordinator.removeLoggedMeal(historyId: outcome.historyId)

    XCTAssertTrue(health.calls.isEmpty)
  }

  private struct SyncFailure: Error {}
}
