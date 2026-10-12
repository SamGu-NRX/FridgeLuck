import GRDB
import XCTest
@testable import HomeFlowCheck

// Tests for the Home flow read model (FL4) against real migrated in-memory-style
// GRDB databases, mirroring the historical-nutrition-check fixture pattern: real
// repositories, real schema, real reads — no stubs of production behavior.
//
// The binding expiry rule is pinned here at the read layer: an inventory lot with
// no expiry date reads back with `daysUntilExpiry == nil` and
// `earliestExpiresAt == nil` — never zero, never a sentinel date.
@MainActor
final class HomeFlowReadModelTests: XCTestCase {
  // MARK: - Fixture

  /// A fully migrated queue plus a read model over real repositories.
  private func makeWorld(_ name: String) throws -> (queue: DatabaseQueue, readModel: HomeFlowReadModel, path: String) {
    let path = NSTemporaryDirectory() + "hfc-\(name)-\(UUID().uuidString).sqlite"
    var config = Configuration()
    config.foreignKeysEnabled = true
    let queue = try DatabaseQueue(path: path, configuration: config)
    try DatabaseMigrations.migrate(queue)

    let nutrition = NutritionService(db: queue)
    let scoring = HealthScoringService(nutritionService: nutrition, db: queue)
    let snapshotService = NutritionSnapshotService(db: queue)
    let personalization = PersonalizationService(db: queue, nutritionSnapshotService: snapshotService)
    let readModel = HomeFlowReadModel(
      inventory: InventoryRepository(db: queue),
      userData: UserDataRepository(db: queue),
      personalization: personalization,
      spoilage: SpoilageService(inventoryRepository: InventoryRepository(db: queue)),
      recipes: RecipeRepository(
        db: queue,
        nutritionService: nutrition,
        healthScoringService: scoring,
        personalizationService: personalization
      ),
      ingredients: IngredientRepository(db: queue)
    )
    return (queue, readModel, path)
  }

  /// A saved profile with display name and in-range age — what makes
  /// `hasCompletedOnboarding()` true.
  private func saveOnboardingProfile(_ world: (queue: DatabaseQueue, readModel: HomeFlowReadModel, path: String)) throws {
    try world.queue.write { db in
      var profile = HealthProfile(
        displayName: "Sam",
        age: 30,
        goal: .general,
        dailyCalories: nil,
        proteinPct: 0.25,
        carbsPct: 0.45,
        fatPct: 0.30,
        dietaryRestrictions: "[]",
        allergenIngredientIds: "[]",
        updatedAt: nil
      )
      profile.id = 1
      try profile.save(db)
    }
  }

  /// One catalog ingredient and one recipe that requires it.
  private func seedCatalog(_ world: (queue: DatabaseQueue, readModel: HomeFlowReadModel, path: String)) throws {
    try world.queue.write { db in
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium) VALUES (?, 'Eggs', 143.0, 12.6, 0.7, 9.5, 0.0, 0.0, 142.0)",
        arguments: [1]
      )
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source) VALUES (?, 'Omelette', 10, 1, 'cook it', 0, 'bundled')",
        arguments: [1]
      )
      try db.execute(
        sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES (?, ?, 1, 100.0, '100 g')",
        arguments: [1, 1]
      )
    }
  }

  // MARK: - Cold start

  func testColdStartWithoutOnboardingProducesEmptyNewInputs() async throws {
    let world = try makeWorld("cold")
    let result = try await world.readModel.load()

    XCTAssertFalse(result.inputs.hasCompletedOnboarding)
    XCTAssertTrue(result.inputs.inventoryItems.isEmpty)
    XCTAssertNil(result.inputs.primaryRecommendation)
    XCTAssertEqual(result.inputs.totalMealsCooked, 0)
    XCTAssertEqual(result.snapshot.stockedIngredientCount, 0)
    XCTAssertNil(result.snapshot.healthProfile)

    let state = HomeFlowStateMap.state(inputs: result.inputs, cookContext: nil)
    XCTAssertEqual(state, .emptyNew)
  }

  func testColdStartInputsHaveNoExpirySentinels() async throws {
    let world = try makeWorld("cold-expiry")
    let result = try await world.readModel.load()
    // No rows at all: nothing may invent an expiry value, not even zero.
    for item in result.inputs.inventoryItems {
      XCTAssertNil(item.daysUntilExpiry)
      XCTAssertNil(item.earliestExpiresAt)
    }
  }

  // MARK: - Stocked kitchen

  func testStockedKitchenWithMakeableRecipeProducesPartlyStocked() async throws {
    let world = try makeWorld("stocked")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1,
      quantityGrams: 400,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: nil
    )

    let result = try await world.readModel.load()

    XCTAssertTrue(result.inputs.hasCompletedOnboarding)
    XCTAssertEqual(result.inputs.inventoryItems.count, 1)
    XCTAssertEqual(result.snapshot.stockedIngredientCount, 1)
    let primary = try XCTUnwrap(result.inputs.primaryRecommendation)
    XCTAssertEqual(primary.recipeName, "Omelette")
    // Only one makeable recipe seeded: no fallbacks expected.
    XCTAssertTrue(result.inputs.fallbackOptions.isEmpty)

    let state = HomeFlowStateMap.state(inputs: result.inputs, cookContext: nil)
    XCTAssertEqual(state, .partlyStocked)
  }

  func testLotWithUnknownExpiryKeepsNilDaysUntilExpiry() async throws {
    let world = try makeWorld("unknown-expiry")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    // location: .unknown with no shelf-life profile is the public path to a lot
    // with genuinely unknown expiry (fridge/pantry/freezer defaults would derive
    // one — see testFridgeLotWithoutExpiryDerivesSevenDayShelfLife).
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1,
      quantityGrams: 400,
      location: .unknown,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: nil
    )

    let result = try await world.readModel.load()
    let item = try XCTUnwrap(result.inputs.inventoryItems.first)
    // Binding rule: unknown expiry is nil — never zero, never a sentinel.
    XCTAssertNil(item.daysUntilExpiry)
    XCTAssertNil(item.earliestExpiresAt)
    // Unknown expiry never masquerades as use-soon either.
    XCTAssertTrue(result.inputs.useSoon.isEmpty)
  }

  func testFridgeLotWithoutExpiryDerivesSevenDayShelfLife() async throws {
    // Pins the WRITER side: addLot(nil expiry) derives a shelf life (7 days for a
    // fridge with no profile row), so the read model reports a real countdown, not
    // nil. The nil path above is only reachable via location .unknown.
    let world = try makeWorld("fridge-derive")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1,
      quantityGrams: 400,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: nil
    )

    let result = try await world.readModel.load()
    let item = try XCTUnwrap(result.inputs.inventoryItems.first)
    XCTAssertEqual(item.daysUntilExpiry, 7)
    XCTAssertNotNil(item.earliestExpiresAt)
  }

  func testUseSoonSuggestionSurfacesForExpiringLot() async throws {
    let world = try makeWorld("use-soon")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1,
      quantityGrams: 400,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: tomorrow
    )

    let result = try await world.readModel.load()
    XCTAssertEqual(result.inputs.useSoon.count, 1)
    XCTAssertNotNil(result.snapshot.useSoonSuggestions.first)
  }

  func testNotOnboardedStockIsHiddenFromInputs() async throws {
    // A pre-onboarding device with rows present (defensive): the gate must still
    // resolve emptyNew because the flow treats onboarding as the entry door.
    let world = try makeWorld("not-onboarded")
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1,
      quantityGrams: 400,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: nil
    )

    let result = try await world.readModel.load()
    XCTAssertFalse(result.inputs.hasCompletedOnboarding)
    XCTAssertTrue(result.inputs.inventoryItems.isEmpty)
    XCTAssertNil(result.inputs.primaryRecommendation)
    let state = HomeFlowStateMap.state(inputs: result.inputs, cookContext: nil)
    XCTAssertEqual(state, .emptyNew)
  }

  // MARK: - Generation guard

  func testGenerationGuardOnlyAcceptsTheNewestLoad() {
    var generation = HomeLoadGeneration()
    let first = generation.begin()
    XCTAssertTrue(generation.isCurrent(first))

    let second = generation.begin()
    XCTAssertTrue(generation.isCurrent(second))
    XCTAssertFalse(generation.isCurrent(first), "a superseded load must be stale")

    // Equality/value semantics: guards are plain values, copyable.
    let copy = generation
    XCTAssertTrue(copy.isCurrent(second))
  }

  func testReadModelLoadResultFeedsTheGateWithoutCookContext() async throws {
    // End-to-end seam: read result -> map, with the cooking override supplied by
    // the view (the Live Assistant coordinator's surfaced context), not by the
    // read model.
    let world = try makeWorld("seam")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1,
      quantityGrams: 400,
      location: .fridge,
      confidenceScore: 0.9,
      source: .manual,
      expiresAt: nil
    )

    let result = try await world.readModel.load()
    let cooking = HomeFlowStateMap.state(
      inputs: result.inputs,
      cookContext: HomeCookContext(recipeName: "Omelette")
    )
    XCTAssertEqual(cooking, .cooking(HomeCookContext(recipeName: "Omelette")))
  }

  // MARK: - Stock evidence (review fix: quantity evidence, not catalog counts)

  func testPopulatedCatalogWithEmptyPantryResolvesEmptyNew() async throws {
    // The regression the reviewer called out: a populated recipe catalog with zero
    // pantry stock is an empty-new kitchen — on the canonical inputs path AND on
    // the snapshot projection the shipped view consumes.
    let world = try makeWorld("catalog-full-pantry-empty")
    try saveOnboardingProfile(world)
    try seedCatalog(world)

    let result = try await world.readModel.load()

    XCTAssertTrue(result.inputs.hasCompletedOnboarding)
    XCTAssertTrue(result.inputs.inventoryItems.isEmpty, "catalog rows are not stock")
    XCTAssertEqual(result.snapshot.stockedIngredientCount, 0)
    XCTAssertEqual(result.snapshot.recipeCount, 1, "the catalog itself is untouched")

    let canonical = HomeFlowStateMap.state(inputs: result.inputs, cookContext: nil)
    let projected = HomeFlowStateMap.state(from: result.snapshot, cookContext: nil)
    XCTAssertEqual(canonical, .emptyNew)
    XCTAssertEqual(projected, .emptyNew)
  }

  func testStockedCountIsDistinctIngredientsWithQuantityEvidence() async throws {
    let world = try makeWorld("distinct-stock")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    try await world.queue.write { db in
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium) VALUES (?, 'Rice', 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 1.0)",
        arguments: [2]
      )
    }
    let inventory = InventoryRepository(db: world.queue)
    // Two lots of the same ingredient in different locations plus one other
    // ingredient: three active (ingredient, location) rows, two stocked
    // ingredients. The stock evidence counts distinct ingredients.
    _ = try inventory.addLot(
      ingredientId: 1, quantityGrams: 200, location: .fridge,
      confidenceScore: 0.9, source: .manual, expiresAt: nil
    )
    _ = try inventory.addLot(
      ingredientId: 1, quantityGrams: 300, location: .pantry,
      confidenceScore: 0.9, source: .manual, expiresAt: nil
    )
    _ = try inventory.addLot(
      ingredientId: 2, quantityGrams: 1000, location: .pantry,
      confidenceScore: 0.9, source: .manual, expiresAt: nil
    )

    let result = try await world.readModel.load()

    XCTAssertEqual(
      result.inputs.inventoryItems.count, 3,
      "active items group lots by (ingredient, location)"
    )
    XCTAssertEqual(
      result.snapshot.stockedIngredientCount, 2,
      "stock evidence counts distinct ingredients with remaining grams"
    )
  }

  func testDepletingAllStockTransitionsPartlyStockedToEmptyNew() async throws {
    let world = try makeWorld("deplete")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1, quantityGrams: 400, location: .fridge,
      confidenceScore: 0.9, source: .manual, expiresAt: nil
    )

    let stocked = try await world.readModel.load()
    XCTAssertEqual(HomeFlowStateMap.state(inputs: stocked.inputs, cookContext: nil), .partlyStocked)

    // Any writer's depletion — the read layer sees the same database.
    try await world.queue.write { db in
      try db.execute(sql: "UPDATE inventory_lots SET remaining_grams = 0")
    }

    let depleted = try await world.readModel.load()
    XCTAssertEqual(depleted.snapshot.stockedIngredientCount, 0)
    XCTAssertEqual(HomeFlowStateMap.state(inputs: depleted.inputs, cookContext: nil), .emptyNew)
    XCTAssertEqual(HomeFlowStateMap.state(from: depleted.snapshot, cookContext: nil), .emptyNew)
  }

  func testDepletedStockWithMealsCookedStaysReturning() async throws {
    let world = try makeWorld("depleted-returning")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1, quantityGrams: 400, location: .fridge,
      confidenceScore: 0.9, source: .manual, expiresAt: nil
    )

    let stocked = try await world.readModel.load()
    XCTAssertEqual(HomeFlowStateMap.state(inputs: stocked.inputs, cookContext: nil), .partlyStocked)

    // The user cooks, then uses everything up. Meals are durable evidence: the
    // depleted kitchen is still a returning user's kitchen. The insert targets the
    // fresh-schema columns (auto-increment id; servings_consumed nullable).
    try await world.queue.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, cooked_at, rating) VALUES (1, datetime('now'), 4)"
      )
    }
    // The domain invariant: historical meals carry a current-version nutrition
    // snapshot — dated aggregate reads fail closed without one. The fixture
    // upholds the same invariant the real meal writer does.
    try await world.queue.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history_nutrition_snapshots (history_id, recipe_servings, snapshot_version, provenance) VALUES ((SELECT MAX(id) FROM cooking_history), 1, 1, 'logged_at_capture')"
      )
    }
    try await world.queue.write { db in
      try db.execute(sql: "UPDATE inventory_lots SET remaining_grams = 0")
    }

    let depleted = try await world.readModel.load()
    XCTAssertEqual(depleted.snapshot.stockedIngredientCount, 0)
    XCTAssertGreaterThan(
      depleted.snapshot.totalMealsCooked, 0,
      "depletion must not erase cooked meals"
    )
    XCTAssertEqual(HomeFlowStateMap.state(inputs: depleted.inputs, cookContext: nil), .returning)
    XCTAssertEqual(HomeFlowStateMap.state(from: depleted.snapshot, cookContext: nil), .returning)
  }

  func testRelaunchReopeningTheSameDatabaseResolvesTheSameState() async throws {
    // Persistence across relaunch: Home resolves the same state from a freshly
    // reopened database — nothing in-memory participates in the derivation.
    let world = try makeWorld("relaunch")
    try saveOnboardingProfile(world)
    try seedCatalog(world)
    _ = try InventoryRepository(db: world.queue).addLot(
      ingredientId: 1, quantityGrams: 400, location: .fridge,
      confidenceScore: 0.9, source: .manual, expiresAt: nil
    )

    let first = try await world.readModel.load()
    let firstState = HomeFlowStateMap.state(inputs: first.inputs, cookContext: nil)
    XCTAssertEqual(firstState, .partlyStocked)

    // "Relaunch": reopen the same file with brand-new repositories.
    var config = Configuration()
    config.foreignKeysEnabled = true
    let reopenedQueue = try DatabaseQueue(path: world.path, configuration: config)
    let nutrition = NutritionService(db: reopenedQueue)
    let scoring = HealthScoringService(nutritionService: nutrition, db: reopenedQueue)
    let snapshotService = NutritionSnapshotService(db: reopenedQueue)
    let personalization = PersonalizationService(db: reopenedQueue, nutritionSnapshotService: snapshotService)
    let relaunched = HomeFlowReadModel(
      inventory: InventoryRepository(db: reopenedQueue),
      userData: UserDataRepository(db: reopenedQueue),
      personalization: personalization,
      spoilage: SpoilageService(inventoryRepository: InventoryRepository(db: reopenedQueue)),
      recipes: RecipeRepository(
        db: reopenedQueue,
        nutritionService: nutrition,
        healthScoringService: scoring,
        personalizationService: personalization
      ),
      ingredients: IngredientRepository(db: reopenedQueue)
    )

    let second = try await relaunched.load()
    XCTAssertEqual(second.inputs, first.inputs)
    XCTAssertEqual(
      HomeFlowStateMap.state(inputs: second.inputs, cookContext: nil),
      firstState
    )
    XCTAssertEqual(
      HomeFlowStateMap.state(from: second.snapshot, cookContext: nil),
      firstState
    )
  }
}
