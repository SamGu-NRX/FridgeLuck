import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// The catalog pool must merge into the recommendation engine under the shared ranking
/// policy, matching only through the hydration-time identity bridge: an unresolved key
/// counts as missing and is never matched by name. Successor dedupe keeps one row per
/// dish (the legacy entry when it can appear), allergen and diet gates fail closed, and
/// use-soon urgency boosts both pools identically.
final class RecipeCatalogRecommendTests: XCTestCase {
  // Pantry: egg(1), rice(2). Not in the pantry: peanut(3), tofu(4).
  // rcp-000001 stands alone; rcp-000002 succeeds legacy 1; rcp-000006 succeeds legacy 3.
  func testFindMakeableMergesLegacyAndCatalogPools() throws {
    let repo = try makeRepository()
    let results = try repo.findMakeable(with: [1, 2], profile: .default)

    let ids = results.map(\.id)
    XCTAssertTrue(ids.contains(.legacy(1)), "legacy Egg Fried Rice should appear")
    XCTAssertTrue(
      ids.contains(.catalog("rcp-000001")),
      "standalone catalog recipe should appear next to the legacy pool")
    XCTAssertFalse(
      ids.contains(.catalog("rcp-000002")),
      "a catalog successor yields to its matchable legacy recipe")
    XCTAssertFalse(
      ids.contains(.catalog("rcp-000006")),
      "a catalog successor yields to its matchable legacy recipe")

    let catalogEntry = try XCTUnwrap(results.first { $0.id == .catalog("rcp-000001") })
    XCTAssertEqual(catalogEntry.recipe.id, nil, "catalog entries synthesize no integer id")
    XCTAssertEqual(catalogEntry.catalog?.ref, .catalog(id: "rcp-000001", revision: 1))
    XCTAssertEqual(catalogEntry.catalog?.successorToLegacyRecipeID, nil)
    XCTAssertEqual(catalogEntry.matchTier, .exact)
    XCTAssertEqual(catalogEntry.matchedRequired, 2)
    XCTAssertEqual(catalogEntry.totalRequired, 2)
    XCTAssertEqual(catalogEntry.missingRequiredCount, 0)
  }

  // Identity across both pools: catalog entries (nil recipe.id) must not collide with
  // each other or with legacy entries in list identity.
  func testCatalogAndLegacyEntriesHaveDistinctIdentity() throws {
    let repo = try makeRepository()
    let results = try repo.findMakeable(with: [1, 2], profile: .default)
    let ids = results.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count, "identities must be unique within one result list")
  }

  // An unbridged key is "not in your kitchen": it makes the line missing for tier
  // purposes but carries no ingredient id, so no identity is invented for it.
  func testUnbridgedKeyCountsAsMissingWithoutIngredientIDs() throws {
    let repo = try makeRepository()

    let exact = try repo.findMakeable(with: [1, 2], profile: .default)
    XCTAssertFalse(exact.contains { $0.id == .catalog("rcp-000003") })

    let near = try repo.findNearMatch(with: [1, 2], profile: .default)
    let mystery = try XCTUnwrap(near.first { $0.id == .catalog("rcp-000003") })
    XCTAssertEqual(mystery.matchTier, .nearMatch)
    XCTAssertEqual(mystery.missingRequiredCount, 1)
    XCTAssertEqual(mystery.missingIngredientIds, [], "no id may be guessed for an unbridged key")
  }

  // Allergen exclusion removes a catalog recipe entirely (whole-recipe gate), and its
  // legacy counterpart in the same pantry.
  func testAllergenGateRemovesCatalogRecipe() throws {
    let repo = try makeRepository()
    var profile = HealthProfile.default
    profile.allergenIngredientIds = "[3]"

    let exact = try repo.findMakeable(with: [1, 2, 3], profile: profile)
    XCTAssertFalse(exact.contains { $0.id == .catalog("rcp-000004") })
    XCTAssertFalse(exact.contains { $0.id == .legacy(2) }, "legacy allergen gate unchanged")

    let near = try repo.findNearMatch(with: [1, 2, 3], profile: profile)
    XCTAssertFalse(near.contains { $0.id == .catalog("rcp-000004") })
  }

  // Diet claims gate the catalog pool fail-closed: a null (or absent) claim fails the
  // vegetarian gate even when every ingredient matches.
  func testVegetarianClaimGatesCatalogPool() throws {
    let repo = try makeRepository()
    let profile = profileWithDiet("vegetarian")

    let results = try repo.findMakeable(with: [1, 2, 4], profile: profile)
    let ids = results.map(\.id)
    XCTAssertTrue(ids.contains(.catalog("rcp-000005")), "claimed vegetarian passes the gate")
    XCTAssertFalse(
      ids.contains(.catalog("rcp-000001")),
      "a recipe without the claim fails the gate even with a full pantry match")
    XCTAssertFalse(ids.contains(.legacy(1)), "legacy pool still gates on its own tag mask")
  }

  // A catalog successor appears only when its legacy recipe cannot appear at all
  // (here: vegan tag mask blocks the legacy pool, while the successor carries the claim).
  func testSuccessorAppearsWhenLegacyRecipeIsBlocked() throws {
    let repo = try makeRepository()
    let profile = profileWithDiet("vegan")

    let results = try repo.findMakeable(with: [1, 2], profile: profile)
    let ids = results.map(\.id)
    XCTAssertTrue(ids.contains(.catalog("rcp-000006")), "successor fills the blocked legacy slot")
    XCTAssertFalse(ids.contains(.legacy(3)), "legacy pool blocked by the vegan tag mask")
    XCTAssertFalse(ids.contains(.legacy(1)))
    XCTAssertFalse(ids.contains(.catalog("rcp-000001")), "unclaimed recipe fails the vegan gate")
  }

  // Use-soon urgency: an inventory lot expiring within the 3-day horizon boosts both
  // pools identically — each entry's score rises by exactly the bonus versus the same
  // pantry with no expiring lot. A lot expiring later changes nothing.
  func testUseSoonBonusAppliesToBothPools() throws {
    let withSoon = try findMakeableScores(lotExpiresInDays: 2)
    let withoutSoon = try findMakeableScores(lotExpiresInDays: 10)

    let legacyID = ScoredRecipeID.legacy(1)
    let catalogID = ScoredRecipeID.catalog("rcp-000001")
    XCTAssertEqual(
      (try XCTUnwrap(withSoon[legacyID])) - (try XCTUnwrap(withoutSoon[legacyID])),
      RecipeRepository.useSoonBonus, accuracy: 0.0001,
      "legacy entry gains exactly the bonus when a lot expires within the horizon")
    XCTAssertEqual(
      (try XCTUnwrap(withSoon[catalogID])) - (try XCTUnwrap(withoutSoon[catalogID])),
      RecipeRepository.useSoonBonus, accuracy: 0.0001,
      "catalog entry gains exactly the bonus when a lot expires within the horizon")
  }

  func testUseSoonReasonSurfacesOnBothPoolsWithinTheHorizon() throws {
    let db = try makeDatabase()
    try InventoryRepository(db: db).addLot(
      ingredientId: 2, quantityGrams: 500, location: .fridge, confidenceScore: 1,
      source: .manual, expiresAt: Date().addingTimeInterval(2 * 24 * 3600))
    let results = try makeRepository(db: db).findMakeable(with: [1, 2], profile: .default)

    let legacy = try XCTUnwrap(results.first { $0.id == .legacy(1) })
    let catalog = try XCTUnwrap(results.first { $0.id == .catalog("rcp-000001") })
    XCTAssertTrue(legacy.rankingReasons.contains(RecipeRepository.useSoonReason))
    XCTAssertTrue(catalog.rankingReasons.contains(RecipeRepository.useSoonReason))
  }

  func testUseSoonBonusIgnoresLotsBeyondTheHorizon() throws {
    let db = try makeDatabase()
    try InventoryRepository(db: db).addLot(
      ingredientId: 2, quantityGrams: 500, location: .fridge, confidenceScore: 1,
      source: .manual, expiresAt: Date().addingTimeInterval(10 * 24 * 3600))
    let results = try makeRepository(db: db).findMakeable(with: [1, 2], profile: .default)
    for entry in results {
      XCTAssertFalse(entry.rankingReasons.contains(RecipeRepository.useSoonReason))
    }
  }

  // The cook packet: structured lines and steps in the drawer/cook-mode shapes, position
  // ordered, with the bridge carrying exact identities only.
  func testCookPacketCarriesStructuredLinesAndSteps() throws {
    let repo = try makeRepository()
    let packet = try XCTUnwrap(try repo.catalogCookPacket(catalogId: "rcp-000001"))

    XCTAssertEqual(packet.title, "Catalog Fried Rice")
    XCTAssertEqual(packet.revision, 1)
    XCTAssertEqual(packet.servings, 2)

    XCTAssertEqual(packet.lines.map(\.key), ["egg", "rice"])
    let egg = packet.lines[0]
    XCTAssertEqual(egg.displayName, "Egg")
    XCTAssertEqual(egg.bridgedIngredientId, 1)
    XCTAssertEqual(egg.quantity, .count(amount: 2, unit: "large", grams: 100))
    XCTAssertEqual(egg.required, true)
    let rice = packet.lines[1]
    XCTAssertEqual(rice.bridgedIngredientId, 2)
    XCTAssertEqual(rice.quantity, .grams(300))

    XCTAssertEqual(packet.steps.count, 2)
    XCTAssertEqual(packet.steps[0].text, "Fry the eggs.")
    XCTAssertEqual(packet.steps[0].uses, [0])
    XCTAssertEqual(packet.steps[0].timerSeconds, 180)
    XCTAssertEqual(packet.steps[0].thermometer, nil)
    XCTAssertEqual(packet.steps[1].text, "Check the rice.")
    XCTAssertEqual(
      packet.steps[1].thermometer,
      CookThermometer(endpointC: 74, food: "rice center", source: "usda-fsis: cooked rice 74 C"))
  }

  func testCookPacketReturnsNilForUnknownCatalogID() throws {
    let repo = try makeRepository()
    XCTAssertNil(try repo.catalogCookPacket(catalogId: "rcp-does-not-exist"))
  }

  // MARK: - Review round (PR #172)

  // Review finding 1: a catalog recommendation must yield cookable content through the
  // repository — structured steps for the guide and its bridged ingredient list for the
  // cooking guide and assistant context — instead of dead-ending on the nil-id legacy
  // stand-in (empty instructions, no ingredients).
  func testCatalogRecommendationYieldsCookPacketAndBridgedIngredients() throws {
    let repo = try makeRepository()
    let results = try repo.findMakeable(with: [1, 2], profile: .default)
    let catalogResult = try XCTUnwrap(
      results.first { $0.catalog != nil && $0.recipe.id == nil },
      "the pantry should match a standalone catalog recipe")

    let packet = try XCTUnwrap(try repo.catalogCookPacket(for: catalogResult))
    XCTAssertEqual(packet.title, catalogResult.recipe.title)
    XCTAssertFalse(packet.steps.isEmpty, "the guide needs structured steps")
    XCTAssertFalse(
      packet.steps.map(\.text).joined(separator: "\n").isEmpty,
      "guide instructions must not be empty for a catalog recipe")

    let ingredients = try repo.cookPacketIngredients(packet)
    XCTAssertFalse(
      ingredients.isEmpty,
      "bridged lines must surface as the ingredient list; empty means Le Chef sees nothing")
    for (ingredient, quantity) in ingredients {
      XCTAssertFalse(ingredient.name.isEmpty)
      XCTAssertEqual(quantity.ingredientId, ingredient.id)
      XCTAssertFalse(quantity.displayQuantity.isEmpty)
    }
  }

  // Review finding 2: keto must fail closed on the catalog pool. The claims schema has
  // no low-carb field, so no catalog recipe can prove compliance, while the legacy pool
  // enforces the .lowCarb tag mask — the asymmetry would empty the legacy pool and leave
  // the catalog pool fully ungated.
  func testKetoDietExcludesCatalogPoolFailingClosed() throws {
    let repo = try makeRepository()
    let results = try repo.findMakeable(with: [1, 2], profile: profileWithDiet("keto"))
    XCTAssertFalse(
      results.contains { $0.catalog != nil },
      "keto must exclude the catalog pool: no low-carb claim exists to prove compliance")
  }

  // The bridge rebuild: legacy_id and fdc_id resolve independently; a key carrying
  // both bridges the union of the two id sets; unresolved keys stay unmapped.
  func testBridgeRebuildResolvesByLegacyIDThenFDCIdentity() throws {
    let db = try makeBridgeDatabase()
    let usda = USDAIdentitySource(
      nameByFDC: [900: "tofu"],
      aliasesByFDC: [900: ["bean curd"]])

    let coverage = try db.write { db in
      try RecipeCatalogIngredientBridge.rebuild(db: db, usda: usda)
    }

    XCTAssertEqual(coverage.totalKeys, 3)
    XCTAssertEqual(coverage.resolvedByLegacyID, 1)
    XCTAssertEqual(coverage.resolvedByFDCID, 1)

    let resolved: [(key: String, id: Int64, by: String)] = try db.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT ingredient_key, ingredient_id, resolved_by FROM recipes_catalog_ingredient_bridge"
      ).map { row in
        (row["ingredient_key"], row["ingredient_id"], row["resolved_by"])
      }
    }
    XCTAssertTrue(
      resolved.contains(where: { $0.key == "egg" && $0.id == 1 && $0.by == "legacy_id" }))
    XCTAssertTrue(
      resolved.contains(where: { $0.key == "tofu" && $0.id == 4 && $0.by == "fdc_id" }),
      "USDA source name and its app alias both point at ingredient 4")
    XCTAssertFalse(resolved.contains { $0.key == "mystery_root" }, "no link, no guess")
  }

  // A key carrying both a legacy id and an FDC id bridges the union of the two id
  // sets: either name the household types must reach the recipe key.
  func testBridgeRebuildUnionsLegacyAndFDCEvidence() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'egg', 155, 13, 1.1, 11),
            (4, 'tofu', 76, 8, 1.9, 4.8);
          INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category) VALUES
            ('paneer', 900, 4, 'Paneer', 'protein');
          """)
    }
    // FDC 900 resolves to the app row named 'egg' (id 1); legacy_id 4 resolves to 'tofu'.
    let usda = USDAIdentitySource(
      nameByFDC: [900: "egg"],
      aliasesByFDC: [:])

    let coverage = try db.write { db in
      try RecipeCatalogIngredientBridge.rebuild(db: db, usda: usda)
    }

    XCTAssertEqual(coverage.totalKeys, 1)
    XCTAssertEqual(coverage.resolvedKeys, 1)
    XCTAssertEqual(coverage.resolvedByLegacyAndFDC, 1)
    XCTAssertEqual(coverage.resolvedByLegacyID, 0)
    XCTAssertEqual(coverage.resolvedByFDCID, 0)

    let resolved: [(id: Int64, by: String)] = try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT ingredient_id, resolved_by FROM recipes_catalog_ingredient_bridge
          WHERE ingredient_key = 'paneer'
          """).map { row in
        (row["ingredient_id"], row["resolved_by"])
      }
    }
    XCTAssertEqual(
      Set(resolved.map(\.id)), Set([Int64(1), Int64(4)]),
      "both the legacy ingredient and the USDA source row bridge the key")
    XCTAssertEqual(Set(resolved.map(\.by)), Set(["legacy_id+fdc_id"]))
  }

  // MARK: - Fixtures

  private func profileWithDiet(_ dietID: String) -> HealthProfile {
    var profile = HealthProfile.default
    profile.dietaryRestrictions = "[\"\(dietID)\"]"
    return profile
  }

  /// Ranking scores of one findMakeable run over the shared fixture, with a rice lot
  /// expiring after the given number of days.
  private func findMakeableScores(lotExpiresInDays: Double) throws -> [ScoredRecipeID: Double] {
    let db = try makeDatabase()
    try InventoryRepository(db: db).addLot(
      ingredientId: 2, quantityGrams: 500, location: .fridge, confidenceScore: 1,
      source: .manual, expiresAt: Date().addingTimeInterval(lotExpiresInDays * 24 * 3600))
    let repo = try makeRepository(db: db)
    let results = try repo.findMakeable(with: [1, 2], profile: .default)
    return Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.rankingScore) })
  }

  private func makeRepository(db: DatabaseQueue? = nil) throws -> RecipeRepository {
    let queue = try db ?? makeDatabase()
    let nutrition = NutritionService(db: queue)
    return RecipeRepository(
      db: queue,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: queue),
      personalizationService: PersonalizationService(db: queue)
    )
  }

  /// Production migrations plus the legacy and catalog fixtures every matcher test shares.
  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'egg', 155, 13, 1.1, 11),
            (2, 'rice', 130, 2.7, 28, 0.3),
            (3, 'peanut', 567, 25.8, 16, 49),
            (4, 'tofu', 76, 8, 1.9, 4.8);

          INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
            (1, 'Egg Fried Rice', 15, 2, 'Fry.'),
            (2, 'Peanut Stew', 40, 4, 'Simmer.'),
            (3, 'Chicken Rice', 25, 2, 'Cook.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
            (1, 1, 1, 100, '2 eggs'),
            (1, 2, 1, 300, '300 g'),
            (2, 3, 1, 200, '200 g'),
            (3, 2, 1, 300, '300 g');

          INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category, classes) VALUES
            ('egg', NULL, 1, 'Egg', 'protein', '["egg"]'),
            ('rice', NULL, 2, 'Rice', 'grain', '["plant"]'),
            ('peanut', NULL, 3, 'Peanut', 'legume', '["peanut","plant"]'),
            ('tofu', NULL, 4, 'Tofu', 'protein', '["soy","plant"]'),
            ('mystery_root', NULL, NULL, 'Mystery Root', 'vegetable', '["unknown"]');
          INSERT INTO recipes_catalog_ingredient_bridge
            (ingredient_key, ingredient_id, resolved_by) VALUES
            ('egg', 1, 'legacy_id'),
            ('rice', 2, 'legacy_id'),
            ('peanut', 3, 'legacy_id'),
            ('tofu', 4, 'legacy_id');

          INSERT INTO recipes_catalog
            (catalog_id, revision, title, cuisine, minutes, servings, claims,
             rights_status, rights_evidence, legacy_recipe_id) VALUES
            ('rcp-000001', 1, 'Catalog Fried Rice', 'chinese', 20, 2, '{}',
             'original', 'test-evidence', NULL),
            ('rcp-000002', 1, 'Successor Fried Rice', 'chinese', 20, 2, '{}',
             'original', 'test-evidence', 1),
            ('rcp-000003', 1, 'Mystery Dish', 'fusion', 30, 2, '{}',
             'original', 'test-evidence', NULL),
            ('rcp-000004', 1, 'Peanut Curry', 'thai', 35, 4, '{}',
             'original', 'test-evidence', NULL),
            ('rcp-000005', 1, 'Tofu Bowl', 'japanese', 15, 2,
             '{"vegetarian":true,"vegan":null,"gluten_free":null,"dairy_free":null}',
             'original', 'test-evidence', NULL),
            ('rcp-000006', 1, 'Vegan Rice Bowl', 'american', 20, 2,
             '{"vegetarian":true,"vegan":true,"gluten_free":null,"dairy_free":null}',
             'original', 'test-evidence', 3);

          INSERT INTO recipes_catalog_lines
            (catalog_id, position, ingredient_key, quantity_kind, quantity_grams,
             quantity_amount, quantity_unit, is_required, assumed_staple) VALUES
            ('rcp-000001', 0, 'egg', 'count', 100, 2, 'large', 1, 0),
            ('rcp-000001', 1, 'rice', 'grams', 300, NULL, NULL, 1, 0),
            ('rcp-000002', 0, 'egg', 'count', 100, 2, 'large', 1, 0),
            ('rcp-000002', 1, 'rice', 'grams', 300, NULL, NULL, 1, 0),
            ('rcp-000003', 0, 'mystery_root', 'unknown', NULL, NULL, NULL, 1, 0),
            ('rcp-000003', 1, 'egg', 'count', 100, 2, 'large', 1, 0),
            ('rcp-000004', 0, 'peanut', 'grams', 200, NULL, NULL, 1, 0),
            ('rcp-000004', 1, 'rice', 'grams', 300, NULL, NULL, 1, 0),
            ('rcp-000005', 0, 'rice', 'grams', 250, NULL, NULL, 1, 0),
            ('rcp-000005', 1, 'tofu', 'grams', 200, NULL, NULL, 1, 0),
            ('rcp-000006', 0, 'rice', 'grams', 300, NULL, NULL, 1, 0);

          INSERT INTO recipes_catalog_steps
            (catalog_id, position, text, uses, timer_seconds, thermometer_endpoint_c,
             thermometer_food, thermometer_source) VALUES
            ('rcp-000001', 0, 'Fry the eggs.', '[0]', 180, NULL, NULL, NULL),
            ('rcp-000001', 1, 'Check the rice.', '[]', NULL, 74.0, 'rice center',
             'usda-fsis: cooked rice 74 C');
          """
      )
    }
    return db
  }

  /// Migrations plus vocabulary and app ingredients only — the bridge table starts empty
  /// so the rebuild under test fills it.
  private func makeBridgeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'egg', 155, 13, 1.1, 11),
            (4, 'tofu', 76, 8, 1.9, 4.8);
          INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES
            (4, 'Bean Curd');

          INSERT INTO recipes_catalog_ingredients
            (key, fdc_id, legacy_id, display_name, category) VALUES
            ('egg', NULL, 1, 'Egg', 'protein'),
            ('tofu', 900, NULL, 'Tofu', 'protein'),
            ('mystery_root', NULL, NULL, 'Mystery Root', 'vegetable');
          """
      )
    }
    return db
  }
}
