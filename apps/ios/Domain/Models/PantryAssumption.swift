import Foundation
import GRDB

struct PantryAssumption: Sendable, Codable, Identifiable {
  var ingredientId: Int64
  var tier: PantryTier
  var addedAt: Date

  var id: Int64 { ingredientId }

  enum PantryTier: String, Codable, Sendable, CaseIterable {
    case alwaysHave = "always_have"
    case usuallyHave = "usually_have"
    case onlyIfConfirmed = "only_if_confirmed"

    var displayLabel: String {
      switch self {
      case .alwaysHave: "Always have"
      case .usuallyHave: "Usually have"
      case .onlyIfConfirmed: "Only if confirmed"
      }
    }

    var next: PantryTier {
      switch self {
      case .alwaysHave: .usuallyHave
      case .usuallyHave: .onlyIfConfirmed
      case .onlyIfConfirmed: .alwaysHave
      }
    }
  }

  enum CodingKeys: String, CodingKey {
    case ingredientId = "ingredient_id"
    case tier
    case addedAt = "added_at"
  }
}

extension PantryAssumption: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "pantry_assumptions"

  enum Columns: String, ColumnExpression {
    case ingredientId = "ingredient_id"
    case tier
    case addedAt = "added_at"
  }
}
