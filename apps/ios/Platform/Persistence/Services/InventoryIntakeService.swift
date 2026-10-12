import Foundation

struct InventoryScanIngestionSummary: Sendable {
  let sourceRef: String
  let ingredientCount: Int
  let lotsAdded: Int
  var lotsRetired: Int = 0
  var lotsRestored: Int = 0
  let skippedAsDuplicate: Bool
}

enum IntakeError: LocalizedError, Equatable {
  case missingSourceRef
  /// `ScanLotLocation.photographed` had no place for an ingredient intake was about to add.
  case missingLocation(ingredientID: Int64)

  var errorDescription: String? {
    switch self {
    case .missingSourceRef:
      return "Scan intake needs a review-session reference."
    case .missingLocation(let ingredientID):
      return "Scan intake has no location for ingredient \(ingredientID)."
    }
  }
}

/// Where scan intake files the lots it adds.
enum ScanLotLocation: Sendable {
  /// From the ingredient's storage tip. The main scan doesn't know where its photo was taken.
  case inferredFromIngredient
  /// Where each ingredient's photo was taken, as onboarding's fridge and pantry steps know.
  /// Adding a lot for an ingredient missing from the map throws rather than guessing.
  case photographed(byIngredient: [Int64: InventoryStorageLocation])
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

  /// Makes the Kitchen match what the user confirmed in one scan-review session.
  ///
  /// The review can be revisited (back from recipes, correct a tomato to a pepper, search again),
  /// so each call reconciles the session's lots in one transaction: newly confirmed foods are
  /// added, lots for foods the user no longer confirms are emptied, and a lot emptied that way
  /// comes back if the user confirms the food again. Lots already cooked from are never
  /// retired, restored or re-added, so a revisit can't bring back eaten food.
  ///
  /// `location` applies to newly added lots; restored and existing lots keep their place.
  /// `preserving` names ingredients this scan can't speak for, such as food from photos that
  /// weren't read this time: their session lots are left exactly as they are, and none is added.
  @discardableResult
  func ingestConfirmedScan(
    detections: [Detection],
    confirmedIngredientIDs: Set<Int64>,
    selectedIngredientByDetection: [UUID: Int64],
    sourceRef: String,
    location: ScanLotLocation,
    preserving: Set<Int64>,
    acquiredAt: Date = Date()
  ) throws -> InventoryScanIngestionSummary {
    let normalizedSourceRef = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSourceRef.isEmpty else {
      throw IntakeError.missingSourceRef
    }

    // `estimateLabel` is the name the review showed its estimate for, so the stored amount is
    // the amount the user confirmed. A corrected detection's label names the wrong food, so
    // those use the chosen ingredient's name instead.
    var observations: [Int64: (count: Int, confidenceSum: Double, estimateLabel: String?)] = [:]
    for detection in detections {
      let selectedIngredientID =
        selectedIngredientByDetection[detection.id] ?? detection.ingredientId
      guard confirmedIngredientIDs.contains(selectedIngredientID) else { continue }

      let existing =
        observations[selectedIngredientID] ?? (count: 0, confidenceSum: 0, estimateLabel: nil)
      let wasCorrected = selectedIngredientID != detection.ingredientId
      observations[selectedIngredientID] = (
        count: existing.count + 1,
        confidenceSum: existing.confidenceSum + max(0, min(Double(detection.confidence), 1.0)),
        estimateLabel: existing.estimateLabel ?? (wasCorrected ? nil : detection.label)
      )
    }

    let ingredients = try ingredientRepository.fetch(ids: Set(observations.keys))
    let ingredientByID: [Int64: Ingredient] = Dictionary(
      uniqueKeysWithValues: ingredients.compactMap { ingredient in
        ingredient.id.map { ($0, ingredient) }
      }
    )

    return try inventoryRepository.write { db in
      let sessionLots = try inventoryRepository.lots(in: db, addedBy: normalizedSourceRef)
      let alreadyAdded = Set(sessionLots.map(\.ingredientId))

      var lotsRetired = 0
      var lotsRestored = 0
      for lot in sessionLots where !lot.wasConsumed && !preserving.contains(lot.ingredientId) {
        let isConfirmed = observations[lot.ingredientId] != nil
        if !isConfirmed && lot.remainingGrams > 0 {
          try inventoryRepository.retireLot(
            in: db,
            lot,
            reason: InventoryRepository.reviewRetirementReason,
            sourceRef: normalizedSourceRef
          )
          lotsRetired += 1
        } else if isConfirmed && lot.wasRetiredByReview {
          try inventoryRepository.restoreRetiredLot(in: db, lot, sourceRef: normalizedSourceRef)
          lotsRestored += 1
        }
      }

      var lotsAdded = 0
      for (ingredientID, observation) in observations
      where !alreadyAdded.contains(ingredientID) && !preserving.contains(ingredientID) {
        let ingredient = ingredientByID[ingredientID]
        // Same estimator and input the review screens display, with no extra floor, so the
        // Kitchen stores what the user confirmed. The catalog-unit estimate it replaced stored
        // e.g. 120 g for an egg the review had shown as ~50 g.
        let gramsPerDetection = Self.estimatedGrams(
          forName: observation.estimateLabel ?? ingredient?.displayName ?? ingredient?.name)
        let quantityGrams = gramsPerDetection * Double(max(1, observation.count))
        let averageConfidence = observation.confidenceSum / Double(max(1, observation.count))

        try inventoryRepository.addLot(
          in: db,
          ingredientId: ingredientID,
          quantityGrams: quantityGrams,
          location: try Self.lotLocation(location, for: ingredientID, ingredient: ingredient),
          confidenceScore: max(0.35, min(averageConfidence, 1.0)),
          source: .scan,
          acquiredAt: acquiredAt,
          reason: "Scan-confirmed inventory intake",
          sourceRef: normalizedSourceRef,
          quantityIsEstimate: true
        )
        lotsAdded += 1
      }

      return InventoryScanIngestionSummary(
        sourceRef: normalizedSourceRef,
        ingredientCount: observations.count,
        lotsAdded: lotsAdded,
        lotsRetired: lotsRetired,
        lotsRestored: lotsRestored,
        skippedAsDuplicate: false
      )
    }
  }

  private static func lotLocation(
    _ location: ScanLotLocation,
    for ingredientID: Int64,
    ingredient: Ingredient?
  ) throws -> InventoryStorageLocation {
    switch location {
    case .inferredFromIngredient:
      return inferredLocation(for: ingredient)
    case .photographed(let byIngredient):
      guard let place = byIngredient[ingredientID] else {
        throw IntakeError.missingLocation(ingredientID: ingredientID)
      }
      return place
    }
  }

  // MARK: - Grocery Intake (explicit quantities + locations)

  struct GroceryIngestItem: Sendable {
    let ingredientId: Int64
    let quantityGrams: Double
    let storageLocation: InventoryStorageLocation
    let confidenceScore: Double
    let source: InventoryLotSource
  }

  /// Explicit gram amounts (not scan-count estimation).
  @discardableResult
  func ingestGroceryItems(
    items: [GroceryIngestItem],
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

    var lotsAdded = 0
    for item in items {
      let safeQuantity = max(20, item.quantityGrams)
      let safeConfidence = max(0.35, min(item.confidenceScore, 1.0))

      _ = try inventoryRepository.addLot(
        ingredientId: item.ingredientId,
        quantityGrams: safeQuantity,
        location: item.storageLocation,
        confidenceScore: safeConfidence,
        source: item.source,
        acquiredAt: acquiredAt,
        reason: "Grocery update intake",
        sourceRef: normalizedSourceRef
      )
      lotsAdded += 1
    }

    return InventoryScanIngestionSummary(
      sourceRef: normalizedSourceRef,
      ingredientCount: items.count,
      lotsAdded: lotsAdded,
      skippedAsDuplicate: false
    )
  }

  // MARK: - Location + Gram Estimation (shared)

  static func inferLocation(for ingredient: Ingredient?) -> InventoryStorageLocation {
    inferredLocation(for: ingredient)
  }

  static func inferLocation(forName ingredientName: String?) -> InventoryStorageLocation {
    inferredLocation(forName: ingredientName)
  }

  static func estimateGrams(forName ingredientName: String?) -> Double {
    estimatedGrams(forName: ingredientName)
  }

  private static func inferredLocation(for ingredient: Ingredient?) -> InventoryStorageLocation {
    // A recognized storage word in the tip wins over the name, and the FIRST
    // storage word in the text is the primary instruction ("Refrigerate or
    // freeze" means fridge; "Cool dark place, not fridge" means pantry). A tip
    // that names no storage word is ignored and the name decides.
    if let tip = ingredient?.storageTip {
      let fromTip = storageWordLocation(in: tip)
      if fromTip != .unknown {
        return fromTip
      }
    }
    return inferredLocation(forName: ingredient?.name)
  }

  /// The earliest recognized storage word in a tip decides its class.
  private static func storageWordLocation(in tip: String) -> InventoryStorageLocation {
    let loweredTip = tip.lowercased()
    var best: (offset: Int, location: InventoryStorageLocation)?
    for (word, location) in storageWords {
      guard let range = loweredTip.range(of: word) else { continue }
      let offset = loweredTip.distance(from: loweredTip.startIndex, to: range.lowerBound)
      if best == nil || offset < best!.offset {
        best = (offset, location)
      }
    }
    return best?.location ?? .unknown
  }

  private static func inferredLocation(forName ingredientName: String?) -> InventoryStorageLocation {
    guard let normalizedName = normalizeIngredientName(ingredientName) else { return .unknown }
    let nameTokens = nameTokens(of: normalizedName)

    if let pinned = collisionOverride(for: normalizedName, tokens: nameTokens) {
      return pinned.location
    }

    if nameTokens.contains("frozen") {
      return .freezer
    }

    if pantryLocationKeywords.contains(where: { matches($0, in: nameTokens) }) {
      return .pantry
    }

    if fridgeLocationKeywords.contains(where: { matches($0, in: nameTokens) }) {
      return .fridge
    }

    return .unknown
  }

  private static func estimatedGrams(forName ingredientName: String?) -> Double {
    guard let normalizedName = normalizeIngredientName(ingredientName) else { return 120 }
    let nameTokens = nameTokens(of: normalizedName)

    if let pinned = collisionOverride(for: normalizedName, tokens: nameTokens),
      let grams = pinned.grams
    {
      return grams
    }

    if matches("egg", in: nameTokens) { return 50 }
    if liquidMassKeywords.contains(where: { matches($0, in: nameTokens) }) { return 240 }
    if oilAndCondimentKeywords.contains(where: { matches($0, in: nameTokens) }) { return 30 }
    if leafyProduceKeywords.contains(where: { matches($0, in: nameTokens) }) { return 40 }
    if aromaticKeywords.contains(where: { matches($0, in: nameTokens) }) { return 20 }
    if proteinKeywords.contains(where: { matches($0, in: nameTokens) }) { return 150 }
    if dryGoodsKeywords.contains(where: { matches($0, in: nameTokens) }) { return 180 }
    if breadKeywords.contains(where: { matches($0, in: nameTokens) }) { return 60 }
    if produceKeywords.contains(where: { matches($0, in: nameTokens) }) { return 120 }

    return 120
  }

  /// Recognized storage words in tips, with the class each word votes for.
  private static let storageWords: [(String, InventoryStorageLocation)] = [
    ("freezer", .freezer), ("freeze", .freezer), ("frozen", .freezer),
    ("pantry", .pantry), ("shelf", .pantry), ("room temp", .pantry), ("cool", .pantry),
    ("fridge", .fridge), ("refriger", .fridge), ("chill", .fridge),
  ]

  /// A pinned name collision that tier matching gets wrong, matched as a
  /// phrase inside the normalized name ("green beans" also covers "fresh
  /// green beans"). `grams` nil keeps the tier estimate.
  private struct NameOverride {
    let phrase: String
    let location: InventoryStorageLocation
    let grams: Double?
  }

  private static let collisionOverrides: [NameOverride] = [
    NameOverride(phrase: "red pepper flakes", location: .pantry, grams: 30),  // a spice jar, not a fresh pepper
    NameOverride(phrase: "green beans", location: .fridge, grams: 120),  // fresh pods, not the dried-bean rule
    NameOverride(phrase: "coconut milk", location: .pantry, grams: nil),  // canned; the name alone rides "milk"
    NameOverride(phrase: "sour cream", location: .fridge, grams: nil),
    NameOverride(phrase: "sweet potato", location: .pantry, grams: nil),  // a cool dark place, not the fridge
    NameOverride(phrase: "peanut butter", location: .pantry, grams: 30),
    NameOverride(phrase: "green onion", location: .fridge, grams: 40),  // leafy, before the onion pantry rule
    NameOverride(phrase: "oatmeal", location: .pantry, grams: 180),
    NameOverride(phrase: "potato", location: .pantry, grams: nil),
    NameOverride(phrase: "eggplant", location: .fridge, grams: 120),
    NameOverride(phrase: "peach", location: .fridge, grams: 120),
    NameOverride(phrase: "peanut", location: .pantry, grams: 180),
    NameOverride(phrase: "cumin", location: .pantry, grams: 30),
  ]

  private static func collisionOverride(
    for normalizedName: String, tokens: [String]
  ) -> (location: InventoryStorageLocation, grams: Double?)? {
    for entry in collisionOverrides {
      let hit =
        entry.phrase.contains(" ")
        ? normalizedName.contains(entry.phrase)
        : tokens.contains { $0 == entry.phrase || singularized($0) == entry.phrase }
      if hit {
        return (entry.location, entry.grams)
      }
    }
    return nil
  }

  private static func nameTokens(of normalizedName: String) -> [String] {
    normalizedName
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  /// Trivial English plural folding ("eggs" -> "egg", "tomatoes" ->
  /// "tomato", "peaches" -> "peach"); keywords still match the raw token,
  /// so "cheese" never depends on this.
  private static func singularized(_ token: String) -> String {
    if token.count > 3, token.hasSuffix("es") {
      return String(token.dropLast(2))
    }
    if token.count > 2, token.hasSuffix("s") {
      return String(token.dropLast(1))
    }
    return token
  }

  /// Whole-word, plural-aware keyword match: "pea" never rides "peanut" or
  /// "peach", "egg" never rides "eggplant", "oat" never rides "goat".
  private static func matches(_ keyword: String, in tokens: [String]) -> Bool {
    tokens.contains { $0 == keyword || singularized($0) == keyword }
  }

  private static func normalizeIngredientName(_ ingredientName: String?) -> String? {
    guard let ingredientName else { return nil }

    let normalizedName =
      ingredientName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalizedName.isEmpty else { return nil }

    return normalizedName
  }

  private static let pantryLocationKeywords = [
    "rice", "pasta", "oil", "sauce", "bread", "tortilla", "oat", "bean", "chickpea", "corn",
    "garlic", "onion", "honey", "peanut butter", "canned", "ginger",
  ]

  private static let fridgeLocationKeywords = [
    "milk", "yogurt", "cheese", "butter", "egg", "spinach", "lettuce", "pepper", "tomato",
    "carrot", "broccoli", "cucumber", "zucchini", "celery", "avocado", "apple", "banana",
    "lemon", "lime", "salmon", "chicken", "beef", "tofu", "mushroom", "cilantro",
  ]

  private static let liquidMassKeywords = ["milk", "yogurt"]
  private static let oilAndCondimentKeywords = [
    "oil", "sauce", "honey", "mustard", "peanut butter", "sesame",
  ]
  private static let leafyProduceKeywords = [
    "spinach", "lettuce", "cilantro", "herb", "green onion",
  ]
  private static let aromaticKeywords = ["garlic", "ginger", "chive"]
  private static let proteinKeywords = ["chicken", "beef", "salmon", "tofu", "tuna"]
  private static let dryGoodsKeywords = [
    "rice", "pasta", "bean", "chickpea", "oat", "corn", "pea",
  ]
  private static let breadKeywords = ["bread", "tortilla"]
  private static let produceKeywords = [
    "onion", "tomato", "pepper", "potato", "carrot", "mushroom", "broccoli", "cucumber",
    "avocado", "apple", "banana", "lemon", "lime", "zucchini", "celery",
  ]
}
