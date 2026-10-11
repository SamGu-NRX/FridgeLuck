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
  private func makeWorld(_ name: String) throws -> (queue: DatabaseQueue, readModel: HomeFlowReadModel) {
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
    return (queue, readModel)
  }

  /// A saved profile with display name and in-range age — what makes
  /// `hasCompletedOnboarding()` true.
  private func saveOnboardingProfile(_ world: (queue: DatabaseQueue, readModel: HomeFlowReadModel)) throws {
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
  private func seedCatalog(_ world: (queue: DatabaseQueue, readModel: HomeFlowReadModel)) throws {
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
    XCTAssertEqual(result.snapshot.ingredientCount, 0)
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
    XCTAssertEqual(result.snapshot.ingredientCount, 1)
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
}
