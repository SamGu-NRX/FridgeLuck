import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The bundle v2 catalog loader: fresh install, upgrade from a legacy v18 database with
/// cooking history, idempotence across launches, revision bumps, user-edit survival, and
/// loud failure with the recipe id on a malformed bundle.
///
/// The fixture is the spec's example bundle (docs/spec/recipes/contracts/examples/
/// bundle-v2.sample.json) embedded verbatim, plus a small legacy data.json-shaped payload
/// for the fallback and upgrade paths.
final class RecipeLoaderTests: XCTestCase {
  // MARK: - Fixtures

  /// A minimal legacy data.json payload: recipe id 2 is the successor the sample bundle
  /// rewrites at revision 2 (same title, "Simple Cheese Omelette").
  private let legacyJSON = """
    {
      "tags": ["quick", "vegetarian", "vegan", "asian", "breakfast", "budget", "comfort",
               "mediterranean", "mexican", "high_protein", "low_carb", "one_pot"],
      "ingredients": {
        "1": ["egg", 155, 13.0, 1.1, 11.0, 0.0, 1.1, 0.124, "1 large (50g)", "Refrigerate"],
        "2": ["rice", 130, 2.7, 28.2, 0.3, 0.4, 0.1, 0.001, "1 cup (195g)", "Keep dry"],
        "7": ["tomato", 18, 0.9, 3.9, 0.2, 1.2, 2.6, 0.005, "1 medium (123g)", "Refrigerate"]
      },
      "recipes": [
        [2, "Simple Cheese Omelette", 10, 1, [[1, 150]], [[7, 50]],
         "Beat the eggs, then cook gently in a pan.", 0],
        [101, "Moroccan chicken stew", 45, 4, [[7, 400]], [], "Braise everything.", 0]
      ]
    }
    """

  private func sampleData(_ mutations: ((String) -> String)... = []) throws -> Data {
    var json = SampleBundleFixture.json
    for mutate in mutations {
      json = mutate(json)
    }
    return Data(json.utf8)
  }

  private func makeDatabase(upTo target: String? = nil) throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: target)
    return db
  }

  private func apply(_ data: Data, to db: DatabaseQueue, marker: String = "test") async throws {
    try await RecipeBundleV2Loader.apply(data: data, into: db, marker: marker)
  }

  private func applyLegacy(_ data: Data, to db: DatabaseQueue, marker: String = "legacy-test")
    async throws
  {
    try await RecipeBundleV2Loader.applyLegacy(data: data, into: db, marker: marker)
  }

  private func count(_ db: DatabaseQueue, _ sql: String, _ arguments: [DatabaseValueConvertible] = [])
    throws -> Int
  {
    try db.read { try Int.fetchOne($0, sql: sql, arguments: arguments) ?? 0 }
  }

  private func string(_ db: DatabaseQueue, _ sql: String, _ arguments: [DatabaseValueConvertible] = [])
    throws -> String?
  {
    try db.read { try String.fetchOne($0, sql: sql, arguments: arguments) }
  }

  /// Seeds a v18 database the way the previous app version wrote it: legacy ingredients, a
  /// bundled recipe (id 2), and cooking history that points at it.
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
        sql: "INSERT INTO recipe_ingredients VALUES (2, 1, 1, 150.0, '150g egg')"
      )
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, rating) VALUES (2, 5)"
      )
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, rating) VALUES (2, 4)"
      )
    }
  }

  // MARK: - Fresh install

  func testFreshInstallHydratesStructuredCatalogFromSampleBundle() async throws {
    let db = try makeDatabase()

    try await apply(try sampleData(), to: db)

    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog"), 6)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog_ingredients"), 20)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_catalog_steps"), 4 + 4 + 3 + 4 + 3 + 5)

    let omelette = try readCatalogRecipe(db, "rcp-000002")
    XCTAssertEqual(omelette?.revision, 2)
    XCTAssertEqual(omelette?.lines.count, 3)
    XCTAssertEqual(omelette?.steps.count, 4)
    // Quantity evidence: count with grams, household without grams (honest unknown mass),
    // and unknown "to taste".
    XCTAssertEqual(omelette?.lines[0].quantity, .count(amount: 3, unit: "large", grams: 150))
    XCTAssertEqual(
      omelette?.lines[1].quantity, .household(amount: 1, unit: "tbsp", grams: nil))
    XCTAssertEqual(omelette?.lines[2].quantity, .unknown(note: "to taste"))
    // Thermometer check pinned to FSIS.
    XCTAssertEqual(omelette?.steps[3].thermometer?.endpointC, 71)
    XCTAssertEqual(omelette?.steps[3].thermometer?.source, "usda-fsis: egg dishes 160 F")
    // The beef stir-fry carries the other pinned check.
    let stirFry = try readCatalogRecipe(db, "rcp-000301")
    XCTAssertEqual(stirFry?.steps[3].thermometer?.source, "usda-fsis: ground beef 160 F")
    // Null claims stay null — fail-closed, not inferred.
    XCTAssertNil(stirFry?.claims.glutenFree)
  }

  func testFreshInstallKeepsLegacyRecipesUntouched() async throws {
    let db = try makeDatabase()
    try seedLegacyRowsThroughCoreTables(db)

    try await apply(try sampleData(), to: db)

    // The legacy `recipes` rows and history are never rewritten by a catalog apply.
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes"), 1)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cooking_history"), 1)
  }

  // MARK: - Upgrade from v18

  func testUpgradeFromV18LinksBundleSuccessorAndKeepsHistory() async throws {
    let db = try makeDatabase(upTo: "v18_cooking_history_swaps")
    try seedLegacyRecipesAndHistory(in: db)
    try DatabaseMigrations.migrate(db)

    try await applyLegacy(Data(legacyJSON.utf8), to: db)
    try await apply(try sampleData(), to: db)

    // Legacy fallback rows are keyed rcp-NNNNNN by the legacy integer id, revision 1.
    let legacyRowRevision = try count(
      db, "SELECT revision FROM recipes_catalog WHERE catalog_id = 'rcp-000002'")
    // After the v2 apply the successor replaced it at revision 2.
    XCTAssertEqual(
      try string(db, "SELECT revision FROM recipes_catalog WHERE catalog_id = 'rcp-000002'"),
      "2")
    XCTAssertEqual(legacyRowRevision, 1, "legacy apply stored revision 1 before the bump")

    // The successor keeps its legacy id: cooking history keeps resolving.
    XCTAssertEqual(
      try readCatalogRecipe(db, "rcp-000002")?.legacyRecipeId, Int64(2))
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = 2"), 2)

    // Unrelated new bundle rows carry no legacy link — rcp-000101 is a new original, not
    // legacy recipe 101 ("Moroccan chicken stew").
    XCTAssertNil(try readCatalogRecipe(db, "rcp-000101")?.legacyRecipeId)

    // The repository bridge resolves the legacy integer id to structured content.
    let repo = try makeRepository(db)
    XCTAssertEqual(try repo.catalogRecipeID(forLegacyRecipeID: 2), "rcp-000002")
    let detail = try repo.catalogRecipe(catalogId: "rcp-000002")
    XCTAssertEqual(detail?.steps.count, 4)
    XCTAssertEqual(detail?.lines.first?.key, "egg")
    XCTAssertEqual(
      try repo.catalogNutrition(catalogId: "rcp-000002", revision: 2)?.coverage,
      .estimated)
  }

  // MARK: - Idempotence

  func testReApplyIsIdempotent() async throws {
    let db = try makeDatabase()
    try await apply(try sampleData(), to: db)
    let recipesBefore = try count(db, "SELECT COUNT(*) FROM recipes_catalog")
    let linesBefore = try count(db, "SELECT COUNT(*) FROM recipes_catalog_lines")
    let stepsBefore = try count(db, "SELECT COUNT(*) FROM recipes_catalog_steps")
    let nutritionBefore = try count(db, "SELECT COUNT(*) FROM recipes_catalog_nutrition")

    try await apply(try sampleData(), to: db, marker: "test-2")

    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog"), recipesBefore)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog_lines"), linesBefore)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog_steps"), stepsBefore)
    XCTAssertEqual(
      try count(db, "SELECT COUNT(*) FROM recipes_catalog_nutrition"), nutritionBefore)
    XCTAssertEqual(
      try string(db, "SELECT value FROM bundled_recipe_state WHERE key = 'recipes_catalog_v2_marker'"),
      "test-2", "marker refreshes even when nothing else changes")
  }

  func testLegacyReapplyAfterBundleSupersedenceIsANoOp() async throws {
    let db = try makeDatabase()
    try await applyLegacy(Data(legacyJSON.utf8), to: db)
    try await apply(try sampleData(), to: db)

    try await applyLegacy(Data(legacyJSON.utf8), to: db, marker: "legacy-2")

    // The legacy fallback must not drag the upgraded successor back to revision 1.
    XCTAssertEqual(
      try string(db, "SELECT revision FROM recipes_catalog WHERE catalog_id = 'rcp-000002'"),
      "2")
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog_steps"), 4 + 4 + 3 + 4 + 3 + 5)
  }

  // MARK: - Revision bump

  func testRevisionBumpReplacesContentAndKeepsHistoricalNutrition() async throws {
    let db = try makeDatabase()
    try await apply(try sampleData(), to: db)
    let originalNutrition = try string(
      db,
      "SELECT nutrition FROM recipes_catalog_nutrition WHERE catalog_id = 'rcp-000002' AND revision = 2")

    let bumped = try sampleData { json in
      json
        .replacingOccurrences(of: "\"revision\": 2", with: "\"revision\": 3")
        .replacingOccurrences(of: "\"timer_seconds\": 60", with: "\"timer_seconds\": 90")
    }
    try await apply(bumped, to: db)

    let updated = try readCatalogRecipe(db, "rcp-000002")
    XCTAssertEqual(updated?.revision, 3)
    // The mutated step timer proves content was actually replaced.
    XCTAssertEqual(updated?.steps[1].timerSeconds, 90)

    // Historical nutrition: the revision-2 snapshot survives byte-for-byte, and the new
    // revision got its own row.
    XCTAssertEqual(
      try string(
        db,
        "SELECT nutrition FROM recipes_catalog_nutrition WHERE catalog_id = 'rcp-000002' AND revision = 2"),
      originalNutrition)
    XCTAssertEqual(
      try count(
        db,
        "SELECT COUNT(*) FROM recipes_catalog_nutrition WHERE catalog_id = 'rcp-000002' AND revision = 3"),
      1)
  }

  // MARK: - User edits

  func testUserEditedRecipeSurvivesHigherRevision() async throws {
    let db = try makeDatabase()
    try await applyLegacy(Data(legacyJSON.utf8), to: db)
    try db.write { db in
      try db.execute(
        sql: "UPDATE recipes_catalog SET is_user_edited = 1 WHERE catalog_id = 'rcp-000002'")
      try db.execute(
        sql: """
          UPDATE recipes_catalog_lines SET quantity_grams = 999
          WHERE catalog_id = 'rcp-000002' AND position = 0
          """)
    }

    let bumped = try sampleData { json in
      json.replacingOccurrences(of: "\"revision\": 2", with: "\"revision\": 9")
    }
    try await apply(bumped, to: db)

    let row = try readCatalogRecipe(db, "rcp-000002")
    XCTAssertEqual(row?.revision, 1)
    XCTAssertEqual(row?.lines.first?.quantity, .grams(999), "the user's edit survives")
    // Unedited rows still upgrade.
    XCTAssertEqual(
      try string(db, "SELECT revision FROM recipes_catalog WHERE catalog_id = 'rcp-000101'"), "1")
  }

  // MARK: - Malformed bundles

  func testMalformedRecipeFailsLoudlyWithRecipeId() async throws {
    let db = try makeDatabase()

    // A step referencing an ingredient index past the end of the lines array.
    let badUses = try sampleData { json in
      json.replacingOccurrences(of: "\"uses\": [0, 2]", with: "\"uses\": [0, 99]")
    }
    do {
      try await apply(badUses, to: db)
      XCTFail("expected a loud failure")
    } catch let error as RecipeBundleV2Error {
      XCTAssertTrue(
        error.description.contains("rcp-000002"),
        "error must name the recipe: \(error)")
    }

    // A recipe missing a required field fails decode with its catalog id.
    let badServings = try sampleData { json in
      json.replacingOccurrences(of: "\"servings\": 1", with: "\"servings_removed\": 1")
    }
    do {
      try await apply(badServings, to: db)
      XCTFail("expected a loud failure")
    } catch let error as RecipeBundleV2Error {
      XCTAssertTrue(
        error.description.contains("rcp-000002"),
        "error must name the recipe: \(error)")
    }

    // Nothing was written: a failed apply leaves the catalog empty.
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_catalog"), 0)
  }

  func testUnpinnedThermometerSourceFailsClosed() async throws {
    let db = try makeDatabase()
    let bad = try sampleData { json in
      json.replacingOccurrences(
        of: "usda-fsis: ground beef 160 F", with: "some blog: ground beef 160 F")
    }
    do {
      try await apply(bad, to: db)
      XCTFail("expected a loud failure")
    } catch let error as RecipeBundleV2Error {
      XCTAssertTrue(error.description.contains("rcp-000301"), "got: \(error)")
    }
  }

  func testWrongBundleVersionFailsClosed() async throws {
    let db = try makeDatabase()
    let wrong = try sampleData { json in
      json.replacingOccurrences(of: "\"bundle_version\": 2", with: "\"bundle_version\": 3")
    }
    do {
      try await apply(wrong, to: db)
      XCTFail("expected a loud failure")
    } catch let error as RecipeBundleV2Error {
      guard case .unsupportedBundleVersion(let found) = error else {
        return XCTFail("wrong error: \(error)")
      }
      XCTAssertEqual(found, 3)
    }
  }

  // MARK: - Read paths

  func testCatalogReadPathsExposeStructuredLinesStepsAndNutrition() async throws {
    let db = try makeDatabase()
    try await apply(try sampleData(), to: db)
    let repo = try makeRepository(db)

    let curry = try repo.catalogRecipe(catalogId: "rcp-000101")
    XCTAssertEqual(curry?.title, "Coconut Chickpea Curry")
    XCTAssertEqual(curry?.cuisine, .indian)
    XCTAssertEqual(curry?.mealSlots, [.dinner, .lunch])
    XCTAssertEqual(curry?.collections, [.budget, .onePot])
    XCTAssertEqual(curry?.equipment, ["large pan"])
    XCTAssertEqual(curry?.lines.count, 9)
    XCTAssertEqual(curry?.lines[0].key, "chickpeas")
    XCTAssertEqual(curry?.lines[0].quantity, .grams(480))
    XCTAssertEqual(curry?.lines[8].required, false, "garnish lines are optional")
    XCTAssertEqual(curry?.lines[8].assumedStaple, false)
    XCTAssertEqual(curry?.lines[5].assumedStaple, true, "cumin is a pantry staple")
    XCTAssertEqual(curry?.steps[2].timerSeconds, 600)
    XCTAssertEqual(curry?.steps[3].uses, [3, 7, 8])
    XCTAssertEqual(curry?.nutrition?.coverage, .partial)
    XCTAssertEqual(curry?.nutrition?.sodiumMg, 480)
    XCTAssertEqual(curry?.rights.status, .original)
    XCTAssertEqual(curry?.ref, RecipeRef.catalog(id: "rcp-000101", revision: 1))

    // Nutrition snapshot read by revision.
    let nutrition = try repo.catalogNutrition(catalogId: "rcp-000301", revision: 1)
    XCTAssertEqual(nutrition?.coverage, .computed)
    XCTAssertEqual(nutrition?.kcal, 475)
    XCTAssertNil(try repo.catalogNutrition(catalogId: "rcp-000301", revision: 2))

    // Browse returns every catalog row with structured content attached.
    let all = try repo.catalogRecipes()
    XCTAssertEqual(all.count, 6)
    XCTAssertTrue(all.allSatisfy { !$0.steps.isEmpty })
  }

  // MARK: - Helpers

  private func makeRepository(_ db: DatabaseQueue) throws -> RecipeRepository {
    RecipeRepository(
      db: db,
      nutritionService: NutritionService(db: db),
      healthScoringService: HealthScoringService(nutritionService: NutritionService(db: db), db: db),
      personalizationService: PersonalizationService(db: db)
    )
  }

  private func seedLegacyRowsThroughCoreTables(_ db: DatabaseQueue) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium)
          VALUES (1, 'egg', 155, 0, 0, 0, 0, 0, 0)
          """)
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
          VALUES (2, 'Simple Cheese Omelette', 10, 1, 'Beat the eggs.', 0, 'bundled')
          """)
      try db.execute(sql: "INSERT INTO cooking_history (recipe_id, rating) VALUES (2, 5)")
    }
  }

  private func readCatalogRecipe(_ db: DatabaseQueue, _ catalogId: String) throws
    -> RecipeCatalogRecipe?
  {
    let repo = try makeRepository(db)
    return try repo.catalogRecipe(catalogId: catalogId)
  }
}

/// The spec's example bundle, embedded verbatim so the loader is tested against the exact
/// machine-checked contract fixture.
private enum SampleBundleFixture {
  static let json = #"""
  {
    "schema": "https://fridgeluck.app/schemas/recipe-bundle-v2.schema.json",
    "bundle_version": 2,
    "generated_at": "2026-10-15T09:41:00Z",
    "cuisines": ["american", "asian", "indian", "italian", "mediterranean", "mexican"],
    "ingredients": [
      {
        "key": "egg",
        "fdc_id": null,
        "legacy_id": 1,
        "display_name": "Egg",
        "category": "dairy_egg",
        "per_100g": null,
        "aliases": ["eggs", "large egg"]
      },
      {
        "key": "soy_sauce",
        "fdc_id": 174278,
        "legacy_id": 3,
        "display_name": "Soy sauce",
        "category": "condiment",
        "per_100g": { "kcal": 60, "protein_g": 10.51, "carbs_g": 5.57, "fat_g": 0.1, "fiber_g": 0.8, "sugar_g": 1.7, "sodium_mg": 5586 },
        "aliases": ["tamari", "shoyu"]
      },
      {
        "key": "olive_oil",
        "fdc_id": 171413,
        "legacy_id": 16,
        "display_name": "Olive oil",
        "category": "condiment",
        "per_100g": { "kcal": 884, "protein_g": 0, "carbs_g": 0, "fat_g": 100, "fiber_g": 0, "sugar_g": 0, "sodium_mg": 2 },
        "aliases": ["extra virgin olive oil"]
      },
      {
        "key": "sesame_oil",
        "fdc_id": 171016,
        "legacy_id": 22,
        "display_name": "Sesame oil",
        "category": "condiment",
        "per_100g": { "kcal": 884, "protein_g": 0, "carbs_g": 0, "fat_g": 100, "fiber_g": 0, "sugar_g": 0, "sodium_mg": 0 },
        "aliases": ["sesame seed oil"]
      },
      {
        "key": "ground_beef",
        "fdc_id": 168608,
        "legacy_id": 38,
        "display_name": "Ground beef",
        "category": "meat",
        "per_100g": { "kcal": 198, "protein_g": 19.42, "carbs_g": 0, "fat_g": 12.73, "fiber_g": 0, "sugar_g": 0, "sodium_mg": 68 },
        "aliases": ["beef mince", "hamburger meat"]
      },
      {
        "key": "broccoli",
        "fdc_id": 170379,
        "legacy_id": 24,
        "display_name": "Broccoli",
        "category": "vegetable",
        "per_100g": { "kcal": 34, "protein_g": 2.82, "carbs_g": 6.64, "fat_g": 0.37, "fiber_g": 2.6, "sugar_g": 1.7, "sodium_mg": 33 },
        "aliases": ["tenderstem broccoli", "broccolini"]
      },
      {
        "key": "spinach",
        "fdc_id": 168462,
        "legacy_id": 19,
        "display_name": "Spinach",
        "category": "vegetable",
        "per_100g": { "kcal": 23, "protein_g": 2.86, "carbs_g": 3.63, "fat_g": 0.39, "fiber_g": 2.2, "sugar_g": 0.42, "sodium_mg": 79 },
        "aliases": ["baby spinach"]
      },
      {
        "key": "coconut_milk",
        "fdc_id": 170172,
        "legacy_id": 49,
        "display_name": "Coconut milk",
        "category": "other",
        "per_100g": { "kcal": 230, "protein_g": 2.29, "carbs_g": 5.54, "fat_g": 23.84, "fiber_g": 2.2, "sugar_g": 3.34, "sodium_mg": 15 },
        "aliases": ["canned coconut milk"]
      },
      {
        "key": "chickpeas",
        "fdc_id": 2644282,
        "legacy_id": 35,
        "display_name": "Chickpeas",
        "category": "legume",
        "per_100g": null,
        "aliases": ["garbanzo beans", "chana"]
      },
      {
        "key": "cumin",
        "fdc_id": 170923,
        "legacy_id": 47,
        "display_name": "Ground cumin",
        "category": "spice",
        "per_100g": { "kcal": 375, "protein_g": 17.81, "carbs_g": 44.24, "fat_g": 22.27, "fiber_g": 10.5, "sugar_g": 2.25, "sodium_mg": 168 },
        "aliases": ["cumin seed", "jeera"]
      },
      {
        "key": "red_pepper_flakes",
        "fdc_id": 170932,
        "legacy_id": 46,
        "display_name": "Red pepper flakes",
        "category": "spice",
        "per_100g": { "kcal": 318, "protein_g": 12.01, "carbs_g": 56.63, "fat_g": 17.27, "fiber_g": 27.2, "sugar_g": 10.34, "sodium_mg": 30 },
        "aliases": ["chilli flakes", "crushed red pepper"]
      },
      {
        "key": "ginger",
        "fdc_id": 169231,
        "legacy_id": 30,
        "display_name": "Ginger",
        "category": "vegetable",
        "per_100g": null,
        "aliases": ["fresh ginger", "ginger root"]
      },
      {
        "key": "garlic",
        "fdc_id": 169230,
        "legacy_id": 6,
        "display_name": "Garlic",
        "category": "vegetable",
        "per_100g": { "kcal": 149, "protein_g": 6.36, "carbs_g": 33.06, "fat_g": 0.5, "fiber_g": 2.1, "sugar_g": 1.0, "sodium_mg": 17 },
        "aliases": ["garlic clove", "minced garlic"]
      },
      {
        "key": "rice",
        "fdc_id": null,
        "legacy_id": 2,
        "display_name": "Rice",
        "category": "grain",
        "per_100g": null,
        "aliases": ["white rice", "jasmine rice", "leftover rice"]
      },
      {
        "key": "pasta",
        "fdc_id": null,
        "legacy_id": 9,
        "display_name": "Pasta",
        "category": "grain",
        "per_100g": null,
        "aliases": ["spaghetti", "penne"]
      },
      {
        "key": "butter",
        "fdc_id": null,
        "legacy_id": 14,
        "display_name": "Butter",
        "category": "dairy_egg",
        "per_100g": null,
        "aliases": ["unsalted butter"]
      },
      {
        "key": "tomato",
        "fdc_id": null,
        "legacy_id": 7,
        "display_name": "Tomato",
        "category": "vegetable",
        "per_100g": null,
        "aliases": ["tomatoes", "canned tomatoes"]
      },
      {
        "key": "lemon",
        "fdc_id": null,
        "legacy_id": 17,
        "display_name": "Lemon",
        "category": "vegetable",
        "per_100g": null,
        "aliases": ["lemon juice", "lemon zest"]
      },
      {
        "key": "cilantro",
        "fdc_id": null,
        "legacy_id": 48,
        "display_name": "Cilantro",
        "category": "vegetable",
        "per_100g": null,
        "aliases": ["coriander leaves", "fresh coriander"]
      },
      {
        "key": "salt",
        "fdc_id": null,
        "legacy_id": null,
        "display_name": "Salt",
        "category": "spice",
        "per_100g": null,
        "aliases": ["kosher salt", "sea salt"]
      }
    ],
    "recipes": [
      {
        "catalog_id": "rcp-000002",
        "revision": 2,
        "title": "Simple Cheese Omelette",
        "cuisine": "american",
        "meal_slots": ["breakfast", "lunch"],
        "collections": ["quick", "comfort"],
        "minutes": 10,
        "servings": 1,
        "equipment": ["non-stick pan"],
        "ingredients": [
          { "key": "egg", "quantity": { "kind": "count", "amount": 3, "unit": "large", "grams": 150 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "butter", "quantity": { "kind": "household", "amount": 1, "unit": "tbsp", "grams": null }, "required": true, "assumed_staple": true, "note": null },
          { "key": "salt", "quantity": { "kind": "unknown", "note": "to taste" }, "required": true, "assumed_staple": true, "note": null }
        ],
        "steps": [
          {
            "text": "Crack the eggs into a bowl, add a pinch of salt, and beat until the yolks and whites are fully combined.",
            "uses": [0, 2],
            "timer_seconds": null,
            "thermometer": null
          },
          {
            "text": "Melt the butter in a non-stick pan over medium heat until it foams but does not brown.",
            "uses": [1],
            "timer_seconds": 60,
            "thermometer": null
          },
          {
            "text": "Pour in the eggs and stir slowly with a spatula, lifting the set edges and letting the liquid run under, until the omelette is mostly set but still glossy.",
            "uses": [0],
            "timer_seconds": 120,
            "thermometer": null
          },
          {
            "text": "Fold the omelette in half and slide it onto a plate. If serving eggs to someone pregnant, older, or very young, cook the omelette through until a thermometer in the centre reads 71 °C (160 °F) and no runny egg remains.",
            "uses": [0],
            "timer_seconds": null,
            "thermometer": { "endpoint_c": 71, "food": "omelette centre", "source": "usda-fsis: egg dishes 160 F" }
          }
        ],
        "claims": { "vegetarian": true, "vegan": false, "gluten_free": true, "dairy_free": false },
        "nutrition_per_serving": {
          "kcal": 335,
          "protein_g": 22,
          "carbs_g": 1,
          "fat_g": 27,
          "fiber_g": 0,
          "sodium_mg": 640,
          "coverage": "estimated",
          "basis": "no weighed line has a catalog per-100g row (catalog lacks a whole-egg row, butter and salt carry none), so all values are household-to-gram estimates from FNDDS reference values"
        },
        "rights": { "status": "original", "evidence": "rewritten as an original for FridgeLuck burst5; replaces the revision-1 text that cited bbcgoodfood.com (rights audit, PR #43)" },
        "keywords": ["omelette", "eggs", "breakfast", "quick", "vegetarian"]
      },
      {
        "catalog_id": "rcp-000101",
        "revision": 1,
        "title": "Coconut Chickpea Curry",
        "cuisine": "indian",
        "meal_slots": ["dinner", "lunch"],
        "collections": ["budget", "one_pot"],
        "minutes": 30,
        "servings": 4,
        "equipment": ["large pan"],
        "ingredients": [
          { "key": "chickpeas", "quantity": { "kind": "grams", "grams": 480 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "coconut_milk", "quantity": { "kind": "grams", "grams": 400 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "tomato", "quantity": { "kind": "grams", "grams": 200 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "spinach", "quantity": { "kind": "grams", "grams": 100 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "garlic", "quantity": { "kind": "grams", "grams": 10 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "cumin", "quantity": { "kind": "household", "amount": 1, "unit": "tsp", "grams": 2 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "olive_oil", "quantity": { "kind": "household", "amount": 1, "unit": "tbsp", "grams": 14 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "salt", "quantity": { "kind": "unknown", "note": "to taste" }, "required": true, "assumed_staple": true, "note": null },
          { "key": "cilantro", "quantity": { "kind": "household", "amount": 1, "unit": "handful", "grams": null }, "required": false, "assumed_staple": false, "note": "for garnish" }
        ],
        "steps": [
          {
            "text": "Warm the oil in a large pan over medium heat and fry the garlic and cumin until fragrant, about 30 seconds.",
            "uses": [6, 4, 5],
            "timer_seconds": 30,
            "thermometer": null
          },
          {
            "text": "Add the tomatoes and cook until they break down into a rough sauce, about 5 minutes.",
            "uses": [2],
            "timer_seconds": 300,
            "thermometer": null
          },
          {
            "text": "Stir in the coconut milk and chickpeas, then simmer until the sauce coats the back of a spoon, about 10 minutes.",
            "uses": [1, 0],
            "timer_seconds": 600,
            "thermometer": null
          },
          {
            "text": "Add the spinach and cook until just wilted, then season with salt to taste and finish with cilantro if you have it.",
            "uses": [3, 7, 8],
            "timer_seconds": null,
            "thermometer": null
          }
        ],
        "claims": { "vegetarian": true, "vegan": true, "gluten_free": true, "dairy_free": true },
        "nutrition_per_serving": {
          "kcal": 425,
          "protein_g": 12,
          "carbs_g": 33,
          "fat_g": 28,
          "fiber_g": 8,
          "sodium_mg": 480,
          "coverage": "partial",
          "basis": "coconut milk, spinach, garlic, cumin, oil from catalog per-100g rows x line grams; the chickpeas row (fdc 2644282) carries no calorie value in the bundled catalog, so chickpea energy is estimated from dry-chickpea reference values and flagged estimated"
        },
        "rights": { "status": "original", "evidence": "authored for FridgeLuck burst5 originals packet, 2026-Q4" },
        "keywords": ["curry", "chickpea", "vegan", "one pot", "budget", "coconut"]
      },
      {
        "catalog_id": "rcp-000300",
        "revision": 1,
        "title": "Weeknight Garlic Butter Pasta",
        "cuisine": "italian",
        "meal_slots": ["dinner", "lunch"],
        "collections": ["quick", "comfort"],
        "minutes": 20,
        "servings": 2,
        "equipment": ["large pot", "frying pan"],
        "ingredients": [
          { "key": "pasta", "quantity": { "kind": "grams", "grams": 200 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "butter", "quantity": { "kind": "household", "amount": 2, "unit": "tbsp", "grams": null }, "required": true, "assumed_staple": true, "note": null },
          { "key": "garlic", "quantity": { "kind": "count", "amount": 3, "unit": "cloves", "grams": 9 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "olive_oil", "quantity": { "kind": "household", "amount": 1, "unit": "tbsp", "grams": 14 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "salt", "quantity": { "kind": "unknown", "note": "for the pasta water, to taste" }, "required": true, "assumed_staple": true, "note": null }
        ],
        "steps": [
          {
            "text": "Bring a large pot of salted water to the boil and cook the pasta until just tender with a slight bite, about 10 minutes; reserve a cup of the water before draining.",
            "uses": [0, 4],
            "timer_seconds": 600,
            "thermometer": null
          },
          {
            "text": "While the pasta cooks, warm the oil and butter in a frying pan and fry the sliced garlic gently until pale gold, about 2 minutes.",
            "uses": [3, 1, 2],
            "timer_seconds": 120,
            "thermometer": null
          },
          {
            "text": "Toss the drained pasta through the garlic butter with a splash of the reserved water until every piece is glossy.",
            "uses": [0],
            "timer_seconds": null,
            "thermometer": null
          }
        ],
        "claims": { "vegetarian": true, "vegan": false, "gluten_free": null, "dairy_free": false },
        "nutrition_per_serving": {
          "kcal": 560,
          "protein_g": 14,
          "carbs_g": 72,
          "fat_g": 23,
          "fiber_g": 3,
          "sodium_mg": 210,
          "coverage": "partial",
          "basis": "garlic and olive oil from catalog per-100g rows; pasta and butter carry no nutrition in the bundle sample, estimated from package-typical values and flagged estimated"
        },
        "rights": { "status": "original", "evidence": "authored for FridgeLuck burst5 originals packet, 2026-Q4" },
        "keywords": ["pasta", "garlic", "butter", "quick", "weeknight", "vegetarian"]
      },
      {
        "catalog_id": "rcp-000301",
        "revision": 1,
        "title": "20-Minute Ginger Beef Stir-Fry",
        "cuisine": "asian",
        "meal_slots": ["dinner"],
        "collections": ["quick"],
        "minutes": 20,
        "servings": 2,
        "equipment": ["wok"],
        "ingredients": [
          { "key": "ground_beef", "quantity": { "kind": "grams", "grams": 300 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "ginger", "quantity": { "kind": "grams", "grams": 25 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "garlic", "quantity": { "kind": "count", "amount": 2, "unit": "cloves", "grams": 6 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "soy_sauce", "quantity": { "kind": "household", "amount": 2, "unit": "tbsp", "grams": 30 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "sesame_oil", "quantity": { "kind": "household", "amount": 1, "unit": "tsp", "grams": 5 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "spinach", "quantity": { "kind": "grams", "grams": 100 }, "required": true, "assumed_staple": false, "note": null }
        ],
        "steps": [
          {
            "text": "Heat half the sesame oil in a wok over high heat until it just smokes.",
            "uses": [4],
            "timer_seconds": null,
            "thermometer": null
          },
          {
            "text": "Brown the beef, pressing it flat and letting it sit undisturbed 2 minutes before tossing, breaking it up as it colours.",
            "uses": [0],
            "timer_seconds": 240,
            "thermometer": null
          },
          {
            "text": "Add the ginger and garlic and fry 30 seconds, then add the soy sauce and toss to coat.",
            "uses": [1, 2, 3],
            "timer_seconds": 30,
            "thermometer": null
          },
          {
            "text": "Cook until a thermometer in the thickest clump of beef reads 71 °C (160 °F), then fold in the spinach until just wilted and finish with the remaining sesame oil.",
            "uses": [0, 5, 4],
            "timer_seconds": null,
            "thermometer": { "endpoint_c": 71, "food": "ground beef, thickest clump", "source": "usda-fsis: ground beef 160 F" }
          }
        ],
        "claims": { "vegetarian": false, "vegan": false, "gluten_free": null, "dairy_free": true },
        "nutrition_per_serving": {
          "kcal": 475,
          "protein_g": 33,
          "carbs_g": 5,
          "fat_g": 34,
          "fiber_g": 2,
          "sodium_mg": 1720,
          "coverage": "computed",
          "basis": "every weighed line has a catalog per-100g row; soy sauce 30 g at 5586 mg/100 g dominates sodium"
        },
        "rights": { "status": "original", "evidence": "authored for FridgeLuck burst5 originals packet, 2026-Q4" },
        "keywords": ["stir-fry", "beef", "ginger", "quick", "high protein", "wok"]
      },
      {
        "catalog_id": "rcp-000302",
        "revision": 1,
        "title": "Sheet-Pan Lemon Broccoli",
        "cuisine": "mediterranean",
        "meal_slots": ["dinner", "lunch"],
        "collections": ["quick", "budget", "use_soon"],
        "minutes": 25,
        "servings": 2,
        "equipment": ["sheet pan", "oven"],
        "ingredients": [
          { "key": "broccoli", "quantity": { "kind": "grams", "grams": 400 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "olive_oil", "quantity": { "kind": "household", "amount": 2, "unit": "tbsp", "grams": 28 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "lemon", "quantity": { "kind": "household", "amount": 1, "unit": "tbsp", "grams": null }, "required": true, "assumed_staple": false, "note": "juice" },
          { "key": "salt", "quantity": { "kind": "unknown", "note": "to taste" }, "required": true, "assumed_staple": true, "note": null },
          { "key": "red_pepper_flakes", "quantity": { "kind": "household", "amount": 0.5, "unit": "tsp", "grams": 1 }, "required": false, "assumed_staple": false, "note": "for garnish" }
        ],
        "steps": [
          {
            "text": "Heat the oven to 220 °C (fan 200 °C) with the sheet pan inside so it is screaming hot.",
            "uses": [],
            "timer_seconds": null,
            "thermometer": null
          },
          {
            "text": "Toss the broccoli florets with the oil and salt directly on the hot pan and roast, turning once, until the stems are tender and the tips are deeply browned, about 15 minutes.",
            "uses": [0, 1, 3],
            "timer_seconds": 900,
            "thermometer": null
          },
          {
            "text": "Squeeze the lemon over the hot broccoli and scatter with red pepper flakes if you like heat.",
            "uses": [2, 4],
            "timer_seconds": null,
            "thermometer": null
          }
        ],
        "claims": { "vegetarian": true, "vegan": true, "gluten_free": true, "dairy_free": true },
        "nutrition_per_serving": {
          "kcal": 175,
          "protein_g": 6,
          "carbs_g": 14,
          "fat_g": 14,
          "fiber_g": 5,
          "sodium_mg": 120,
          "coverage": "computed",
          "basis": "broccoli, olive oil and red pepper flakes from catalog per-100g rows x line grams; lemon juice and salt lines carry no nutrition"
        },
        "rights": { "status": "original", "evidence": "authored for FridgeLuck burst5 originals packet, 2026-Q4" },
        "keywords": ["broccoli", "side", "vegan", "sheet pan", "lemon", "budget"]
      },
      {
        "catalog_id": "rcp-000303",
        "revision": 1,
        "title": "Cumin-Spun Tomato Rice",
        "cuisine": "mexican",
        "meal_slots": ["dinner", "lunch"],
        "collections": ["budget", "one_pot", "use_soon"],
        "minutes": 35,
        "servings": 4,
        "equipment": ["lidded pan"],
        "ingredients": [
          { "key": "rice", "quantity": { "kind": "grams", "grams": 300 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "tomato", "quantity": { "kind": "grams", "grams": 300 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "garlic", "quantity": { "kind": "count", "amount": 2, "unit": "cloves", "grams": 6 }, "required": true, "assumed_staple": false, "note": null },
          { "key": "cumin", "quantity": { "kind": "household", "amount": 1, "unit": "tsp", "grams": 2 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "olive_oil", "quantity": { "kind": "household", "amount": 1, "unit": "tbsp", "grams": 14 }, "required": true, "assumed_staple": true, "note": null },
          { "key": "salt", "quantity": { "kind": "unknown", "note": "to taste" }, "required": true, "assumed_staple": true, "note": null },
          { "key": "cilantro", "quantity": { "kind": "household", "amount": 1, "unit": "handful", "grams": null }, "required": false, "assumed_staple": false, "note": "for garnish" }
        ],
        "steps": [
          {
            "text": "Rinse the rice until the water runs clear and drain it well.",
            "uses": [0],
            "timer_seconds": null,
            "thermometer": null
          },
          {
            "text": "Fry the rice in the oil with the garlic and cumin, stirring, until the grains look chalky and smell nutty, about 3 minutes.",
            "uses": [0, 2, 3, 4],
            "timer_seconds": 180,
            "thermometer": null
          },
          {
            "text": "Blend the tomatoes smooth, add to the pan with 450 ml water and the salt, and bring to the boil.",
            "uses": [1, 5],
            "timer_seconds": null,
            "thermometer": null
          },
          {
            "text": "Cover, drop the heat to low, and steam until the rice is tender and the liquid is gone, about 18 minutes; rest covered 5 minutes off the heat before fluffing.",
            "uses": [0],
            "timer_seconds": 1080,
            "thermometer": null
          },
          {
            "text": "Fluff with a fork and scatter cilantro over the top if you have it.",
            "uses": [6],
            "timer_seconds": null,
            "thermometer": null
          }
        ],
        "claims": { "vegetarian": true, "vegan": true, "gluten_free": true, "dairy_free": true },
        "nutrition_per_serving": {
          "kcal": 290,
          "protein_g": 6,
          "carbs_g": 56,
          "fat_g": 5,
          "fiber_g": 4,
          "sodium_mg": 150,
          "coverage": "partial",
          "basis": "garlic, cumin and olive oil from catalog per-100g rows; rice and tomato carry no nutrition in the bundle sample, estimated from package-typical values and flagged estimated"
        },
        "rights": { "status": "original", "evidence": "authored for FridgeLuck burst5 originals packet, 2026-Q4" },
        "keywords": ["rice", "tomato", "cumin", "vegan", "one pot", "budget", "side"]
      }
    ]
  }
  """#
}
