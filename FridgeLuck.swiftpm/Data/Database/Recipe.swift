import Foundation
import GRDB

// MARK: - Recipe Tags (Bitmask)

struct RecipeTags: OptionSet, Sendable, Codable {
  let rawValue: Int

  static let quick = RecipeTags(rawValue: 1 << 0)
  static let vegetarian = RecipeTags(rawValue: 1 << 1)
  static let vegan = RecipeTags(rawValue: 1 << 2)
  static let asian = RecipeTags(rawValue: 1 << 3)
  static let breakfast = RecipeTags(rawValue: 1 << 4)
  static let budget = RecipeTags(rawValue: 1 << 5)
  static let comfort = RecipeTags(rawValue: 1 << 6)
  static let mediterranean = RecipeTags(rawValue: 1 << 7)
  static let mexican = RecipeTags(rawValue: 1 << 8)
  static let highProtein = RecipeTags(rawValue: 1 << 9)
  static let lowCarb = RecipeTags(rawValue: 1 << 10)
  static let onePot = RecipeTags(rawValue: 1 << 11)

  static let allTags: [(String, RecipeTags)] = [
    ("quick", .quick),
    ("vegetarian", .vegetarian),
    ("vegan", .vegan),
    ("asian", .asian),
    ("breakfast", .breakfast),
    ("budget", .budget),
    ("comfort", .comfort),
    ("mediterranean", .mediterranean),
    ("mexican", .mexican),
    ("high_protein", .highProtein),
    ("low_carb", .lowCarb),
    ("one_pot", .onePot),
  ]

  var labels: [String] {
    Self.allTags.compactMap { name, tag in
      self.contains(tag) ? name : nil
    }
  }
}

// MARK: - Recipe Source

enum RecipeSource: String, Codable, Sendable, DatabaseValueConvertible {
  case bundled
  case user
  case aiGenerated = "ai_generated"
}

// MARK: - Recipe

struct Recipe: Identifiable, Sendable, Codable {
  var id: Int64?
  var title: String
  var timeMinutes: Int
  var servings: Int
  var instructions: String
  var tags: Int
  var source: RecipeSource
  var createdAt: Date?

  var recipeTags: RecipeTags {
    RecipeTags(rawValue: tags)
  }
}

extension Recipe: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "recipes"

  enum Columns: String, ColumnExpression {
    case id, title
    case timeMinutes = "time_minutes"
    case servings, instructions, tags, source
    case createdAt = "created_at"
  }
}

// MARK: - Recipe Ingredient (Join Table)

struct RecipeIngredient: Sendable, Codable {
  var recipeId: Int64
  var ingredientId: Int64
  var isRequired: Bool
  var quantityGrams: Double
  var displayQuantity: String
}

extension RecipeIngredient: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "recipe_ingredients"

  enum Columns: String, ColumnExpression {
    case recipeId = "recipe_id"
    case ingredientId = "ingredient_id"
    case isRequired = "is_required"
    case quantityGrams = "quantity_grams"
    case displayQuantity = "display_quantity"
  }
}
