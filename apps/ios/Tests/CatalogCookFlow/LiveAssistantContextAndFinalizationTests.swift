import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The surfaces a recommended recipe reaches — LeChef's context and cook session, and the
/// meal finalization log — resolve a catalog result through its packet instead of the
/// legacy integer column. Over a hydrated bundle-v2 fixture: the context carries the
/// packet's structured steps (stated timer, cited thermometer check) and the exact
/// (catalogId, revision); the finalization log for a recipe with no persisted id still
/// records a history row linked to the (catalogId, revision) that was cooked, so a later
/// revision bump cannot rewrite what the meal says it was. Harness mirrors
/// CatalogCookFlowTests: real loader, real migrations, real repositories.
@MainActor
final class LiveAssistantContextAndFinalizationTests: XCTestCase {
  // MARK: - Fixtures

  private static let catalogId = "rcp-900001"

  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return db
  }

  private func hydrate(_ db: DatabaseQueue, revision: Int) throws {
    let bundle = try RecipeBundleV2.decode(from: Data(Self.bundleJSON(revision: revision).utf8))
    try db.write { db in
      try RecipeBundleV2Loader.apply(bundle: bundle, marker: "live-assistant-context-tests", db: db)
    }
  }

  private func makeRepository(_ db: DatabaseQueue) throws -> RecipeRepository {
    let nutritionService = NutritionService(db: db)
    let healthScoring = HealthScoringService(nutritionService: nutritionService, db: db)
    let personalization = PersonalizationService(db: db)
    return RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoring,
      personalizationService: personalization)
  }

  /// The recipe object the recommend pool builds for a catalog entry: no persisted id.
  private func catalogRecipe() -> Recipe {
    Recipe(
      id: nil,
      title: "Catalog Scramble",
      timeMinutes: 12,
      servings: 2,
      instructions: "Beat the eggs.",  // legacy fallback text; catalog steps win
      tags: 0,
      source: .bundled,
      createdAt: nil)
  }

  private func scored(_ recipe: Recipe, catalogID: String?, revision: Int) -> ScoredRecipe {
    var scored = ScoredRecipe(
      recipe: recipe,
      matchedRequired: 1,
      totalRequired: 1,
      matchedOptional: 0,
      missingRequiredCount: 0,
      missingIngredientIds: [],
      macros: RecipeMacros(
        caloriesPerServing: 58, proteinPerServing: 24, carbsPerServing: 4,
        fatPerServing: 30, fiberPerServing: 1, sugarPerServing: 1, sodiumPerServing: 520),
      healthScore: HealthScore(rating: 4, label: "Good", reasoning: "test"),
      personalScore: 0.5,
      rankingScore: 1.0,
      rankingReasons: [],
      matchTier: .exact)
    if let catalogID {
      scored.catalog = CatalogRecipeMatch(
        ref: .catalog(id: catalogID, revision: revision), successorToLegacyRecipeID: nil)
    }
    return scored
  }

  private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
  }

  // MARK: - Factory: catalog context

  func testFactoryBuildsContextFromTheCatalogPacket() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 3)
    let repository = try makeRepository(db)

    let scored = scored(
      catalogRecipe(), catalogID: Self.catalogId, revision: 3)
    let context = LiveAssistantRecipeContextFactory(recipeRepository: repository)
      .context(for: scored)

    XCTAssertEqual(context.catalogID, Self.catalogId)
    XCTAssertEqual(context.catalogRevision, 3)
    XCTAssertEqual(context.recipeID, nil)  // catalog entries carry no legacy row
    XCTAssertEqual(context.catalogSteps?.count, 2)
    XCTAssertEqual(context.catalogSteps?[0].timerSeconds, 90)
    XCTAssertEqual(context.catalogSteps?[1].thermometer?.endpointC, 74)
    // The cook session runs the packet's steps, so the context text is the packet's
    // own wording — not the legacy fallback instruction.
    XCTAssertEqual(
      context.instructions, "Beat the eggs in a bowl.\nCook gently until the centre just sets.")
  }

  func testFactoryKeepsLegacyInstructionsForAnUnknownCatalogRef() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 3)
    let repository = try makeRepository(db)

    let scored = scored(catalogRecipe(), catalogID: "rcp-does-not-exist", revision: 1)
    let context = LiveAssistantRecipeContextFactory(recipeRepository: repository)
      .context(for: scored)

    XCTAssertNil(context.catalogID)
    XCTAssertNil(context.catalogRevision)
    XCTAssertNil(context.steps)
    XCTAssertEqual(context.instructions, "Beat the eggs.")
  }

  func testFactoryKeepsLegacyPathForAResultWithAnIntegerID() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 3)
    let repository = try makeRepository(db)

    var recipe = catalogRecipe()
    recipe.id = 42
    let scored = scored(recipe, catalogID: nil, revision: 3)
    let context = LiveAssistantRecipeContextFactory(recipeRepository: repository)
      .context(for: scored)

    XCTAssertEqual(context.recipeID, 42)
    XCTAssertNil(context.catalogID)
    XCTAssertNil(context.steps)
    XCTAssertEqual(context.instructions, "Beat the eggs.")
  }

  // MARK: - Finalization: catalog log

  func testFinalizationLogsACatalogRecipeWithNoLegacyIDAgainstTheCookedRevision() async throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 3)
    let nutritionService = NutritionService(db: db)
    let healthScoring = HealthScoringService(nutritionService: nutritionService, db: db)
    let personalization = PersonalizationService(db: db)
    let repository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoring,
      personalizationService: personalization)

    let vm = MealFinalizationViewModel(
      recipe: catalogRecipe(),
      defaultServings: 2,
      catalogId: Self.catalogId,
      catalogRevision: 3,
      recipeRepository: repository,
      personalizationService: personalization,
      inventoryRepository: InventoryRepository(db: db))

    await vm.save()

    XCTAssertNil(vm.errorMessage)
    XCTAssertTrue(vm.didSave)

    // The catalog entry has no integer id, so the log resolves a legacy row to anchor
    // the foreign key, and links the exact (catalogId, revision) that was cooked.
    let historyRows = try count(db, "SELECT COUNT(*) FROM cooking_history")
    XCTAssertEqual(historyRows, 1)
    let refRows = try count(
      db,
      """
      SELECT COUNT(*) FROM recipes_cooking_catalog_refs
      WHERE catalog_id = '\(Self.catalogId)' AND revision = 3
      """)
    XCTAssertEqual(refRows, 1)
  }

  func testFinalizationLogsALegacyRecipeWithoutACatalogRef() async throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 3)
    let nutritionService = NutritionService(db: db)
    let healthScoring = HealthScoringService(nutritionService: nutritionService, db: db)
    let personalization = PersonalizationService(db: db)
    let repository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoring,
      personalizationService: personalization)

    var recipe = catalogRecipe()
    recipe.id = 77
    let vm = MealFinalizationViewModel(
      recipe: recipe,
      defaultServings: 1,
      recipeRepository: repository,
      personalizationService: personalization,
      inventoryRepository: InventoryRepository(db: db))

    await vm.save()

    XCTAssertNil(vm.errorMessage)
    XCTAssertTrue(vm.didSave)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cooking_history"), 1)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_cooking_catalog_refs"), 0)
  }
}

extension LiveAssistantContextAndFinalizationTests {
  /// Two-ingredient, two-step catalog recipe: step 1 carries a 90 s timer, step 2 a
  /// checkable thermometer endpoint with its pinned source. The schema requires at least
  /// 2 ingredient lines and 2 steps (RecipeBundleV2 compile-time validation), so the
  /// fixture carries butter alongside the egg. Same fixture shape as CatalogCookFlowTests.
  fileprivate static func bundleJSON(revision: Int) -> String {
    """
    {
      "schema": "https://fridgeluck.app/schemas/recipe-bundle-v2.schema.json",
      "bundle_version": 2,
      "generated_at": "2026-10-16T00:00:00Z",
      "cuisines": ["american", "asian", "indian", "italian", "mediterranean", "mexican"],
      "ingredients": [
        {
          "key": "egg",
          "fdc_id": null,
          "legacy_id": null,
          "display_name": "Egg",
          "category": "dairy_egg",
          "per_100g": null,
          "aliases": ["eggs"]
        },
        {
          "key": "butter",
          "fdc_id": null,
          "legacy_id": null,
          "display_name": "Butter",
          "category": "dairy_egg",
          "per_100g": null,
          "aliases": []
        }
      ],
      "recipes": [
        {
          "catalog_id": "rcp-900001",
          "revision": \(revision),
          "title": "Catalog Scramble",
          "cuisine": "american",
          "meal_slots": ["breakfast"],
          "collections": ["quick"],
          "minutes": 12,
          "servings": 2,
          "equipment": [],
          "ingredients": [
            {
              "key": "egg",
              "quantity": {"kind": "count", "amount": 2, "unit": "large", "grams": 100},
              "required": true,
              "assumed_staple": false,
              "note": null
            },
            {
              "key": "butter",
              "quantity": {"kind": "household", "amount": 1, "unit": "tbsp", "grams": 14},
              "required": true,
              "assumed_staple": false,
              "note": null
            }
          ],
          "steps": [
            {
              "text": "Beat the eggs in a bowl.",
              "uses": [0],
              "timer_seconds": 90,
              "thermometer": null
            },
            {
              "text": "Cook gently until the centre just sets.",
              "uses": [0],
              "timer_seconds": null,
              "thermometer": {"endpoint_c": 74, "food": "scramble centre", "source": "usda-fsis: egg dishes 160 F"}
            }
          ],
          "claims": {"vegetarian": true, "vegan": false, "gluten_free": true, "dairy_free": false},
          "nutrition_per_serving": {
            "kcal": 58,
            "protein_g": 24,
            "carbs_g": 4,
            "fat_g": 30,
            "fiber_g": 1,
            "sodium_mg": 520,
            "coverage": "estimated",
            "basis": "test fixture: household-to-gram estimates"
          },
          "rights": {"status": "original", "evidence": "test fixture: original wording"},
          "keywords": []
        }
      ]
    }
    """
  }
}
