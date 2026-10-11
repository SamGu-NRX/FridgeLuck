import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// Acceptance tests for the app flow through the separate plan store: relaunch
/// restore, editable review actions, stale-input detection, and persistence.
/// Uses the real repositories over fully migrated in-memory SQLite.
@MainActor
final class WeeklyPlanAppFlowTests: XCTestCase {
  // MARK: - Fixtures

  private struct Fixture {
    let dbQueue: DatabaseQueue
    let inventoryRepository: InventoryRepository
    let recipeRepository: RecipeRepository
    let ingredientRepository: IngredientRepository
    let userDataRepository: UserDataRepository
    let store: WeeklyPlanStore
    let directory: URL
  }

  /// Recipes:
  /// 101 — needs 100 g of 1 (required) + 50 g of 2 (optional)
  /// 102 — needs 100 g of 2 (required)
  /// 103 — needs 5000 g of 1 (required): never feasible on the fixture stock
  /// 104 — needs 100 g of 3 (required)
  private func makeFixture() throws -> Fixture {
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)

    try dbQueue.write { db in
      for (id, name) in [(1, "rice"), (2, "onion"), (3, "lentils")] {
        try db.execute(
          sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat, typical_unit) VALUES (?, ?, 0, 0, 0, 0, 'g')",
          arguments: [id, name])
      }
      let recipes: [(Int64, String, Int)] = [
        (101, "Rice Bowl", 25), (102, "Onion Soup", 20), (103, "Feast", 90), (104, "Lentil Stew", 40),
      ]
      for (id, title, minutes) in recipes {
        try db.execute(
          sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source) VALUES (?, ?, ?, 2, '', 0, 'bundled')",
          arguments: [id, title, minutes])
      }
      let rows: [(Int64, Int64, Bool, Double)] = [
        (101, 1, true, 100), (101, 2, false, 50),
        (102, 2, true, 100),
        (103, 1, true, 5000),
        (104, 3, true, 100),
      ]
      for (recipeId, ingredientId, required, grams) in rows {
        try db.execute(
          sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES (?, ?, ?, ?, '')",
          arguments: [recipeId, ingredientId, required, grams])
      }
    }

    let inventoryRepository = InventoryRepository(db: dbQueue)
    try inventoryRepository.addLot(
      ingredientId: 1, quantityGrams: 1000, location: .fridge, confidenceScore: 1, source: .manual)
    try inventoryRepository.addLot(
      ingredientId: 2, quantityGrams: 500, location: .fridge, confidenceScore: 1, source: .manual)
    try inventoryRepository.addLot(
      ingredientId: 3, quantityGrams: 400, location: .fridge, confidenceScore: 1, source: .manual)

    let nutritionService = NutritionService(db: dbQueue)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("weekly-plan-flow-tests-" + UUID().uuidString, isDirectory: true)
    return Fixture(
      dbQueue: dbQueue,
      inventoryRepository: inventoryRepository,
      recipeRepository: RecipeRepository(
        db: dbQueue,
        nutritionService: nutritionService,
        healthScoringService: HealthScoringService(nutritionService: nutritionService, db: dbQueue),
        personalizationService: PersonalizationService(db: dbQueue)
      ),
      ingredientRepository: IngredientRepository(db: dbQueue),
      userDataRepository: UserDataRepository(db: dbQueue),
      store: WeeklyPlanStore(directory: directory),
      directory: directory)
  }

  private func makeViewModel(_ fixture: Fixture) -> WeeklyPlanViewModel {
    let model = WeeklyPlanViewModel(
      inventoryRepository: fixture.inventoryRepository,
      recipeRepository: fixture.recipeRepository,
      ingredientRepository: fixture.ingredientRepository,
      userDataRepository: fixture.userDataRepository,
      store: fixture.store)
    model.load()
    return model
  }

  // MARK: - Compute, relaunch, staleness

  func testRecomputePersistsAFeasibleDraft() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)

    XCTAssertNil(model.flowState.entry, "A fresh kitchen has no stored plan.")
    model.recompute()

    let plan = try XCTUnwrap(model.flowState.plan)
    XCTAssertTrue(plan.isFeasible, "Fixture stock covers three recipes across three slots.")
    XCTAssertEqual(model.flowState.entry?.phase, .draft)
    XCTAssertNotNil(fixture.store.load(), "The draft persists through the separate store.")
  }

  func testRelaunchRestoresTheAcceptedPlanUnstale() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)
    model.recompute()
    model.accept()
    XCTAssertEqual(model.flowState.entry?.phase, .accepted)

    // Relaunch: a brand-new view model over the same store and unchanged inputs.
    let relaunched = makeViewModel(fixture)
    let entry = try XCTUnwrap(relaunched.flowState.entry)
    XCTAssertEqual(entry.phase, .accepted)
    XCTAssertFalse(relaunched.flowState.isStale)
  }

  func testStockChangeMakesTheRestoredPlanStaleWithoutRewritingIt() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)
    model.recompute()
    model.accept()
    let stored = try XCTUnwrap(fixture.store.load())

    // The kitchen moves underneath the accepted plan.
    try fixture.inventoryRepository.addLot(
      ingredientId: 1, quantityGrams: 50, location: .fridge, confidenceScore: 1, source: .manual)

    let relaunched = makeViewModel(fixture)
    let entry = try XCTUnwrap(relaunched.flowState.entry)
    XCTAssertTrue(relaunched.flowState.isStale, "A changed fingerprint must show as stale.")
    XCTAssertEqual(entry.phase, .accepted, "Staleness is displayed, never auto-fixed.")
    XCTAssertEqual(entry.plan.assignments, stored.plan.assignments, "The plan itself is untouched.")
  }

  // MARK: - Editing

  func testEditingAnAcceptedSlotDemotesItToDraft() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)
    model.recompute()
    model.accept()

    // Swap a slot that is not already cooking the lentil stew over to it.
    let target = try XCTUnwrap(
      model.flowState.plan?.assignments.first(where: { $0.recipeId != 104 }))
    model.edit(slotId: target.slotId, newRecipeId: 104)

    XCTAssertEqual(model.flowState.entry?.phase, .draft, "Any edit demotes acceptance.")
    XCTAssertNil(model.flowState.entry?.acceptedAt)
    XCTAssertNil(model.flowState.rejectionReason)
    XCTAssertEqual(
      try XCTUnwrap(fixture.store.load()).phase, .draft, "The demotion persists.")
  }

  func testInfeasibleEditIsRejectedAndNothingChanges() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)
    model.recompute()
    model.accept()
    let before = try XCTUnwrap(fixture.store.load())

    // Feast needs 5000 g of rice; the fixture holds 1000 g.
    let target = try XCTUnwrap(
      model.flowState.plan?.assignments.first(where: { $0.recipeId != 103 }))
    model.edit(slotId: target.slotId, newRecipeId: 103)

    XCTAssertNotNil(model.flowState.rejectionReason, "A breaking edit shows its reason.")
    XCTAssertEqual(model.flowState.entry?.phase, .accepted, "Rejection never demotes.")
    XCTAssertEqual(try XCTUnwrap(fixture.store.load()), before, "Disk is untouched.")
  }

  func testRemovingASlotKeepsTheRemainderAndDemotesToDraft() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)
    model.recompute()
    model.accept()

    let before = try XCTUnwrap(model.flowState.plan?.assignments.count)
    let slotId = try XCTUnwrap(model.flowState.plan?.assignments.first?.slotId)
    model.remove(slotId: slotId)

    let plan = try XCTUnwrap(model.flowState.plan)
    XCTAssertEqual(plan.assignments.count, before - 1)
    XCTAssertEqual(model.flowState.entry?.phase, .draft)
    XCTAssertTrue(plan.isFeasible, "Dropping a slot can only free stock.")
  }

  func testDiscardClearsThePlanAndTheStore() throws {
    let fixture = try makeFixture()
    let model = makeViewModel(fixture)
    model.recompute()

    model.discard()

    XCTAssertNil(model.flowState.entry)
    XCTAssertNil(fixture.store.load(), "Removing the plan clears the store.")
  }
}
