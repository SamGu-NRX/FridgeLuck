import FLFeatureLogic
import Foundation

/// One food in the grocery review. Amounts may be unknown (`quantityGrams == nil`) when the
/// source carried no usable weight — the review asks the user instead of guessing, and the
/// session cannot commit until every confirmed item is resolved.
struct GroceryPendingItem: Identifiable, Sendable, Equatable {
  let id: UUID
  var ingredientId: Int64?
  var ingredientName: String
  var quantityGrams: Double?
  var storageLocation: InventoryStorageLocation
  var confidenceScore: Double
  var source: InventoryLotSource
  var isConfirmed: Bool
  /// How the stored amount was established, kept alongside the amount through review into
  /// the lot row. `nil` while the amount is unknown.
  var quantityProvenance: QuantityProvenance?
  /// Count read off the line ("2 @", "x2"), kept for the evidence summary.
  var countEvidence: Int?
  /// Short source evidence: "0.94 lb", "NET WT 454 G".
  var evidenceSummary: String?
  /// The raw recognition text this draft came from.
  var rawDescription: String?
  /// Other foods recognition considered, for identity correction.
  var alternatives: [GroceryAlternative]

  init(
    id: UUID = UUID(),
    ingredientId: Int64?,
    ingredientName: String,
    quantityGrams: Double?,
    storageLocation: InventoryStorageLocation,
    confidenceScore: Double,
    source: InventoryLotSource,
    isConfirmed: Bool = true,
    quantityProvenance: QuantityProvenance? = nil,
    countEvidence: Int? = nil,
    evidenceSummary: String? = nil,
    rawDescription: String? = nil,
    alternatives: [GroceryAlternative] = []
  ) {
    self.id = id
    self.ingredientId = ingredientId
    self.ingredientName = ingredientName
    self.quantityGrams = quantityGrams
    self.storageLocation = storageLocation
    self.confidenceScore = confidenceScore
    self.source = source
    self.isConfirmed = isConfirmed
    self.quantityProvenance = quantityProvenance
    self.countEvidence = countEvidence
    self.evidenceSummary = evidenceSummary
    self.rawDescription = rawDescription
    self.alternatives = alternatives
  }

  /// A confirmed item can commit only with a food and a positive amount chosen.
  var isResolvedForCommit: Bool {
    ingredientId != nil && (quantityGrams ?? 0) > 0
  }

  /// Replaces the item's identity after a correction. A heuristic estimate belongs to the
  /// old food, so it is re-derived from the new one and may become unknown; a value the
  /// user set or an explicit weight describes the physical item and stays.
  mutating func replaceIdentity(ingredientId: Int64, name: String, estimatedGrams: Double?) {
    self.ingredientId = ingredientId
    ingredientName = name
    alternatives.removeAll { $0.id == ingredientId }

    guard quantityProvenance == nil || quantityProvenance == .estimate else { return }
    quantityGrams = estimatedGrams
    quantityProvenance = estimatedGrams.map { _ in QuantityProvenance.estimate }
  }

  /// The user set the amount by hand.
  mutating func setAmount(_ grams: Double, provenance: QuantityProvenance) {
    quantityGrams = grams
    quantityProvenance = provenance
  }
}
