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

  init(recipeId: Int64, rating: Int? = nil, imagePath: String? = nil, servingsConsumed: Int? = nil)
  {
    self.recipeId = recipeId
    self.rating = rating
    self.imagePath = imagePath
    self.servingsConsumed = servingsConsumed
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
  }
}

// MARK: - Badge

struct Badge: Identifiable, Sendable, Codable {
  var id: String
  var earnedAt: Date?
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
