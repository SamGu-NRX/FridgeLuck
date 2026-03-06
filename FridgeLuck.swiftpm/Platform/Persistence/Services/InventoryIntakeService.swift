import Foundation

struct InventoryScanIngestionSummary: Sendable {
  let sourceRef: String
  let ingredientCount: Int
  let lotsAdded: Int
  let skippedAsDuplicate: Bool
}

/// Converts confirmed scan detections into inventory lot updates.
/// This keeps scan confidence and ingredient-level accounting linked.
final class InventoryIntakeService: Sendable {
  private let ingredientRepository: IngredientRepository
  private let inventoryRepository: InventoryRepository

  init(
    ingredientRepository: IngredientRepository,
    inventoryRepository: InventoryRepository
  ) {
    self.ingredientRepository = ingredientRepository
    self.inventoryRepository = inventoryRepository
  }

  @discardableResult
  func ingestConfirmedScan(
    detections: [Detection],
    confirmedIngredientIDs: Set<Int64>,
    selectedIngredientByDetection: [UUID: Int64],
    sourceRef: String,
    acquiredAt: Date = Date()
  ) throws -> InventoryScanIngestionSummary {
    let normalizedSourceRef = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSourceRef.isEmpty else {
      return InventoryScanIngestionSummary(
        sourceRef: sourceRef,
        ingredientCount: 0,
        lotsAdded: 0,
        skippedAsDuplicate: false
      )
    }

    if try inventoryRepository.hasEvent(eventType: .add, sourceRef: normalizedSourceRef) {
      return InventoryScanIngestionSummary(
        sourceRef: normalizedSourceRef,
        ingredientCount: 0,
        lotsAdded: 0,
        skippedAsDuplicate: true
      )
    }

    var observations: [Int64: (count: Int, confidenceSum: Double)] = [:]

    for detection in detections {
      let selectedIngredientID =
        selectedIngredientByDetection[detection.id] ?? detection.ingredientId
      guard confirmedIngredientIDs.contains(selectedIngredientID) else { continue }

      let existing = observations[selectedIngredientID] ?? (count: 0, confidenceSum: 0)
      observations[selectedIngredientID] = (
        count: existing.count + 1,
        confidenceSum: existing.confidenceSum + max(0, min(Double(detection.confidence), 1.0))
      )
    }

    guard !observations.isEmpty else {
      return InventoryScanIngestionSummary(
        sourceRef: normalizedSourceRef,
        ingredientCount: 0,
        lotsAdded: 0,
        skippedAsDuplicate: false
      )
    }

    let ingredientIDs = Set(observations.keys)
    let ingredients = try ingredientRepository.fetch(ids: ingredientIDs)
    let ingredientPairs: [(Int64, Ingredient)] = ingredients.compactMap { ingredient in
      guard let id = ingredient.id else { return nil }
      return (id, ingredient)
    }
    let ingredientByID: [Int64: Ingredient] = Dictionary(uniqueKeysWithValues: ingredientPairs)

    var lotsAdded = 0
    for (ingredientID, observation) in observations {
      let ingredient = ingredientByID[ingredientID]
      let gramsPerDetection = Self.estimatedGrams(for: ingredient)
      let quantityGrams = max(30, gramsPerDetection * Double(max(1, observation.count)))

      let averageConfidence = observation.confidenceSum / Double(max(1, observation.count))
      let confidence = max(0.35, min(averageConfidence, 1.0))
      let location = Self.inferredLocation(for: ingredient)

      _ = try inventoryRepository.addLot(
        ingredientId: ingredientID,
        quantityGrams: quantityGrams,
        location: location,
        confidenceScore: confidence,
        source: .scan,
        acquiredAt: acquiredAt,
        reason: "Scan-confirmed inventory intake",
        sourceRef: normalizedSourceRef
      )
      lotsAdded += 1
    }

    return InventoryScanIngestionSummary(
      sourceRef: normalizedSourceRef,
      ingredientCount: observations.count,
      lotsAdded: lotsAdded,
      skippedAsDuplicate: false
    )
  }

  private static func inferredLocation(for ingredient: Ingredient?) -> InventoryStorageLocation {
    guard let tip = ingredient?.storageTip?.lowercased() else { return .unknown }

    if tip.contains("freezer") || tip.contains("freeze") {
      return .freezer
    }
    if tip.contains("pantry") || tip.contains("shelf") {
      return .pantry
    }
    if tip.contains("fridge") || tip.contains("refriger") || tip.contains("chill") {
      return .fridge
    }
    return .unknown
  }

  private static func estimatedGrams(for ingredient: Ingredient?) -> Double {
    guard let typicalUnit = ingredient?.typicalUnit?.lowercased() else { return 120 }

    if let grams = extractNumber(from: typicalUnit, unitTokens: ["g", "gram", "grams"]) {
      return max(20, grams)
    }

    if let ounces = extractNumber(from: typicalUnit, unitTokens: ["oz", "ounce", "ounces"]) {
      return max(20, ounces * 28.3495)
    }

    if typicalUnit.contains("cup") { return 240 }
    if typicalUnit.contains("tbsp") || typicalUnit.contains("tablespoon") { return 15 }
    if typicalUnit.contains("tsp") || typicalUnit.contains("teaspoon") { return 5 }
    if typicalUnit.contains("slice") { return 35 }
    if typicalUnit.contains("piece") || typicalUnit.contains("whole") { return 90 }

    return 120
  }

  private static func extractNumber(from text: String, unitTokens: [String]) -> Double? {
    let pattern = "([0-9]+(?:\\.[0-9]+)?)\\s*(\\b(?:" + unitTokens.joined(separator: "|") + ")\\b)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
      match.numberOfRanges >= 2,
      let numberRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    return Double(text[numberRange])
  }
}
