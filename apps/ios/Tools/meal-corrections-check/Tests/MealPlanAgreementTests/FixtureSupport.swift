import GRDB
@testable import FridgeLuck

/// Shared fixture for the meal-plan agreement checks: an in-memory GRDB database with the
/// same inline-SQL shape the app's own test suite uses.
enum PlanFixture {
  /// Ingredients: 1 rice, 2 egg, 3 scallion, 4 soy sauce (optional in the recipe).
  /// Recipe 1 "Egg Fried Rice" serves 2 (300 g rice, 100 g egg, 20 g scallion, 15 g soy).
  /// Recipe 2 "Plain Eggs" serves 1 (100 g egg).
  static func makeDatabase() throws -> DatabaseQueue {
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
          INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
            (1, 'Egg Fried Rice', 15, 2, 'Fry.'),
            (2, 'Plain Eggs', 10, 1, 'Boil.');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES
            (1, 1, 1, 300, '300 g'),
            (1, 2, 1, 100, '2 eggs'),
            (1, 3, 1, 20, '2 stalks'),
            (1, 4, 0, 15, '1 tbsp'),
            (2, 2, 1, 100, '2 eggs');
          """
      )
    }
    return db
  }

  static func makeMealLogService(db: DatabaseQueue, inventory: InventoryRepository)
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
      inventoryRepository: inventory
    )
  }

  /// Stock per ingredient id: rice plentiful, egg plentiful, scallion out of stock.
  static func stock(
    _ inventory: InventoryRepository, pairs: [(Int64, Double)]
  ) throws {
    for (id, grams) in pairs {
      try inventory.addLot(
        ingredientId: id, quantityGrams: grams, location: .fridge, confidenceScore: 1,
        source: .manual)
    }
  }

  static func historyCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cooking_history") ?? 0 }
  }

  static func eventCount(_ db: DatabaseQueue) throws -> Int {
    try db.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM inventory_events WHERE event_type = 'consume'")
        ?? 0
    }
  }

  /// Deducted grams per ingredient from the log's `consume` events, reported positive
  /// (the table stores consumption as negative deltas). Fixture `add` events are excluded.
  static func eventGramsByIngredient(_ db: DatabaseQueue) throws -> [Int64: Double] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ingredient_id, SUM(quantity_delta_grams) g FROM inventory_events
          WHERE event_type = 'consume' GROUP BY ingredient_id
          """)
      var byId: [Int64: Double] = [:]
      for row in rows {
        let id: Int64 = row["ingredient_id"]
        byId[id] = -(row["g"] as Double? ?? 0)
      }
      return byId
    }
  }

  static func acceptedRow(_ db: DatabaseQueue, historyId: Int64) throws -> Row? {
    try db.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT accepted_plan_json, accepted_plan_identity FROM cooking_history WHERE id = ?",
        arguments: [historyId])
    }
  }
}
