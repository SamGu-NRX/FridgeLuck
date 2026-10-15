import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

final class UseSoonRecommendationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testRepositoryRanksUseSoonBeforeApplyingLimitWithoutChangingStandardOrder() throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1], to: fixture)
    try addRecipe(102, minutes: 45, required: [2], to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)

    let standard = try fixture.recipes.findMakeable(with: [1, 2], profile: .default, limit: 1)
    let useSoon = try fixture.recipes.findMakeable(
      with: [1, 2], profile: .default, limit: 1, order: .useSoon, now: now
    )

    XCTAssertEqual(standard.map(\.id), [101])
    XCTAssertEqual(useSoon.map(\.id), [102])
    XCTAssertEqual(useSoon.first?.rankingReasons.first, "Uses spinach from your use-soon stock")
    XCTAssertFalse(standard[0].rankingReasons.contains { $0.contains("use-soon") })
  }

  func testExpiredUnknownDepletedAndBeyondWindowLotsDoNotPromoteRecipes() throws {
    let cases: [(expiry: Date?, remaining: Double, promoted: Bool)] = [
      (now.addingTimeInterval(-1), 100, false),
      (now, 100, false),
      (nil, 100, false),
      (now.addingTimeInterval(1), 0, false),
      (now.addingTimeInterval(3 * 86400 + 1), 100, false),
      (now.addingTimeInterval(3 * 86400), 100, true),
      (now.addingTimeInterval(1), 0.5, true),
    ]
    for testCase in cases {
      let fixture = try makeFixture()
      try addRecipe(101, minutes: 10, required: [1], to: fixture)
      try addRecipe(102, minutes: 45, required: [2], to: fixture)
      try addLot(
        ingredient: 2, expiry: testCase.expiry, remaining: testCase.remaining, to: fixture
      )
      let results = try fixture.recipes.findMakeable(
        with: [1, 2], profile: .default, order: .useSoon, now: now
      )
      XCTAssertEqual(results.map(\.id), testCase.promoted ? [102, 101] : [101, 102])
      XCTAssertEqual(
        results.first?.rankingReasons.first?.contains("use-soon"), testCase.promoted
      )
    }
  }

  func testEarliestUsableLotWinsAndExplanationNamesThatIngredient() throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1], to: fixture)
    try addRecipe(102, minutes: 45, required: [2, 3], to: fixture)
    try addLot(ingredient: 1, expiry: now.addingTimeInterval(7200), to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(-3600), to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(10800), to: fixture)
    try addLot(ingredient: 3, expiry: now.addingTimeInterval(3600), to: fixture)

    let results = try fixture.recipes.findMakeable(
      with: [1, 2, 3], profile: .default, order: .useSoon, now: now
    )

    XCTAssertEqual(results.map(\.id), [102, 101])
    XCTAssertEqual(results[0].rankingReasons.first, "Uses tomatoes from your use-soon stock")
    XCTAssertEqual(results[1].rankingReasons.first, "Uses rice from your use-soon stock")
  }

  func testOptionalAndZeroQuantityIngredientsDoNotCreateUseSoonReasons() throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1], to: fixture)
    try addRecipe(102, minutes: 45, required: [1], optional: [2], to: fixture)
    try addRecipe(103, minutes: 45, required: [1, 3], to: fixture)
    try fixture.db.write { db in
      try db.execute(
        sql: "UPDATE recipe_ingredients SET quantity_grams = 0 WHERE recipe_id = 103 AND ingredient_id = 3"
      )
    }
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)
    try addLot(ingredient: 3, expiry: now.addingTimeInterval(3600), to: fixture)

    let results = try fixture.recipes.findMakeable(
      with: [1, 2, 3], profile: .default, order: .useSoon, now: now
    )

    XCTAssertEqual(Set(results.compactMap(\.id)), [101, 102, 103])
    XCTAssertTrue(results.allSatisfy { !$0.rankingReasons.contains { $0.contains("use-soon") } })
  }

  func testUrgentStockOutsideAvailableIngredientsDoesNotPromoteNearMatch() throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1, 3], to: fixture)
    try addRecipe(102, minutes: 45, required: [1, 2], to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)

    let results = try fixture.recipes.findNearMatch(
      with: [1], profile: .default, order: .useSoon, now: now
    )

    XCTAssertEqual(results.map(\.id), [101, 102])
    XCTAssertTrue(results.allSatisfy { !$0.rankingReasons.contains { $0.contains("use-soon") } })
  }

  func testUrgencyNeverBypassesAllergenOrDietFilters() throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1], tags: RecipeTags.vegan.rawValue, to: fixture)
    try addRecipe(102, minutes: 45, required: [2], to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)
    var allergic = HealthProfile.default
    allergic.allergenIngredientIds = "[2]"
    var vegan = HealthProfile.default
    vegan.dietaryRestrictions = "[\"vegan\"]"

    for profile in [allergic, vegan] {
      let results = try fixture.recipes.findMakeable(
        with: [1, 2], profile: profile, order: .useSoon, now: now
      )
      XCTAssertEqual(results.map(\.id), [101])
    }
  }

  func testFewerMissingIngredientsBeatMoreUrgentStock() throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 45, required: [1, 3], to: fixture)
    try addRecipe(102, minutes: 10, required: [2, 3, 4], to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)

    let results = try fixture.recipes.findNearMatch(
      with: [1, 2], profile: .default, maxMissingRequired: 2, order: .useSoon, now: now
    )

    XCTAssertEqual(results.map(\.id), [101, 102])
    XCTAssertEqual(results.map(\.missingRequiredCount), [1, 2])
  }

  @MainActor
  func testRealRecommendationEnginePublishesUseSoonOrderAndRefreshesAfterDepletion() async throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1], to: fixture)
    try addRecipe(102, minutes: 45, required: [2], to: fixture)
    try addRecipe(103, minutes: 10, required: [2, 3], to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)
    let engine = RecommendationEngine(
      recipeRepository: fixture.recipes,
      healthScoringService: fixture.health,
      recipeGenerator: NoGeneration()
    )

    await engine.findRecipes(for: [1, 2], now: now)

    XCTAssertNil(engine.error)
    XCTAssertEqual(engine.sections.exact.map(\.id), [102, 101])
    XCTAssertEqual(engine.sections.nearMatch.map(\.id), [103])
    XCTAssertEqual(engine.recommendations.map(\.id), [102, 101, 103])
    XCTAssertEqual(engine.quickSuggestion?.id, 102)
    let top = try XCTUnwrap(engine.recommendations.first)
    XCTAssertEqual(top.rankingReasons.first, "Uses spinach from your use-soon stock")

    let consumption = try InventoryRepository(db: fixture.db).applyConsumption(
      recipeId: 102, servingsConsumed: 1, sourceRef: "use-soon-test"
    )
    XCTAssertEqual(consumption.map(\.consumedGrams), [100])
    await engine.findRecipes(for: [1, 2], now: now)

    XCTAssertNil(engine.error)
    XCTAssertEqual(engine.sections.exact.map(\.id), [101, 102])
    XCTAssertEqual(engine.quickSuggestion?.id, 101)
    XCTAssertTrue(engine.recommendations.allSatisfy {
      !$0.rankingReasons.contains { $0.contains("use-soon") }
    })
  }

  @MainActor
  func testWidenedNearMatchSearchUsesSameExpiryOrder() async throws {
    let fixture = try makeFixture()
    try addRecipe(101, minutes: 10, required: [1, 3, 4], to: fixture)
    try addRecipe(102, minutes: 45, required: [2, 3, 4], to: fixture)
    try addLot(ingredient: 2, expiry: now.addingTimeInterval(3600), to: fixture)
    let engine = RecommendationEngine(
      recipeRepository: fixture.recipes, healthScoringService: fixture.health,
      recipeGenerator: NoGeneration()
    )

    await engine.findRecipes(for: [1, 2], now: now)

    XCTAssertNil(engine.error)
    XCTAssertEqual(engine.sections.exact.map(\.id), [])
    XCTAssertEqual(engine.sections.nearMatch.map(\.id), [102, 101])
    XCTAssertEqual(engine.quickSuggestion?.id, 102)
  }

  private struct Fixture {
    let db: DatabaseQueue
    let recipes: RecipeRepository
    let health: HealthScoringService
  }

  private func makeFixture() throws -> Fixture {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      for (id, name) in [(1, "rice"), (2, "spinach"), (3, "tomatoes"), (4, "onion")] {
        try db.execute(
          sql: """
            INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
            VALUES (?, ?, 100, 5, 15, 2)
            """,
          arguments: [id, name]
        )
      }
    }
    let nutrition = NutritionService(db: db)
    let health = HealthScoringService(nutritionService: nutrition, db: db)
    let recipes = RecipeRepository(
      db: db, nutritionService: nutrition, healthScoringService: health,
      personalizationService: PersonalizationService(db: db)
    )
    return Fixture(db: db, recipes: recipes, health: health)
  }

  private func addRecipe(
    _ id: Int64, minutes: Int, required: [Int64], optional: [Int64] = [],
    tags: Int = 0, to fixture: Fixture
  ) throws {
    _ = try fixture.recipes.saveRecipe(
      Recipe(
        id: id, title: "Recipe \(id)", timeMinutes: minutes, servings: 1,
        instructions: "Use the ingredients.", tags: tags, source: .user
      ),
      ingredients: required.map { (ingredientId: $0, grams: 100, required: true) }
        + optional.map { (ingredientId: $0, grams: 100, required: false) }
    )
  }

  private func addLot(
    ingredient: Int64, expiry: Date?, remaining: Double = 100, to fixture: Fixture
  ) throws {
    try fixture.db.write { db in
      try db.execute(
        sql: """
          INSERT INTO inventory_lots (ingredient_id, quantity_grams, remaining_grams, expires_at)
          VALUES (?, 100, ?, ?)
          """,
        arguments: [ingredient, remaining, expiry]
      )
    }
  }
}

private struct NoGeneration: RecipeGenerating {
  var enhancementAvailability: AIEnhancementAvailability { .unavailable("Not used by recipe search") }

  func generate(
    from ingredientNames: [String], dietaryRestrictions: [String]
  ) async throws -> GeneratedRecipeResult? {
    XCTFail("Recipe search must not require a model call")
    return nil
  }
}
