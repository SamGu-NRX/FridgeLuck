import GRDB
import XCTest

@testable import FridgeLuck

/// Mirrors the hosted NutritionReportingTests fixture: a meal inserted directly
/// by SQL must capture its nutrition snapshot in the same fixture transaction —
/// the strict read path serves history macros only from frozen snapshots.
final class FixtureSnapshotTests: XCTestCase {
  func testDirectFixtureInsertWithCapturedSnapshotFeedsCapturedMacros() throws {
    let queue = try DatabaseQueue()
    try DatabaseMigrations.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Required and optional', 10, 4, 'Cook.');
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (1, 'Required', 200, 20, 30, 8), (2, 'Optional', 400, 12, 16, 20);
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (1, 1, 1, 200, '200 g'), (1, 2, 0, 100, '100 g');
          INSERT INTO cooking_history (recipe_id, cooked_at, servings_consumed)
          VALUES (1, CURRENT_TIMESTAMP, 1);
          """
      )
      try NutritionSnapshotService(db: queue).captureSnapshot(
        in: db, historyId: db.lastInsertedRowID, recipeId: 1)
    }

    // Recipe total: 200 g required at 200 kcal / 20 g protein per 100 g, over
    // four servings, with the meal's 1-of-4 servings factor applied — optional
    // ingredients are excluded from the snapshot.
    let macros = try NutritionSnapshotService(db: queue).capturedMacros(historyId: 1)
    XCTAssertEqual(macros.caloriesPerServing, 100, accuracy: 0.001)
    XCTAssertEqual(macros.proteinPerServing, 10, accuracy: 0.001)
    XCTAssertEqual(macros.carbsPerServing, 15, accuracy: 0.001)
    XCTAssertEqual(macros.fatPerServing, 4, accuracy: 0.001)

    // A row without a snapshot still fails loudly (the fixture discipline).
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO cooking_history (recipe_id, cooked_at, servings_consumed)
          VALUES (1, CURRENT_TIMESTAMP, 1)
          """
      )
    }
    XCTAssertThrowsError(
      try NutritionSnapshotService(db: queue).capturedMacros(historyId: 2)
    )
  }
}
