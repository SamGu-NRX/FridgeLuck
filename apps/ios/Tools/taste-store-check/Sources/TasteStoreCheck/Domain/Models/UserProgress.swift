import Foundation
import GRDB

// MARK: - Cooking History

struct CookingHistory: Identifiable, Sendable, Codable {
  var id: Int64?
  var recipeId: Int64
  var cookedAt: Date?
  var rating: Int?  // 1-5 stars, nil if unrated
  var imagePath: String?  // relative path in app documents
  var servingsConsumed: Int?  // how many servings the user ate
  var portionMultiplier: Double  // plate size relative to a full serving; 1.0 when not asked

  /// `cookedAt` is set here because GRDB encodes a nil optional as SQL NULL, which bypasses the
  /// column's CURRENT_TIMESTAMP default. NULL rows were counted in streaks but dropped from every
  /// dated query (today's nutrition, weekly history).
  init(
    recipeId: Int64,
    cookedAt: Date = Date(),
    rating: Int? = nil,
    imagePath: String? = nil,
    servingsConsumed: Int? = nil,
    portionMultiplier: Double = 1.0
  ) {
    self.recipeId = recipeId
    self.cookedAt = cookedAt
    self.portionMultiplier = portionMultiplier
    self.rating = rating
    self.imagePath = imagePath
    self.servingsConsumed = servingsConsumed
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recipeId = "recipe_id"
    case cookedAt = "cooked_at"
    case rating
    case imagePath = "image_path"
    case servingsConsumed = "servings_consumed"
    case portionMultiplier = "portion_multiplier"
  }
}

extension CookingHistory: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "cooking_history"

  enum Columns: String, ColumnExpression {
    case id
    case recipeId = "recipe_id"
    case cookedAt = "cooked_at"
    case rating
    case imagePath = "image_path"
    case servingsConsumed = "servings_consumed"
    case portionMultiplier = "portion_multiplier"
  }
}

// MARK: - Badge

struct Badge: Identifiable, Sendable, Codable {
  var id: String
  var earnedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case earnedAt = "earned_at"
  }
}

extension Badge: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "badges"

  enum Columns: String, ColumnExpression {
    case id
    case earnedAt = "earned_at"
  }
}

// MARK: - Streak

struct Streak: Sendable, Codable {
  var date: String  // ISO format: "2026-02-08"
  var mealsCookedCount: Int

  enum CodingKeys: String, CodingKey {
    case date
    case mealsCookedCount = "meals_cooked"
  }
}

extension Streak: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "streaks"

  enum Columns: String, ColumnExpression {
    case date
    case mealsCookedCount = "meals_cooked"
  }
}

// MARK: - User Correction

struct UserCorrection: Identifiable, Sendable, Codable {
  var id: Int64?
  var visionLabel: String
  var correctedIngredientId: Int64
  var correctionCount: Int
  var lastUsedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case visionLabel = "vision_label"
    case correctedIngredientId = "corrected_ingredient_id"
    case correctionCount = "correction_count"
    case lastUsedAt = "last_used_at"
  }
}

extension UserCorrection: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "user_corrections"

  enum Columns: String, ColumnExpression {
    case id
    case visionLabel = "vision_label"
    case correctedIngredientId = "corrected_ingredient_id"
    case correctionCount = "correction_count"
    case lastUsedAt = "last_used_at"
  }
}
