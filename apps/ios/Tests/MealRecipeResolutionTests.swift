import GRDB
import XCTest

@testable import FridgeLuck

/// The meal-photo screen shows, previews and logs one recipe. Logging moves an ingredientless
/// recipe onto a same-title recipe that has ingredients, so the screen must resolve it the same
/// way before it previews anything.
final class MealRecipeResolutionTests: XCTestCase {
  func testChoosingAnIngredientlessRecipePreviewsAndLogsItsIngredientBackedTwin() throws {
    let db = try makeDatabase()
    let inventory = InventoryRepository(db: db)
    try inventory.addLot(
      ingredientId: 1, quantityGrams: 500, location: .fridge, confidenceScore: 1, source: .manual)
    let recipes = makeRecipeRepository(db: db)
    let chosen = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })

    let resolved = try XCTUnwrap(try recipes.resolveForLogging(chosen))
    XCTAssertEqual(resolved.recipe.id, 2)
    XCTAssertEqual(resolved.macros.caloriesPerServing, 260, accuracy: 0.001)

    let previews = try inventory.previewConsumption(
      recipeId: try XCTUnwrap(resolved.recipe.id), servingsConsumed: 1)
    let outcome = try MealLogService(
      db: db, recipeRepository: recipes, personalizationService: PersonalizationService(db: db),
      inventoryRepository: inventory, imageStorageService: ImageStorageService()
    ).logMeal(recipe: resolved.recipe, imagePath: nil, servingsConsumed: 1)

    XCTAssertEqual(outcome.recipeId, 2)
    XCTAssertEqual(previews.map(\.ingredientId), outcome.inventoryConsumption.map(\.ingredientId))
    XCTAssertEqual(
      try XCTUnwrap(previews.first).deductedGrams,
      try XCTUnwrap(outcome.inventoryConsumption.first).consumedGrams, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(previews.first).deductedGrams, 200, accuracy: 0.001)
  }

  /// Logging keeps its own recovery: passing the ingredientless recipe still lands on the twin.
  func testLoggingTheIngredientlessRecipeStillRecoversTheTwin() throws {
    let db = try makeDatabase()
    let recipes = makeRecipeRepository(db: db)
    let chosen = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })

    let outcome = try MealLogService(
      db: db, recipeRepository: recipes, personalizationService: PersonalizationService(db: db),
      inventoryRepository: InventoryRepository(db: db), imageStorageService: ImageStorageService()
    ).logMeal(recipe: chosen, imagePath: nil, servingsConsumed: 1)

    XCTAssertEqual(outcome.recipeId, 2)
  }

  func testRecipeWithIngredientsResolvesToItself() throws {
    let db = try makeDatabase()
    let twin = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 2) })
    XCTAssertEqual(try makeRecipeRepository(db: db).resolveForLogging(twin)?.recipe.id, 2)
  }

  func testUnsavedRecipeWithANewTitleDoesNotResolve() throws {
    let db = try makeDatabase()
    let unsaved = Recipe(
      id: nil, title: "Something New", timeMinutes: 5, servings: 1, instructions: "Mix.",
      tags: 0, source: .aiGenerated)
    XCTAssertNil(try makeRecipeRepository(db: db).resolveForLogging(unsaved))
    XCTAssertEqual(try db.read { try Recipe.fetchCount($0) }, 2, "resolving must not insert")
  }

  private func makeRecipeRepository(db: DatabaseQueue) -> RecipeRepository {
    let nutrition = NutritionService(db: db)
    return RecipeRepository(
      db: db,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: PersonalizationService(db: db)
    )
  }

  /// Recipe 1 has no ingredient rows; recipe 2 shares its title and has 200 g of rice.
  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
          VALUES (1, 'cooked_rice', 130, 2.7, 28, 0.3);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
            (1, 'Egg Fried Rice', 15, 1, 'Fry.'),
            (2, 'Egg Fried Rice', 15, 1, 'Fry.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (2, 1, 1, 200, '200 g');
          """
      )
    }
    return db
  }
}
