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

/// What cooking a catalog recipe took out of the Kitchen for one required line. A catalog
/// line names a vocabulary key, not an app ingredient, so it reaches stock only through the
/// key's rows in `recipes_catalog_ingredient_bridge`.
struct CatalogLineConsumption: Equatable, Sendable {
  enum Status: Equatable, Sendable {
    /// Grams came out of held lots of the bridged ingredients, possibly fewer than asked.
    case used
    /// The line bridges to app ingredients, but the Kitchen holds none of them.
    case notInKitchen
    /// The key bridges to no app ingredient, so no lot can stand for it. Nothing is taken.
    case noBridge
    /// The line gives no weight ("to taste", a count with no grams). Nothing is taken.
    case noGramAmount
  }

  let ingredientKey: String
  /// The app ingredients the bridge maps the key to, ascending. Empty for `.noBridge`.
  let bridgedIngredientIds: [Int64]
  let requestedGrams: Double
  /// Grams taken from each bridged ingredient's lots. Only ingredients the Kitchen held appear.
  let consumedGramsByIngredient: [Int64: Double]
  let status: Status

  var consumedGrams: Double { consumedGramsByIngredient.values.reduce(0, +) }

  /// The line in the per-ingredient shape legacy consumption reports, so "N ingredients came
  /// out" counts catalog lines the way it counts legacy ones. A line drawn from two bridged
  /// ingredients reports the one it took most from. nil when the line could not reach stock.
  var inventoryResult: InventoryConsumptionResult? {
    switch status {
    case .noBridge, .noGramAmount:
      return nil
    case .used, .notInKitchen:
      guard
        let representative = consumedGramsByIngredient.max(by: { lhs, rhs in
          lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        })?.key ?? bridgedIngredientIds.first
      else { return nil }
      return InventoryConsumptionResult(
        ingredientId: representative,
        requestedGrams: requestedGrams,
        consumedGrams: consumedGrams,
        shortfallGrams: max(0, requestedGrams - consumedGrams))
    }
  }
}

// MARK: - Virtual Fridge View Models

/// Active stock row: ingredient + storage, aggregated from lots.
struct InventoryActiveItem: Identifiable, Sendable {
  let ingredientId: Int64
  let ingredientName: String
  let storageLocation: InventoryStorageLocation
  let totalRemainingGrams: Double
  let averageConfidenceScore: Double
  let earliestExpiresAt: Date?
  let daysUntilExpiry: Int?
  let lastUpdatedAt: Date?
  let lotCount: Int
  let mostRecentSource: InventoryLotSource
  /// True when any remaining lot's amount is a photo-intake guess the user hasn't set.
  let hasEstimatedQuantity: Bool

  var id: String { "\(ingredientId)_\(storageLocation.rawValue)" }

  var isRecentlyAdded: Bool {
    guard let lastUpdatedAt else { return false }
    return abs(lastUpdatedAt.timeIntervalSinceNow) < 24 * 3600
  }

  var isLowStock: Bool { totalRemainingGrams < 50 }

  var isExpiringSoon: Bool {
    guard let daysUntilExpiry else { return false }
    return daysUntilExpiry <= 3
  }

  func withConfirmedConfidence() -> InventoryActiveItem {
    InventoryActiveItem(
      ingredientId: ingredientId,
      ingredientName: ingredientName,
      storageLocation: storageLocation,
      totalRemainingGrams: totalRemainingGrams,
      averageConfidenceScore: 1.0,
      earliestExpiresAt: earliestExpiresAt,
      daysUntilExpiry: daysUntilExpiry,
      lastUpdatedAt: lastUpdatedAt,
      lotCount: lotCount,
      mostRecentSource: mostRecentSource,
      hasEstimatedQuantity: hasEstimatedQuantity
    )
  }
}

/// A lot added by one scan-review session, used to reconcile later edits to that review.
struct ScanSessionLot: Sendable, Equatable {
  let lotId: Int64
  let ingredientId: Int64
  let quantityGrams: Double
  let remainingGrams: Double
  /// Some of it was cooked. Such lots are never retired or re-added by review.
  let wasConsumed: Bool
  /// Its latest event is this review emptying it, so reconfirming can bring it back.
  let wasRetiredByReview: Bool
}

/// Preview of grams that would be consumed vs on-hand.
struct InventoryDeductionPreview: Identifiable, Sendable {
  let ingredientId: Int64
  let ingredientName: String
  /// What the recipe asks for.
  let proposedGrams: Double
  let availableGrams: Double
  /// What logging takes out: `proposedGrams` capped at `availableGrams`.
  let deductedGrams: Double
  let shortfallGrams: Double

  var id: Int64 { ingredientId }

  var hasShortfall: Bool { shortfallGrams > 0 }

  var coverageRatio: Double {
    guard proposedGrams > 0 else { return 1.0 }
    return min(1.0, availableGrams / proposedGrams)
  }
}
