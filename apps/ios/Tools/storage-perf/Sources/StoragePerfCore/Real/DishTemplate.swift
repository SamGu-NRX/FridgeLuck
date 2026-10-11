import Foundation
import GRDB

struct DishTemplate: Identifiable, Sendable, Codable {
  var id: Int64?
  var name: String
  var baseCalories: Double
  var baseProtein: Double
  var baseCarbs: Double
  var baseFat: Double
  var notes: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case baseCalories = "base_calories"
    case baseProtein = "base_protein"
    case baseCarbs = "base_carbs"
    case baseFat = "base_fat"
    case notes
  }
}

extension DishTemplate: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "dish_templates"

  enum Columns: String, ColumnExpression {
    case id, name
    case baseCalories = "base_calories"
    case baseProtein = "base_protein"
    case baseCarbs = "base_carbs"
    case baseFat = "base_fat"
    case notes
  }
}
