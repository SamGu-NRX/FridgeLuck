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

/// How an inventory lot's stored amount was established. Confidence says how sure recognition
/// was about the identity; provenance says how much the amount itself can be trusted. A
/// heuristic guess the system invented, a value the user set by hand, and an explicit weight
/// read from a package or receipt are three different things, so they stay distinguishable.
enum QuantityProvenance: String, Sendable, Codable {
  /// Heuristic guess (typical unit, per-name table). Shown as "est." in the Kitchen.
  case estimate
  /// A value the user typed or stepped to.
  case entered
  /// An explicit weight read from the source: package net weight, receipt line, or a value
  /// the user read from the packaging and set with its unit.
  case measured
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
  /// Where the stored amount came from: a heuristic guess, a value the user set, or an
  /// explicit weight read from the package or receipt. Legacy rows predate the column.
  var quantityProvenance: QuantityProvenance?

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
    case quantityProvenance = "quantity_provenance"
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
  let proposedGrams: Double
  let availableGrams: Double
  let shortfallGrams: Double

  var id: Int64 { ingredientId }

  var hasShortfall: Bool { shortfallGrams > 0 }

  var coverageRatio: Double {
    guard proposedGrams > 0 else { return 1.0 }
    return min(1.0, availableGrams / proposedGrams)
  }
}
