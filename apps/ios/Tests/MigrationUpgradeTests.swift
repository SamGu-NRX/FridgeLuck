import GRDB
import XCTest

@testable import FridgeLuck

/// v16-v19 run on databases people already have. These tests build a v15 database the way the
/// previous app version wrote it, upgrade it, and check that nothing existing is lost or
/// re-marked. A fresh-install migration can't show that.
final class MigrationUpgradeTests: XCTestCase {
  private let lastShippedMigration = "v15_notification_rules_and_opportunities"

  func testUpgradeAddsTheNewMigrationsInOrder() throws {
    let db = try makeV15Database()

    try DatabaseMigrations.migrate(db)

    let applied = try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
    XCTAssertEqual(
      Array(applied.suffix(3)),
      [
        "v17_cooking_portion_multiplier", "v18_cooking_history_swaps",
        "v19_grocery_amount_provenance",
      ])
  }

  func testExistingMealsSurviveUnchangedAsFullPortionsWithoutSwaps() throws {
    let db = try makeV15Database()
    let before = try meals(db)

    try DatabaseMigrations.migrate(db)

    XCTAssertEqual(try meals(db), before)
    let portions = try db.read {
      try Double.fetchAll($0, sql: "SELECT portion_multiplier FROM cooking_history ORDER BY id")
    }
    XCTAssertEqual(portions, [1.0, 1.0, 1.0])
    let swapCount = try db.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cooking_history_swaps")
    }
    XCTAssertEqual(swapCount, 0)
  }

  func testBackfillMarksExactlyThePhotoIntakeLots() throws {
    let db = try makeV15Database()

    try DatabaseMigrations.migrate(db)

    let flags = try db.read { db in
      try Row.fetchAll(db, sql: "SELECT id, quantity_is_estimate FROM inventory_lots ORDER BY id")
        .map { (row: Row) -> (Int64, Bool) in (row["id"], row["quantity_is_estimate"]) }
    }
    XCTAssertEqual(flags.map { $0.0 }, [1, 2, 3, 4, 5])
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: flags),
      [
        1: true,  // photo intake, untouched
        2: false,  // grocery update (user reviewed the amount)
        3: true,  // photo intake, partly cooked: remaining still derives from the guess
        4: false,  // manual add
        5: true,  // photo intake, used up
      ])
  }

  func testUpgradeKeepsEveryLotQuantityAndEvent() throws {
    let db = try makeV15Database()
    let lotsBefore = try lots(db)
    let eventsBefore = try eventCount(db)

    try DatabaseMigrations.migrate(db)

    XCTAssertEqual(try lots(db), lotsBefore)
    XCTAssertEqual(try eventCount(db), eventsBefore)
  }

  func testRerunningMigrationsDoesNotReMarkALotTheUserLaterSet() throws {
    let db = try makeV15Database()
    try DatabaseMigrations.migrate(db)
    try db.write { try $0.execute(sql: "UPDATE inventory_lots SET quantity_is_estimate = 0 WHERE id = 1") }

    try DatabaseMigrations.migrate(db)

    let flag = try db.read {
      try Bool.fetchOne($0, sql: "SELECT quantity_is_estimate FROM inventory_lots WHERE id = 1")
    }
    XCTAssertEqual(flag, false)
  }

  func testUpgradedMealsReportTheSameNutritionAsBefore() throws {
    let db = try makeV15Database()

    try DatabaseMigrations.migrate(db)

    // Meal 2: 1 of 2 servings of 100 g egg (140 kcal/100 g) + 200 g rice (130 kcal/100 g) = 200 kcal.
    // Meal 3: 2 of 2 servings = 400 kcal. Meal 1 has the old NULL timestamp and stays out of
    // dated reports, as before the upgrade; its true cooking time is unrecoverable.
    let journal = try UserDataRepository(db: db).cookingJournal()
    let caloriesByID = Dictionary(
      uniqueKeysWithValues: journal.map { ($0.id, $0.macrosConsumed.calories) })
    XCTAssertEqual(caloriesByID[2] ?? -1, 200, accuracy: 0.001)
    XCTAssertEqual(caloriesByID[3] ?? -1, 400, accuracy: 0.001)
    XCTAssertEqual(try UserDataRepository(db: db).todayMacros().calories, 600, accuracy: 0.001)
  }

  // MARK: - v15 fixture

  private func makeV15Database() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: lastShippedMigration)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'egg', 140, 12, 1, 10),
            (2, 'rice', 130, 2.7, 28, 0.3),
            (3, 'tomato', 18, 0.9, 3.9, 0.2);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Egg Fried Rice', 15, 2, 'Cook.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
            (1, 1, 1, 100, '2 eggs'),
            (1, 2, 1, 200, '1 cup');

          -- Meal 1 was saved by the old code path that left cooked_at NULL.
          INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed)
          VALUES (1, 1, NULL, 4, 1);
          INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed)
          VALUES (2, 1, CURRENT_TIMESTAMP, NULL, 1), (3, 1, CURRENT_TIMESTAMP, 5, 2);

          INSERT INTO inventory_lots
            (id, ingredient_id, quantity_grams, remaining_grams, storage_location, confidence_score, source)
          VALUES
            (1, 1, 50, 50, 'fridge', 0.9, 'scan'),
            (2, 2, 600, 600, 'pantry', 0.9, 'scan'),
            (3, 3, 240, 120, 'fridge', 0.8, 'scan'),
            (4, 3, 300, 300, 'fridge', 1.0, 'manual'),
            (5, 1, 50, 0, 'fridge', 0.9, 'scan');

          INSERT INTO inventory_events
            (ingredient_id, lot_id, event_type, quantity_delta_grams, reason, source_ref)
          VALUES
            (1, 1, 'add', 50, 'Scan-confirmed inventory intake', 'scan-review:a'),
            (2, 2, 'add', 600, 'Grocery update intake', 'grocery_update_b'),
            (3, 3, 'add', 240, 'Scan-confirmed inventory intake', 'scan-review:a'),
            (3, 3, 'consume', -120, 'Cooked meal consumption', 'recipe:1'),
            (3, 4, 'add', 300, NULL, NULL),
            (1, 5, 'add', 50, 'Scan-confirmed inventory intake', 'scan-review:c'),
            (1, 5, 'consume', -50, 'Cooked meal consumption', 'recipe:1');
          """
      )
    }
    return db
  }

  private struct MealSnapshot: Equatable {
    let id: Int64
    let cookedAt: String?
    let rating: Int?
    let servings: Int?
  }

  private func meals(_ db: DatabaseQueue) throws -> [MealSnapshot] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT id, cooked_at, rating, servings_consumed FROM cooking_history ORDER BY id"
      ).map {
        MealSnapshot(
          id: $0["id"], cookedAt: $0["cooked_at"], rating: $0["rating"],
          servings: $0["servings_consumed"])
      }
    }
  }

  private func lots(_ db: DatabaseQueue) throws -> [[Double]] {
    try db.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT id, ingredient_id, quantity_grams, remaining_grams FROM inventory_lots ORDER BY id"
      ).map { [$0["id"], $0["ingredient_id"], $0["quantity_grams"], $0["remaining_grams"]] }
    }
  }

  private func eventCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM inventory_events") ?? 0 }
  }
}
