import Foundation

// MARK: - Exposure

/// One item of a rendered slate: the recipe and its display position.
struct TasteExposureItem: Codable, Equatable, Sendable {
  var recipe: TasteRecipeRef
  var position: Int
}

/// Decision context of a render
/// (docs/spec/taste/contracts/exposure.schema.json `context`).
struct TasteExposureContext: Codable, Equatable, Sendable {
  var kitchenIngredientCount: Int
  var householdSize: Int
  var mealContext: String?
}

/// One recommendation-surface render: what was shown, in what order, and the full
/// feasible choice set the ranker drew from. This record is what separates availability
/// from preference (docs/spec/taste/SPEC.md §2.4). `id` is a stable UUID v4 string.
struct TasteExposure: Codable, Equatable, Sendable {
  var id: String
  var at: Date
  var surface: String
  var eater: String?
  var sessionId: String?
  var slate: [TasteExposureItem]
  var feasible: [TasteRecipeRef]
  var context: TasteExposureContext
}

// MARK: - Profile statements

/// Which layer a profile sentence belongs to
/// (docs/spec/taste/contracts/profile-statement.schema.json).
enum TasteStatementLayer: String, Codable, Sendable, CaseIterable {
  /// Setup allergies/diets: hard filter, edited in setup only, never machine-written.
  case restriction
  /// What the user told the app at setup or later.
  case stated
  /// User-set override with a fixed rank value in [-8, +8].
  case pinned
  /// Learned from behaviour; carries numerator/denominator evidence counts.
  case inferred
}

/// Lifecycle state of a profile statement.
enum TasteStatementState: String, Codable, Sendable, CaseIterable {
  case active
  /// The user tapped "Right".
  case confirmed
  /// "This is wrong": kept, never re-learned, shown struck-through.
  case rejected
  /// "Don't ask again" until `mutedUntil`.
  case muted
  /// Evidence went stale; revives automatically on fresh evidence.
  case expired
}

/// One sentence on the taste profile with the evidence it stands on
/// (docs/spec/taste/contracts/profile-statement.schema.json).
struct TasteProfileStatement: Codable, Equatable, Sendable {
  var id: String
  var layer: TasteStatementLayer
  var featureKind: TasteFeatureKind?
  var featureKey: String?
  var templateId: String
  /// Evidence count for the claim; required for inferred, nil otherwise.
  var numerator: Int?
  /// Distinct opportunities the numerator is out of.
  var denominator: Int?
  var state: TasteStatementState
  var mutedUntil: Date?
  var pinnedValue: Double?
  var lastEvidenceAt: Date?
  var createdAt: Date
  var updatedAt: Date
  var text: String
}
