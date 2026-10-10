import GRDB
import XCTest

@testable import FridgeLuck

final class NutritionReportingTests: XCTestCase {
  func testTodayMacrosExcludeOptionalIngredients() throws {
    let db = try makeDatabase(servingsConsumed: 1)
    assertMacros(try UserDataRepository(db: db).todayMacros(), servings: 1)
    try assertMatchesPreview(try UserDataRepository(db: db).todayMacros(), db: db)
  }

  func testJournalMacrosExcludeOptionalIngredients() throws {
    let db = try makeDatabase(servingsConsumed: 1)
    let journal = try UserDataRepository(db: db).cookingJournal()
    XCTAssertEqual(journal.count, 1)
    let entry = try XCTUnwrap(journal.first)
    assertMacros(entry.macrosConsumed, servings: 1)
    try assertMatchesPreview(entry.macrosConsumed, db: db)
  }

  func testDailyMacrosExcludeOptionalIngredients() throws {
    let db = try makeDatabase(servingsConsumed: 1)
    let point = try XCTUnwrap(UserDataRepository(db: db).dailyMacroTotals(lastDays: 1).first)
    let macros = MacroTotals(
      calories: point.calories, protein: point.protein, carbs: point.carbs, fat: point.fat
    )
    assertMacros(macros, servings: 1)
    try assertMatchesPreview(macros, db: db)
  }

  func testConsumedServingsScalingAndNullFallbackStayConsistent() throws {
    for consumed: Int? in [3, nil] {
      let db = try makeDatabase(servingsConsumed: consumed)
      let repository = UserDataRepository(db: db)
      let expectedServings = Double(consumed ?? 4)
      assertMacros(try repository.todayMacros(), servings: expectedServings)
      let entry = try XCTUnwrap(repository.cookingJournal().first)
      XCTAssertEqual(entry.servingsConsumed, consumed ?? 4)
      assertMacros(entry.macrosConsumed, servings: expectedServings)
      let point = try XCTUnwrap(repository.dailyMacroTotals(lastDays: 1).first)
      assertMacros(
        MacroTotals(calories: point.calories, protein: point.protein, carbs: point.carbs, fat: point.fat),
        servings: expectedServings
      )
    }
  }

  private func makeDatabase(servingsConsumed: Int?) throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try DatabaseMigrations.migrate(queue)
    try queue.write { db in
      try db.execute(sql: """
        INSERT INTO recipes (id, title, time_minutes, servings, instructions)
        VALUES (1, 'Required and optional', 10, 4, 'Cook.');
        INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
        VALUES (1, 'Required', 200, 20, 30, 8), (2, 'Optional', 400, 12, 16, 20);
        INSERT INTO recipe_ingredients
          (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
        VALUES (1, 1, 1, 200, '200 g'), (1, 2, 0, 100, '100 g');
        """)
      try db.execute(
        sql: """
          INSERT INTO cooking_history (recipe_id, cooked_at, servings_consumed)
          VALUES (1, CURRENT_TIMESTAMP, ?)
          """,
        arguments: [servingsConsumed]
      )
      // v20 reporting reads only through completed snapshots, captured in the
      // same transaction the meal is logged in — mirror recordCooking here.
      let historyId = try Int64.fetchOne(
        db, sql: "SELECT last_insert_rowid()")!
      try NutritionSnapshotService(db: queue).captureSnapshot(
        in: db,
        historyId: historyId,
        recipeId: 1
      )
    }
    return queue
  }

  private func assertMacros(
    _ macros: MacroTotals, servings: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // Required ingredient: 200 g at 200/20/30/8 per 100 g, divided into four servings.
    XCTAssertEqual(macros.calories, 100 * servings, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(macros.protein, 10 * servings, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(macros.carbs, 15 * servings, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(macros.fat, 4 * servings, accuracy: 0.0001, file: file, line: line)
  }

  private func assertMatchesPreview(
    _ macros: MacroTotals, db: DatabaseQueue,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let preview = try NutritionService(db: db).macros(for: 1)
    XCTAssertEqual(macros.calories, preview.caloriesPerServing, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(macros.protein, preview.proteinPerServing, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(macros.carbs, preview.carbsPerServing, accuracy: 0.0001, file: file, line: line)
    XCTAssertEqual(macros.fat, preview.fatPerServing, accuracy: 0.0001, file: file, line: line)
  }
}
