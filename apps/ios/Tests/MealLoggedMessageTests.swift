import GRDB
import XCTest

@testable import FridgeLuck

/// The "Meal logged" alert says the Kitchen changed only when the log took something out of it.
final class MealLoggedMessageTests: XCTestCase {
  private func result(consumed: Double, requested: Double = 100) -> InventoryConsumptionResult {
    InventoryConsumptionResult(
      ingredientId: 1, requestedGrams: requested, consumedGrams: consumed,
      shortfallGrams: max(0, requested - consumed))
  }

  func testCountsOnlyIngredientsThatCameOut() {
    XCTAssertEqual(
      MealLoggedMessage.text(for: [result(consumed: 40), result(consumed: 0), result(consumed: 100)]
      ),
      "Your meal has been recorded, and 2 ingredients came out of your Kitchen.")
  }

  func testSingularIngredient() {
    XCTAssertEqual(
      MealLoggedMessage.text(for: [result(consumed: 30)]),
      "Your meal has been recorded, and 1 ingredient came out of your Kitchen.")
  }

  func testNothingInStockSaysNothingCameOut() {
    XCTAssertEqual(
      MealLoggedMessage.text(for: [result(consumed: 0), result(consumed: 0)]),
      "Your meal has been recorded. None of its ingredients were in your Kitchen, so nothing came out."
    )
  }

  func testRecipeWithoutIngredientsSaysKitchenUnchanged() {
    XCTAssertEqual(
      MealLoggedMessage.text(for: []),
      "Your meal has been recorded. This recipe has no ingredient list, so your Kitchen didn't change."
    )
  }

  /// The walk's case: logging a recipe whose ingredients aren't in the Kitchen.
  func testLoggingWithAnEmptyKitchenReportsNothingCameOut() throws {
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

    let consumption = try InventoryRepository(db: db).applyConsumption(
      recipeId: 1, servingsConsumed: 1)

    XCTAssertEqual(
      MealLoggedMessage.text(for: consumption),
      "Your meal has been recorded. None of its ingredients were in your Kitchen, so nothing came out."
    )
  }
}
