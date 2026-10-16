import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// End-to-end proof over the SHIPPED bundle (the recipes-v2.json actually carried in the
/// app bundle, not a fixture): every recipe hydrates with its lines and steps, an upgrade
/// from a v18 database keeps cooking history while the catalog hydrates around it, and
/// RecommendationEngine.findRecipes over fixture pantries returns feasible recipes with
/// honest fit lines on the migrated database.
///
/// Tests run hosted in the app (TEST_HOST), so Bundle.main is the app bundle and the
/// shipped resource is the real thing the app will read at launch.
final class RecipeCatalogIntegrationTests: XCTestCase {
  // MARK: - Helpers

  private func makeDatabase(upTo target: String? = nil) throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: target)
    return db
  }

  /// The bundle the app actually ships. Fails loudly rather than skipping: a missing
  /// resource is exactly what these tests exist to catch.
  private func shippedBundleData() throws -> Data {
    guard let url = RecipeBundleV2Loader.bundleV2URL(in: .main) else {
      XCTFail("shipped bundle missing from the app bundle: Resources/RecipeCatalog/recipes-v2.json")
      throw XCTSkip("bundle resource not shipped — the app would fall back to legacy data.json")
    }
    return try Data(contentsOf: url)
  }

  private func count(_ db: DatabaseQueue, _ sql: String, _ arguments: StatementArguments = StatementArguments())
    throws -> Int
  {
    try db.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
  }

  /// Seeds a v18 database the way the previous app version wrote it: legacy ingredients,
  /// a bundled recipe (id 2), and cooking history that points at it.
  private func seedLegacyRecipesAndHistory(in db: DatabaseQueue) throws {
    try db.write { db in
      for (id, name, kcal) in [(Int64(1), "egg", 155.0), (Int64(7), "tomato", 18.0)] {
        try db.execute(
          sql: """
            INSERT INTO ingredients
                (id, name, calories, protein, carbs, fat, fiber, sugar, sodium)
            VALUES (?, ?, ?, 0, 0, 0, 0, 0, 0)
            """,
          arguments: [id, name, kcal]
        )
      }
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
          VALUES (2, 'Simple Cheese Omelette', 10, 1, 'Beat the eggs.', 0, 'bundled')
          """
      )
      try db.execute(
        sql: "INSERT INTO recipe_ingredients VALUES (2, 1, 1, 150.0, '150g egg')")
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, rating) VALUES (2, 5)")
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, rating) VALUES (2, 4)")
    }
  }

  private func makeRepository(_ db: DatabaseQueue) throws -> RecipeRepository {
    RecipeRepository(
      db: db,
      nutritionService: NutritionService(db: db),
      healthScoringService: HealthScoringService(
        nutritionService: try NutritionService(db: db), db: db),
      personalizationService: PersonalizationService(db: db)
    )
  }

  @MainActor
  private func makeEngine(_ db: DatabaseQueue) throws -> RecommendationEngine {
    RecommendationEngine(
      recipeRepository: try makeRepository(db),
      healthScoringService: HealthScoringService(
        nutritionService: NutritionService(db: db), db: db),
      recipeGenerator: NoopRecipeGenerator()
    )
  }

  // MARK: - Shipped bundle hydrates completely

  func testShippedBundleHydratesEveryRecipeWithLinesStepsAndNutrition() async throws {
    let data = try shippedBundleData()
    let bundle = try RecipeBundleV2.decode(from: data)
    let db = try makeDatabase()

    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: "integration")

    // Every bundle recipe and ingredient landed, keyed by stable catalog id.
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog"), bundle.recipes.count)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_catalog_ingredients"), bundle.ingredients.count)

    // No empty hydration: every recipe carries at least one line and one step, every
    // line names existing vocabulary, and every revision has its nutrition snapshot.
    let uncovered =
      try await db.read { db -> Int in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM recipes_catalog r
            WHERE NOT EXISTS (
                    SELECT 1 FROM recipes_catalog_lines l
                    WHERE l.catalog_id = r.catalog_id)
                  OR NOT EXISTS (
                    SELECT 1 FROM recipes_catalog_steps s
                    WHERE s.catalog_id = r.catalog_id)
                  OR NOT EXISTS (
                    SELECT 1 FROM recipes_catalog_nutrition n
                    WHERE n.catalog_id = r.catalog_id AND n.revision = r.revision)
                  OR EXISTS (
                    SELECT 1 FROM recipes_catalog_lines l
                    LEFT JOIN recipes_catalog_ingredients i ON i.key = l.ingredient_key
                    WHERE l.catalog_id = r.catalog_id AND i.key IS NULL)
            """) ?? 0
      }
    XCTAssertEqual(uncovered, 0, "every recipe hydrates with lines, steps, nutrition, and resolvable ingredient keys")

    // Catalog ids stay in the corpus band: rcp-000167 upward, no migrated-legacy claim
    // in this bundle (rcp-000001..rcp-000166 stay reserved).
    let lowest = try await db.read {
      try String.fetchOne($0, sql: "SELECT MIN(catalog_id) FROM recipes_catalog")
    }
    XCTAssertEqual(lowest, "rcp-000167")

    // Rights never ship without a status from the audited set.
    XCTAssertEqual(
      try count(
        db,
        "SELECT COUNT(*) FROM recipes_catalog WHERE rights_status NOT IN ('original', 'quarantined')"),
      0)

    // Re-applying the same shipped bundle changes nothing (launch idempotence).
    let linesBefore = try count(db, "SELECT COUNT(*) FROM recipes_catalog_lines")
    let stepsBefore = try count(db, "SELECT COUNT(*) FROM recipes_catalog_steps")
    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: "integration-2")
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog"), bundle.recipes.count)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_catalog_lines"), linesBefore,
      "re-apply must not duplicate lines")
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_catalog_steps"), stepsBefore,
      "re-apply must not duplicate steps")
  }

  // MARK: - v18 upgrade with cooking history

  func testUpgradeFromV18KeepsCookingHistoryAndHydratesShippedBundleAroundIt() async throws {
    let data = try shippedBundleData()
    let bundle = try RecipeBundleV2.decode(from: data)
    let db = try makeDatabase(upTo: "v18_cooking_history_swaps")
    try seedLegacyRecipesAndHistory(in: db)
    try DatabaseMigrations.migrate(db)

    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: "integration")

    // History survives untouched: both rows, still resolving to the legacy recipe row.
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = 2"), 2)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes WHERE id = 2 AND source = 'bundled'"), 1)

    // The bundle hydrates fully around the legacy data without claiming any of it:
    // this bundle has no migrated successors (corpus starts at rcp-000167), so no
    // catalog row may link a legacy id.
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog"), bundle.recipes.count)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_catalog WHERE legacy_recipe_id IS NOT NULL"), 0,
      "no false legacy links: a mislink would misattribute cooking history")

    // The legacy recipe and vocabulary stay readable through their existing ids
    // (spec: legacy rows stay readable through their existing ids).
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes"), 1)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM ingredients"), 2)
  }

  // MARK: - Recommendation over the migrated database

  @MainActor
  func testFindRecipesOverMigratedDatabaseReturnsFeasibleRecipesWithHonestFitLines() async throws {
    let data = try shippedBundleData()
    let db = try makeDatabase(upTo: "v18_cooking_history_swaps")
    try seedLegacyRecipesAndHistory(in: db)
    try DatabaseMigrations.migrate(db)
    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: "integration")

    let engine = try makeEngine(db)

    // A pantry holding the omelette's only required ingredient: an exact match with an
    // honest fit line (matched == required, nothing missing).
    await engine.findRecipes(for: [1])
    let exact = engine.sections.exact
    XCTAssertTrue(exact.contains { $0.recipe.id == 2 }, "egg pantry matches the omelette")
    if let omelette = exact.first(where: { $0.recipe.id == 2 }) {
      XCTAssertEqual(omelette.matchTier, .exact)
      XCTAssertEqual(omelette.matchedRequired, omelette.totalRequired)
      XCTAssertEqual(omelette.missingRequiredCount, 0)
      XCTAssertTrue(omelette.missingIngredientIds.isEmpty)
    }

    // A pantry holding only the optional tomato: no exact match, and the near match
    // names exactly what it is missing — the fit line does not pretend feasibility.
    await engine.findRecipes(for: [7])
    XCTAssertTrue(engine.sections.exact.isEmpty, "tomato alone completes nothing")
    let near = engine.sections.nearMatch
    XCTAssertTrue(near.contains { $0.recipe.id == 2 }, "the omelette is one egg away")
    if let omelette = near.first(where: { $0.recipe.id == 2 }) {
      XCTAssertEqual(omelette.matchTier, .nearMatch)
      XCTAssertEqual(omelette.missingRequiredCount, 1)
      XCTAssertEqual(omelette.missingIngredientIds, [1])
      XCTAssertEqual(omelette.matchedRequired, 0)
      XCTAssertEqual(omelette.totalRequired, 1)
    }

    // The engine's published shape stays consistent for the UI. The merged
    // 762-recipe catalog pool can outrank the omelette for a tomato-only
    // pantry, so pin the shape (quick suggestion = top near match when nothing
    // completes), not the bundle-specific winner; the omelette's own presence
    // and fit lines are asserted above.
    XCTAssertEqual(
      engine.quickSuggestion?.recipe.id, engine.sections.nearMatch.first?.recipe.id)
    XCTAssertEqual(engine.searchedIngredientCount, 1)
    XCTAssertNil(engine.error)
  }

  @MainActor
  func testEmptyPantryFallsBackToStapleAssumptionAndStillRanksHonest() async throws {
    let data = try shippedBundleData()
    let db = try makeDatabase(upTo: "v18_cooking_history_swaps")
    try seedLegacyRecipesAndHistory(in: db)
    try DatabaseMigrations.migrate(db)
    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: "integration")

    let engine = try makeEngine(db)

    // Empty pantries are substituted with the staple fallback set, which includes
    // ingredient 1; the omelette is then presented as an exact match, and its fit line
    // still reports matched == required (never inflated). searchedIngredientCount stays
    // the raw scanned count (zero) — the fallback shapes the query, not the report.
    await engine.findRecipes(for: [])
    XCTAssertTrue(engine.sections.exact.contains { $0.recipe.id == 2 })
    XCTAssertEqual(engine.searchedIngredientCount, 0)
    if let omelette = engine.sections.exact.first(where: { $0.recipe.id == 2 }) {
      XCTAssertEqual(omelette.matchedRequired, omelette.totalRequired)
      XCTAssertEqual(omelette.missingRequiredCount, 0)
    }
  }

  @MainActor
  func testCatalogReadPathServesShippedBundleContent() async throws {
    let data = try shippedBundleData()
    let bundle = try RecipeBundleV2.decode(from: data)
    let db = try makeDatabase(upTo: "v18_cooking_history_swaps")
    try seedLegacyRecipesAndHistory(in: db)
    try DatabaseMigrations.migrate(db)
    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: "integration")

    // The repository bridge the UI reads from serves the shipped bundle's structured
    // content, not just rows.
    let repo = try makeRepository(db)
    let first = bundle.recipes[0]
    let detail = try repo.unscreenedCatalog.recipe(catalogId: first.catalogId)
    XCTAssertEqual(detail?.catalogId, first.catalogId)
    XCTAssertEqual(detail?.title, first.title)
    XCTAssertEqual(detail?.lines.count, first.lines.count)
    XCTAssertEqual(detail?.steps.count, first.steps.count)
    XCTAssertNotNil(try repo.catalogNutrition(catalogId: first.catalogId, revision: first.revision))
  }
}

/// Does nothing: these tests exercise recommendation over persisted data, not generation.
private struct NoopRecipeGenerator: RecipeGenerating {
  var enhancementAvailability: AIEnhancementAvailability { .unavailable("not under test") }

  func generate(from ingredientNames: [String], dietaryRestrictions: [String])
    async throws -> GeneratedRecipeResult?
  {
    nil
  }
}
