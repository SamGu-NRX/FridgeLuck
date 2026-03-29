import Foundation

struct GroceryPendingItem: Identifiable, Sendable {
  let id: UUID
  var ingredientId: Int64
  var ingredientName: String
  var quantityGrams: Double
  var storageLocation: InventoryStorageLocation
  var confidenceScore: Double
  var source: InventoryLotSource
  var isConfirmed: Bool

  init(
    ingredientId: Int64,
    ingredientName: String,
    quantityGrams: Double,
    storageLocation: InventoryStorageLocation,
    confidenceScore: Double,
    source: InventoryLotSource,
    isConfirmed: Bool = true
  ) {
    self.id = UUID()
    self.ingredientId = ingredientId
    self.ingredientName = ingredientName
    self.quantityGrams = quantityGrams
    self.storageLocation = storageLocation
    self.confidenceScore = confidenceScore
    self.source = source
    self.isConfirmed = isConfirmed
  }

  init(from detection: Detection) {
    self.id = UUID()
    self.ingredientId = detection.ingredientId
    self.ingredientName = detection.label
    self.quantityGrams = InventoryIntakeService.estimateGrams(forName: detection.label)
    self.storageLocation = InventoryIntakeService.inferLocation(forName: detection.label)
    self.confidenceScore = Double(detection.confidence)
    self.source = .scan
    self.isConfirmed = detection.confidence >= 0.70
  }
}
