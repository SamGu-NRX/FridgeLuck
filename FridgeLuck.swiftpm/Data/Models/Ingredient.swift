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
  var description: String?
  var categoryLabel: String?
  var spriteGroup: String?
  var spriteKey: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case calories
    case protein
    case carbs
    case fat
    case fiber
    case sugar
    case sodium
    case typicalUnit = "typical_unit"
    case storageTip = "storage_tip"
    case pairsWith = "pairs_with"
    case notes
    case description
    case categoryLabel = "category_label"
    case spriteGroup = "sprite_group"
    case spriteKey = "sprite_key"
  }
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
    case description
    case categoryLabel = "category_label"
    case spriteGroup = "sprite_group"
    case spriteKey = "sprite_key"
  }
}

extension Ingredient {
  var displayName: String {
    let normalized = name.replacingOccurrences(of: "_", with: " ")

    if normalized == normalized.lowercased() {
      return normalized.localizedCapitalized
    }

    return normalized
  }

  func matchesSearch(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.isEmpty { return true }
    let corpus = "\(name) \(description ?? "") \(notes ?? "")".lowercased()
    return corpus.contains(trimmed)
  }
}
