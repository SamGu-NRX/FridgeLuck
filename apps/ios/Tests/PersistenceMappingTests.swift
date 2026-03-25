import Foundation
import GRDB
import XCTest

final class PersistenceMappingTests: XCTestCase {
  private struct RecipeRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "recipes"

    var id: Int64?
    var title: String
    var timeMinutes: Int
    var servings: Int
    var instructions: String
    var tags: Int
    var source: String
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
      case id
      case title
      case timeMinutes = "time_minutes"
      case servings
      case instructions
      case tags
      case source
      case createdAt = "created_at"
    }
  }

  private struct CookingHistoryRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "cooking_history"

    var id: Int64?
    var recipeId: Int64
    var cookedAt: Date?
    var rating: Int?
    var imagePath: String?
    var servingsConsumed: Int?

    enum CodingKeys: String, CodingKey {
      case id
      case recipeId = "recipe_id"
      case cookedAt = "cooked_at"
      case rating
      case imagePath = "image_path"
      case servingsConsumed = "servings_consumed"
    }
  }

  private struct StreakRow: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "streaks"

    var date: String
    var mealsCookedCount: Int

    enum CodingKeys: String, CodingKey {
      case date
      case mealsCookedCount = "meals_cooked"
    }
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(
        sql: """
          CREATE TABLE recipes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            time_minutes INTEGER NOT NULL,
            servings INTEGER NOT NULL,
            instructions TEXT NOT NULL,
            tags INTEGER DEFAULT 0,
            source TEXT DEFAULT 'bundled',
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
          )
          """
      )
      try db.execute(
        sql: """
          CREATE TABLE cooking_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recipe_id INTEGER NOT NULL REFERENCES recipes(id),
            cooked_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            rating INTEGER,
            image_path TEXT,
            servings_consumed INTEGER
          )
          """
      )
      try db.execute(
        sql: """
          CREATE TABLE streaks (
            date TEXT PRIMARY KEY,
            meals_cooked INTEGER DEFAULT 0
          )
          """
      )
    }
    return dbQueue
  }

  func testSnakeCaseRoundTripPersistsWithExplicitCodingKeys() throws {
    let dbQueue = try makeDatabase()

    let recipeID = try dbQueue.write { db in
      let recipe = RecipeRow(
        id: nil,
        title: "Classic Egg Fried Rice",
        timeMinutes: 15,
        servings: 2,
        instructions: "Cook and serve.",
        tags: 0,
        source: "bundled",
        createdAt: Date()
      )
      try recipe.insert(db)
      return db.lastInsertedRowID
    }

    try dbQueue.write { db in
      let history = CookingHistoryRow(
        id: nil,
        recipeId: recipeID,
        cookedAt: Date(),
        rating: 5,
        imagePath: "photos/meal.jpg",
        servingsConsumed: 1
      )
      try history.insert(db)

      let streak = StreakRow(date: "2030-01-01", mealsCookedCount: 1)
      try streak.insert(db)
    }

    try dbQueue.read { db in
      let recipe = try RecipeRow.fetchOne(db, key: recipeID)
      XCTAssertEqual(recipe?.timeMinutes, 15)

      let history = try CookingHistoryRow.fetchOne(
        db,
        sql: "SELECT * FROM cooking_history WHERE recipe_id = ? LIMIT 1",
        arguments: [recipeID]
      )
      XCTAssertEqual(history?.recipeId, recipeID)
      XCTAssertEqual(history?.imagePath, "photos/meal.jpg")
      XCTAssertEqual(history?.servingsConsumed, 1)

      let streak = try StreakRow.fetchOne(db, key: "2030-01-01")
      XCTAssertEqual(streak?.mealsCookedCount, 1)
    }
  }

  func testCamelCaseColumnsFailAgainstSnakeCaseSchema() throws {
    let dbQueue = try makeDatabase()

    let recipeID = try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source)
          VALUES ('Classic Egg Fried Rice', 15, 2, 'Cook and serve.', 0, 'bundled')
          """
      )
      return db.lastInsertedRowID
    }

    XCTAssertThrowsError(
      try dbQueue.write { db in
        try db.execute(
          sql: """
            INSERT INTO cooking_history (recipeId, cookedAt, rating, imagePath, servingsConsumed)
            VALUES (?, CURRENT_TIMESTAMP, ?, ?, ?)
            """,
          arguments: [recipeID, 5, "photos/meal.jpg", 1]
        )
      }
    )

    XCTAssertThrowsError(
      try dbQueue.write { db in
        try db.execute(
          sql: "INSERT INTO streaks (date, mealsCookedCount) VALUES ('2030-01-01', 1)"
        )
      }
    )
  }

  func testAppModelsDeclareRequiredSnakeCaseCodingKeys() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let recipeModels = try String(
      contentsOf: root.appendingPathComponent("Domain/Models/Recipe.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(recipeModels.contains("case timeMinutes = \"time_minutes\""))
    XCTAssertTrue(recipeModels.contains("case createdAt = \"created_at\""))
    XCTAssertTrue(recipeModels.contains("case recipeId = \"recipe_id\""))
    XCTAssertTrue(recipeModels.contains("case displayQuantity = \"display_quantity\""))

    let ingredientModels = try String(
      contentsOf: root.appendingPathComponent("Domain/Models/Ingredient.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(ingredientModels.contains("case typicalUnit = \"typical_unit\""))
    XCTAssertTrue(ingredientModels.contains("case storageTip = \"storage_tip\""))
    XCTAssertTrue(ingredientModels.contains("case pairsWith = \"pairs_with\""))
    XCTAssertTrue(ingredientModels.contains("case categoryLabel = \"category_label\""))
    XCTAssertTrue(ingredientModels.contains("case spriteGroup = \"sprite_group\""))
    XCTAssertTrue(ingredientModels.contains("case spriteKey = \"sprite_key\""))

    let healthProfileModels = try String(
      contentsOf: root.appendingPathComponent("Domain/Models/HealthProfile.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(healthProfileModels.contains("case displayName = \"display_name\""))
    XCTAssertTrue(healthProfileModels.contains("case age"))

    let dishTemplateModels = try String(
      contentsOf: root.appendingPathComponent("Domain/Models/DishTemplate.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(dishTemplateModels.contains("case baseCalories = \"base_calories\""))
    XCTAssertTrue(dishTemplateModels.contains("case baseProtein = \"base_protein\""))
    XCTAssertTrue(dishTemplateModels.contains("case baseCarbs = \"base_carbs\""))
    XCTAssertTrue(dishTemplateModels.contains("case baseFat = \"base_fat\""))

    let userProgressModels = try String(
      contentsOf: root.appendingPathComponent("Domain/Models/UserProgress.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(userProgressModels.contains("case recipeId = \"recipe_id\""))
    XCTAssertTrue(userProgressModels.contains("case cookedAt = \"cooked_at\""))
    XCTAssertTrue(userProgressModels.contains("case imagePath = \"image_path\""))
    XCTAssertTrue(userProgressModels.contains("case servingsConsumed = \"servings_consumed\""))
    XCTAssertTrue(userProgressModels.contains("case earnedAt = \"earned_at\""))
    XCTAssertTrue(userProgressModels.contains("case mealsCookedCount = \"meals_cooked\""))
    XCTAssertTrue(userProgressModels.contains("case visionLabel = \"vision_label\""))
    XCTAssertTrue(
      userProgressModels.contains("case correctedIngredientId = \"corrected_ingredient_id\""))
    XCTAssertTrue(userProgressModels.contains("case correctionCount = \"correction_count\""))
    XCTAssertTrue(userProgressModels.contains("case lastUsedAt = \"last_used_at\""))
  }

  func testInventoryModelsDeclareRequiredSnakeCaseCodingKeys() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let inventoryModels = try String(
      contentsOf: root.appendingPathComponent("Domain/Models/Inventory.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(inventoryModels.contains("case ingredientId = \"ingredient_id\""))
    XCTAssertTrue(inventoryModels.contains("case fridgeDays = \"fridge_days\""))
    XCTAssertTrue(inventoryModels.contains("case pantryDays = \"pantry_days\""))
    XCTAssertTrue(inventoryModels.contains("case freezerDays = \"freezer_days\""))
    XCTAssertTrue(inventoryModels.contains("case quantityGrams = \"quantity_grams\""))
    XCTAssertTrue(inventoryModels.contains("case remainingGrams = \"remaining_grams\""))
    XCTAssertTrue(inventoryModels.contains("case storageLocation = \"storage_location\""))
    XCTAssertTrue(inventoryModels.contains("case confidenceScore = \"confidence_score\""))
    XCTAssertTrue(inventoryModels.contains("case acquiredAt = \"acquired_at\""))
    XCTAssertTrue(inventoryModels.contains("case expiresAt = \"expires_at\""))
    XCTAssertTrue(inventoryModels.contains("case eventType = \"event_type\""))
    XCTAssertTrue(inventoryModels.contains("case quantityDeltaGrams = \"quantity_delta_grams\""))
    XCTAssertTrue(inventoryModels.contains("case sourceRef = \"source_ref\""))
    XCTAssertTrue(inventoryModels.contains("case totalRemainingGrams = \"total_remaining_grams\""))
    XCTAssertTrue(
      inventoryModels.contains("case averageConfidenceScore = \"average_confidence_score\""))
    XCTAssertTrue(inventoryModels.contains("case lastUpdatedAt = \"last_updated_at\""))
  }

  func testMigrationsDeclareInventoryTables() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let migrations = try String(
      contentsOf: root.appendingPathComponent("Platform/Persistence/Database/Migrations.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(migrations.contains("v9_smart_fridge_inventory"))
    XCTAssertTrue(migrations.contains("ingredient_shelf_life_profiles"))
    XCTAssertTrue(migrations.contains("inventory_lots"))
    XCTAssertTrue(migrations.contains("inventory_events"))
    XCTAssertTrue(migrations.contains("inventory_items"))
    XCTAssertTrue(migrations.contains("v10_confidence_learning"))
    XCTAssertTrue(migrations.contains("confidence_signal_events"))
    XCTAssertTrue(migrations.contains("trust_vector_state"))
    XCTAssertTrue(migrations.contains("v12_required_onboarding_identity"))
    XCTAssertTrue(migrations.contains("display_name"))
    XCTAssertTrue(migrations.contains("age"))
  }
}
