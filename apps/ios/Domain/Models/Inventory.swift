import Foundation
import GRDB

enum InventoryStorageLocation: String, Sendable, Codable, CaseIterable, DatabaseValueConvertible {
  case fridge
  case pantry
  case freezer
  case unknown
}

enum InventoryLotSource: String, Sendable, Codable, DatabaseValueConvertible {
  case scan
  case reverseScan = "reverse_scan"
  case manual
  case system
}

enum InventoryEventType: String, Sendable, Codable, DatabaseValueConvertible {
  case add
  case consume
  case adjust
  case discard
  case expire
}

struct IngredientShelfLifeProfile: Sendable, Codable {
  var ingredientId: Int64
  var fridgeDays: Int?
  var pantryDays: Int?
  var freezerDays: Int?
  var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case ingredientId = "ingredient_id"
    case fridgeDays = "fridge_days"
    case pantryDays = "pantry_days"
    case freezerDays = "freezer_days"
    case updatedAt = "updated_at"
  }
}

extension IngredientShelfLifeProfile: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "ingredient_shelf_life_profiles"

  enum Columns: String, ColumnExpression {
    case ingredientId = "ingredient_id"
    case fridgeDays = "fridge_days"
    case pantryDays = "pantry_days"
    case freezerDays = "freezer_days"
    case updatedAt = "updated_at"
  }
}

struct InventoryLot: Identifiable, Sendable, Codable {
  var id: Int64?
  var ingredientId: Int64
  var quantityGrams: Double
  var remainingGrams: Double
  var storageLocation: InventoryStorageLocation
  var confidenceScore: Double
  var source: InventoryLotSource
  var acquiredAt: Date
  var expiresAt: Date?
  var createdAt: Date?
  var updatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case ingredientId = "ingredient_id"
    case quantityGrams = "quantity_grams"
    case remainingGrams = "remaining_grams"
    case storageLocation = "storage_location"
    case confidenceScore = "confidence_score"
    case source
    case acquiredAt = "acquired_at"
    case expiresAt = "expires_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

extension InventoryLot: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "inventory_lots"

  enum Columns: String, ColumnExpression {
    case id
    case ingredientId = "ingredient_id"
    case quantityGrams = "quantity_grams"
    case remainingGrams = "remaining_grams"
    case storageLocation = "storage_location"
    case confidenceScore = "confidence_score"
    case source
    case acquiredAt = "acquired_at"
    case expiresAt = "expires_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

struct InventoryEvent: Identifiable, Sendable, Codable {
  var id: Int64?
  var ingredientId: Int64
  var lotId: Int64?
  var eventType: InventoryEventType
  var quantityDeltaGrams: Double
  var confidenceScore: Double
  var reason: String?
  var sourceRef: String?
  var createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case ingredientId = "ingredient_id"
    case lotId = "lot_id"
    case eventType = "event_type"
    case quantityDeltaGrams = "quantity_delta_grams"
    case confidenceScore = "confidence_score"
    case reason
    case sourceRef = "source_ref"
    case createdAt = "created_at"
  }
}

extension InventoryEvent: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "inventory_events"

  enum Columns: String, ColumnExpression {
    case id
    case ingredientId = "ingredient_id"
    case lotId = "lot_id"
    case eventType = "event_type"
    case quantityDeltaGrams = "quantity_delta_grams"
    case confidenceScore = "confidence_score"
    case reason
    case sourceRef = "source_ref"
    case createdAt = "created_at"
  }
}

struct InventoryItem: Sendable, Codable {
  var ingredientId: Int64
  var totalRemainingGrams: Double
  var averageConfidenceScore: Double
  var lastUpdatedAt: Date?

  enum CodingKeys: String, CodingKey {
    case ingredientId = "ingredient_id"
    case totalRemainingGrams = "total_remaining_grams"
    case averageConfidenceScore = "average_confidence_score"
    case lastUpdatedAt = "last_updated_at"
  }
}

extension InventoryItem: FetchableRecord, PersistableRecord, TableRecord {
  static let databaseTableName = "inventory_items"

  enum Columns: String, ColumnExpression {
    case ingredientId = "ingredient_id"
    case totalRemainingGrams = "total_remaining_grams"
    case averageConfidenceScore = "average_confidence_score"
    case lastUpdatedAt = "last_updated_at"
  }
}

struct InventoryUseSoonSuggestion: Identifiable, Sendable {
  let ingredientId: Int64
  let ingredientName: String
  let remainingGrams: Double
  let earliestExpiresAt: Date
  let daysRemaining: Int
  let confidenceScore: Double

  var id: Int64 { ingredientId }
}

struct InventoryConsumptionResult: Sendable {
  let ingredientId: Int64
  let requestedGrams: Double
  let consumedGrams: Double
  let shortfallGrams: Double
}
