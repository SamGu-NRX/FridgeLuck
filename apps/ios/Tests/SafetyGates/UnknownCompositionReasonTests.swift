import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The meal-log picker showed Kimchi Fried Rice and Blueberry Diner Pancakes as "Can't confirm
/// it fits your restrictions" for a peanut household, with no reason (2026-10-16 walk at alpha
/// af85600, shots -14 and -21). The refusal stands; the warning now names the lines.
final class UnknownCompositionReasonTests: XCTestCase {
  func testShippedRefusalsNameTheUnknownLines() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    guard RecipeBundleV2Loader.bundleV2URL(in: .main) != nil else {
      throw XCTSkip("shipped bundle missing from the app bundle")
    }
    try await AppDatabase(dbQueue: db).warmBundledContentIfNeeded()

    let ingredients = try await db.read { db in try Ingredient.fetchAll(db) }
    let peanutGroup = try XCTUnwrap(AllergenSupport.groups.first { $0.id == "peanut" })
    let peanutID = try XCTUnwrap(AllergenSupport.matchingIDs(for: peanutGroup, in: ingredients).max())
    var peanutHousehold = HealthProfile.default
    peanutHousehold.allergenIngredientIds = "[\(peanutID)]"
    let profile = peanutHousehold

    for (catalogID, expected) in [
      ("rcp-000573", "We can't check kimchi for peanut"),
      ("rcp-000953", "We can't check baking powder and sugar for peanut"),
    ] {
      try await db.read { db in
        let boundary = try HouseholdSafetyBoundary.load(profile: profile, in: db)
        let keys = try String.fetchAll(
          db,
          sql: "SELECT ingredient_key FROM recipes_catalog_lines WHERE catalog_id = ? ORDER BY position",
          arguments: [catalogID])
        let claims = try String.fetchOne(
          db, sql: "SELECT claims FROM recipes_catalog WHERE catalog_id = ?", arguments: [catalogID])
        let verdict = RecipeRepository.catalogMealLogVerdict(
          boundary: boundary, lineKeys: keys, claimsJSON: claims)
        XCTAssertEqual(verdict, .blocked(.unknownComposition), "\(catalogID) is still refused")
        XCTAssertFalse(boundary.admitsCatalogRecipe(lineKeys: keys, claimsJSON: claims))
        XCTAssertEqual(try boundary.warning(for: verdict, lineKeys: keys, in: db), expected)
      }
    }
  }

  /// The legacy search the picker lists: the entry it hands the UI carries the line's name.
  func testLegacySearchEntryCarriesTheUnknownIngredientName() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (30, 'peanut', 567, 25.8, 16, 49),
            (31, 'gochujang', 200, 4, 40, 1),
            (32, 'rice', 130, 2.7, 28, 0.3);
          INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category, classes) VALUES
            ('rice', NULL, 32, 'Rice', 'grain', '["plant"]');
          INSERT INTO recipes_catalog_ingredient_bridge
            (ingredient_key, ingredient_id, resolved_by) VALUES ('rice', 32, 'legacy_id');
          INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
            (1, 'Spicy Rice', 15, 2, '1. Cook.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
            (1, 32, 1, 300, '300 g'),
            (1, 31, 1, 30, '30 g');
          INSERT OR REPLACE INTO health_profile (id, allergen_ingredient_ids) VALUES (1, '[30]');
          """)
    }
    let nutrition = NutritionService(db: db)
    let repo = RecipeRepository(
      db: db, nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: PersonalizationService(db: db))

    let entry = try XCTUnwrap(try repo.searchRecipes(query: "Spicy").first)
    XCTAssertEqual(entry.verdict, .blocked(.unknownComposition))
    XCTAssertEqual(entry.warning, "We can't check gochujang for peanut")
  }

  /// Other refusals keep their wording.
  func testOtherReasonsAreUnchanged() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.read { db in
      let boundary = try HouseholdSafetyBoundary.load(profile: .default, in: db)
      XCTAssertEqual(
        try boundary.warning(for: .blocked(.diet(.vegan)), lineKeys: [], in: db),
        "Doesn't fit your vegan diet")
      XCTAssertNil(try boundary.warning(for: .allowed, lineKeys: ["kimchi"], in: db))
      XCTAssertEqual(
        try boundary.warning(for: .blocked(.unknownComposition), lineKeys: [], in: db),
        "Can't confirm it fits your restrictions",
        "a refusal with no unknown line keeps the general line")
    }
  }
}
