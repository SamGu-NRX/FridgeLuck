import GRDB
import XCTest

@testable import FridgeLuck

/// Swapping chicken for tofu while cooking must log tofu: tofu's nutrition in every report and
/// in the celebration/Apple Health macros, and tofu taken out of the Kitchen.
final class SwapLoggingTests: XCTestCase {
  private let chicken: Int64 = 1
  private let tofu: Int64 = 2
  private lazy var tofuForChicken = IngredientSwap(
    originalIngredientId: chicken, substituteIngredientId: tofu, ratio: 1.5)

  func testReportsUseTheSubstituteAtItsRatio() throws {
    let db = try makeDatabase()
    try PersonalizationService(db: db).recordCooking(
      recipeId: 1, servingsConsumed: 1, swaps: [tofuForChicken])
    let reports = UserDataRepository(db: db)

    // 100 g chicken becomes 150 g tofu at 80 kcal/100 g.
    XCTAssertEqual(try reports.todayMacros().calories, 120, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(reports.cookingJournal().first).macrosConsumed.calories, 120, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(reports.dailyMacroTotals(lastDays: 1).first).calories, 120, accuracy: 0.001)
  }

  func testSwapsBelongToOneMealOnly() throws {
    let db = try makeDatabase()
    let personalization = PersonalizationService(db: db)
    try personalization.recordCooking(recipeId: 1, servingsConsumed: 1, swaps: [tofuForChicken])
    try personalization.recordCooking(recipeId: 1, servingsConsumed: 1)

    // 120 kcal (tofu meal) + 165 kcal (chicken meal).
    XCTAssertEqual(try UserDataRepository(db: db).todayMacros().calories, 285, accuracy: 0.001)
  }

  func testPreviewAndHealthMacrosUseTheSubstitute() throws {
    let db = try makeDatabase()
    let nutrition = NutritionService(db: db)

    XCTAssertEqual(try nutrition.macros(for: 1).caloriesPerServing, 165, accuracy: 0.001)
    XCTAssertEqual(
      try nutrition.macros(for: 1, swaps: [tofuForChicken]).caloriesPerServing, 120,
      accuracy: 0.001)
  }

  func testConsumptionTakesTheSubstituteFromTheKitchen() throws {
    let db = try makeDatabase()
    let inventory = InventoryRepository(db: db)
    try inventory.addLot(
      ingredientId: chicken, quantityGrams: 300, location: .fridge, confidenceScore: 1,
      source: .manual)
    try inventory.addLot(
      ingredientId: tofu, quantityGrams: 400, location: .fridge, confidenceScore: 1,
      source: .manual)

    _ = try inventory.applyConsumption(recipeId: 1, servingsConsumed: 1, swaps: [tofuForChicken])

    let remaining = Dictionary(
      uniqueKeysWithValues: try inventory.fetchAllActiveItems().map {
        ($0.ingredientId, $0.totalRemainingGrams)
      })
    XCTAssertEqual(remaining[chicken] ?? 0, 300, accuracy: 0.001)
    XCTAssertEqual(remaining[tofu] ?? 0, 250, accuracy: 0.001)
  }

  func testSwapOfANonRequiredIngredientIsRejectedLoudly() throws {
    let db = try makeDatabase()
    let optionalSwap = IngredientSwap(
      originalIngredientId: 99, substituteIngredientId: tofu, ratio: 1)

    XCTAssertThrowsError(
      try PersonalizationService(db: db).recordCooking(
        recipeId: 1, servingsConsumed: 1, swaps: [optionalSwap]))
    XCTAssertEqual(
      try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cooking_history") }, 0)
  }

  /// One-serving recipe: 100 g chicken (165 kcal/100 g). Tofu is 80 kcal/100 g.
  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'chicken breast', 165, 31, 0, 3.6),
            (2, 'tofu', 80, 8, 2, 4.8);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Test Stir Fry', 15, 1, 'Cook.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (1, 1, 1, 100, '100 g');
          """
      )
    }
    return db
  }
}
