import GRDB
import XCTest

@testable import FridgeLuck

/// Mirrors the hosted MigrationUpgradeTests assertions so the full migration chain and
/// the snapshot backfill run on Linux: a v15 database upgraded through every migration
/// must apply the complete ordered sequence and backfill snapshots for existing meals.
final class MigrationChainTests: XCTestCase {
  func testUpgradeAppliesTheFullOrderedChainAndBackfillsSnapshots() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: "v15_notification_rules_and_opportunities")

    // Minimal pre-upgrade rows: one recipe (2 servings), egg 100 g at 140 kcal/100 g,
    // rice 200 g at 130 kcal/100 g, and two logged meals (1 and 2 of 2 servings).
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'egg', 140, 12, 1, 10),
            (2, 'rice', 130, 2.7, 28, 0.3);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Egg Fried Rice', 15, 2, 'Cook.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
            (1, 1, 1, 100, '2 eggs'),
            (1, 2, 1, 200, '1 cup');
          INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed)
          VALUES (1, 1, CURRENT_TIMESTAMP, NULL, 1), (2, 1, CURRENT_TIMESTAMP, 5, 2);
          """
      )
    }

    try DatabaseMigrations.migrate(db)

    // FULL ordered chain, ending with the snapshot cutover.
    let applied = try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
    XCTAssertEqual(
      applied,
      [
        "v1_initial", "v2_ingredient_education_fields", "v3_dish_templates",
        "v4_ingredient_aliases", "v5_ingredient_display_metadata",
        "v6_cooking_photo_servings", "v7_usda_catalog_state", "v8_bundled_recipe_state",
        "v9_smart_fridge_inventory", "v10_confidence_learning",
        "v11_reconcile_ingredientless_recipe_links", "v12_required_onboarding_identity",
        "v13_ingredient_favorites", "v14_pantry_assumptions_saved_winners",
        "v15_notification_rules_and_opportunities", "v16_inventory_quantity_estimates",
        "v17_cooking_portion_multiplier", "v18_cooking_history_swaps",
        "v19_accepted_meal_consumption_plan", "v20_accepted_meal_revision",
        "v21_historical_nutrition_snapshots",
      ])

    // Legacy rows: no stored plan, accepted revision 1.
    let legacy = try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, accepted_plan_json, accepted_plan_identity, accepted_revision
          FROM cooking_history ORDER BY id
          """
      ).map { row -> (id: Int64, hasPlan: Bool, revision: Int) in
        (
          row["id"], (row["accepted_plan_json"] as String?) != nil,
          row["accepted_revision"]
        )
      }
    }
    XCTAssertEqual(legacy.map { $0.id }, [1, 2])
    XCTAssertTrue(legacy.allSatisfy { !$0.hasPlan && $0.revision == 1 })

    // Backfilled snapshot headers for both pre-existing meals.
    let headers = try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT history_id, recipe_servings, snapshot_version, provenance
          FROM cooking_history_nutrition_snapshots ORDER BY history_id
          """
      ).map { row -> (Int64, Int, Int, String) in
        (row["history_id"], row["recipe_servings"], row["snapshot_version"], row["provenance"])
      }
    }
    XCTAssertEqual(headers.map { $0.0 }, [1, 2])
    XCTAssertTrue(headers.allSatisfy { $0.1 == 2 && $0.2 == 1 && $0.3 == "upgrade_backfill" })

    // Frozen lines carry the recipe's reference grams and per-100 g nutrients.
    let lines = try db.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT line_index, original_ingredient_id, quantity_grams, calories
          FROM cooking_history_nutrition_lines WHERE history_id = 1 ORDER BY line_index
          """
      ).map { row -> (Int, Int64, Double, Double) in
        (row["line_index"], row["original_ingredient_id"], row["quantity_grams"], row["calories"])
      }
    }
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines[0].0, 0)
    XCTAssertEqual(lines[0].1, 1)
    XCTAssertEqual(lines[0].2, 100, accuracy: 0.001)
    XCTAssertEqual(lines[0].3, 140, accuracy: 0.001)
    XCTAssertEqual(lines[1].0, 1)
    XCTAssertEqual(lines[1].1, 2)
    XCTAssertEqual(lines[1].2, 200, accuracy: 0.001)
    XCTAssertEqual(lines[1].3, 130, accuracy: 0.001)

    // The backfilled snapshot reproduces the live-catalog math: meal 1 (1 of 2
    // servings) = 50 g egg + 100 g rice = 200 kcal via the snapshot read path.
    let mealMacros = try NutritionSnapshotService(db: db).capturedMacros(historyId: 1)
    XCTAssertEqual(mealMacros.caloriesPerServing, 200, accuracy: 0.001)
  }
}
