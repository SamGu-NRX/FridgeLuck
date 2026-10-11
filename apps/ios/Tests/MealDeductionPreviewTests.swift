import GRDB
import XCTest

@testable import FridgeLuck

/// The meal-photo deduction preview and its "Deduct N items" count must match what logging the
/// same recipe takes out of the same Kitchen.
final class MealDeductionPreviewTests: XCTestCase {
  func testPreviewMatchesWhatLoggingConsumes() throws {
    let db = try makeDatabase()
    let inventory = InventoryRepository(db: db)
    // Rice is short, egg is plentiful in two lots, scallion is out of stock, and soy sauce is
    // optional, so the log leaves it alone.
    for (id, grams) in [(1, 100.0), (2, 40.0), (2, 200.0), (4, 50.0)] {
      try inventory.addLot(
        ingredientId: Int64(id), quantityGrams: grams, location: .fridge, confidenceScore: 1,
        source: .manual)
    }

    let previews = try inventory.previewConsumption(
      recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.4)
    let outcome = try makeMealLogService(db: db, inventory: inventory).logMeal(
      recipe: try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) }),
      imagePath: nil, servingsConsumed: 1, portionMultiplier: 1.4)

    let consumed = outcome.inventoryConsumption.filter { $0.consumedGrams > 0 }
    XCTAssertEqual(previews.map(\.ingredientId), consumed.map(\.ingredientId))
    XCTAssertEqual(previews.map(\.ingredientId), [1, 2])
    for (preview, result) in zip(previews, consumed) {
      XCTAssertEqual(preview.deductedGrams, result.consumedGrams, accuracy: 0.001)
      XCTAssertEqual(preview.proposedGrams, result.requestedGrams, accuracy: 0.001)
    }
    // Recipe serves 2, so one large (1.4x) serving asks for 0.7 of each amount.
    XCTAssertEqual(previews[0].deductedGrams, 100, accuracy: 0.001)
    XCTAssertTrue(previews[0].hasShortfall)
    XCTAssertEqual(previews[1].deductedGrams, 70, accuracy: 0.001)
  }

  func testEmptyKitchenPreviewsNothing() throws {
    let db = try makeDatabase()
    XCTAssertTrue(
      try InventoryRepository(db: db).previewConsumption(recipeId: 1, servingsConsumed: 1)
        .isEmpty)
  }

  func testBreakdownUsesTheSameScaling() {
    XCTAssertEqual(
      InventoryRepository.servingFactor(
        servingsConsumed: 1, portionMultiplier: 1.4, recipeServings: 2),
      0.7, accuracy: 0.0001)
  }

  private func makeMealLogService(db: DatabaseQueue, inventory: InventoryRepository)
    -> MealLogService
  {
    let nutrition = NutritionService(db: db)
    let personalization = PersonalizationService(db: db)
    return MealLogService(
      db: db,
      recipeRepository: RecipeRepository(
        db: db,
        nutritionService: nutrition,
        healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
        personalizationService: personalization
      ),
      personalizationService: personalization,
      inventoryRepository: inventory,
      imageStorageService: ImageStorageService()
    )
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (1, 'cooked_rice', 130, 2.7, 28, 0.3),
            (2, 'egg', 155, 13, 1.1, 11),
            (3, 'scallion', 32, 1.8, 7, 0.2),
            (4, 'soy_sauce', 53, 8, 4.9, 0.6);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (1, 'Egg Fried Rice', 15, 2, 'Fry.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES
            (1, 1, 1, 300, '300 g'),
            (1, 2, 1, 100, '2 eggs'),
            (1, 3, 1, 20, '2 stalks'),
            (1, 4, 0, 15, '1 tbsp');
          """
      )
    }
    return db
  }
}
