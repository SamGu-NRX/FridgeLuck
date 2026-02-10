import Foundation
import GRDB

struct Ingredient: Identifiable, Sendable, Codable {
  var id: Int64?
  var name: String
  var calories: Double  // kcal per 100g
  var protein: Double  // grams per 100g
  var carbs: Double  // grams per 100g
  var fat: Double  // grams per 100g
  var fiber: Double  // grams per 100g
  var sugar: Double  // grams per 100g
  var sodium: Double  // grams per 100g
  var typicalUnit: String?  // e.g. "1 large (50g)"
  var storageTip: String?
  var pairsWith: String?
  var notes: String?
}

extension Ingredient: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "ingredients"

  enum Columns: String, ColumnExpression {
    case id, name, calories, protein, carbs, fat
    case fiber, sugar, sodium
    case typicalUnit = "typical_unit"
    case storageTip = "storage_tip"
    case pairsWith = "pairs_with"
    case notes
  }
}
