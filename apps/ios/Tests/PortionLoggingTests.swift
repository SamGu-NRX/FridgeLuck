import GRDB
import XCTest

@testable import FridgeLuck

/// The meal-photo screen lets the user say the plate was small (~70%) or large (~140%).
/// What gets logged must match what the user confirmed on screen.
final class PortionLoggingTests: XCTestCase {
  func testSmallPortionScalesEveryNutritionReport() throws {
    let db = try makeDatabase()
    try PersonalizationService(db: db).recordCooking(
      recipeId: 1, servingsConsumed: 1, portionMultiplier: 0.7)
    let reports = UserDataRepository(db: db)

    XCTAssertEqual(try reports.todayMacros().calories, 140, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(reports.cookingJournal().first).macrosConsumed.calories, 140, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(reports.dailyMacroTotals(lastDays: 1).first).calories, 140, accuracy: 0.001)
  }

  func testMealsLoggedBeforeThePortionColumnCountAsFullPortions() throws {
    let db = try makeDatabase()
    try PersonalizationService(db: db).recordCooking(recipeId: 1, servingsConsumed: 1)

    XCTAssertEqual(try UserDataRepository(db: db).todayMacros().calories, 200, accuracy: 0.001)
  }

  func testLargePortionDeductsMoreInventory() throws {
    let db = try makeDatabase()
    let inventory = InventoryRepository(db: db)
    try inventory.addLot(
      ingredientId: 1, quantityGrams: 200, location: .fridge, confidenceScore: 1, source: .manual)

    let results = try inventory.applyConsumption(
      recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.4)

    XCTAssertEqual(try XCTUnwrap(results.first).consumedGrams, 140, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(inventory.fetchAllActiveItems().first).totalRemainingGrams, 60, accuracy: 0.001)
  }

  /// One serving recipe: 100 g of an ingredient with 200 kcal per 100 g.
  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (1, 'test rice', 200, 4, 40, 1);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Test Rice', 10, 1, 'Cook.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (1, 1, 1, 100, '100 g');
          """
      )
    }
    return db
  }
}
