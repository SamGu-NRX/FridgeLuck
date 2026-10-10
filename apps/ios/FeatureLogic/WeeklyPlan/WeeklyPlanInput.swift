import Foundation

// MARK: - Input bundle

/// The complete read-only household snapshot a plan is computed from. The
/// fingerprint over these exact values is how accepted plans detect that the
/// kitchen moved underneath them.
public struct WeeklyPlanInput: Sendable, Equatable {
  public var slots: [WeeklyPlanSlot]
  public var recipes: [WeeklyPlanRecipe]
  public var stock: [WeeklyPlanStockItem]
  /// Use-soon urgency per ingredient (points per gram). Absent = zero.
  public var urgencies: [WeeklyPlanUrgency]
  public var constraints: WeeklyPlanConstraints
  public var objective: WeeklyPlanObjective

  public init(
    slots: [WeeklyPlanSlot], recipes: [WeeklyPlanRecipe], stock: [WeeklyPlanStockItem],
    urgencies: [WeeklyPlanUrgency] = [], constraints: WeeklyPlanConstraints = WeeklyPlanConstraints(),
    objective: WeeklyPlanObjective = WeeklyPlanObjective()
  ) {
    self.slots = slots
    self.recipes = recipes
    self.stock = stock
    self.urgencies = urgencies
    self.constraints = constraints
    self.objective = objective
  }

  /// Stock indexed by ingredient. Duplicate ids (e.g. caller passing per-lot
  /// rows) collapse instead of crashing: multiple known lots sum; any
  /// unconfirmed lot makes the whole ingredient unconfirmed — an unconfirmed
  /// guess cannot back feasibility regardless of what else is on hand.
  public var stockByID: [Int64: WeeklyPlanStockItem] {
    Dictionary(stock.map { ($0.ingredientId, $0) }, uniquingKeysWith: { a, b in
      guard a.quantityIsKnown, b.quantityIsKnown else {
        return WeeklyPlanStockItem(ingredientId: a.ingredientId, availableGrams: 0, quantityIsKnown: false)
      }
      return WeeklyPlanStockItem(
        ingredientId: a.ingredientId, availableGrams: a.availableGrams + b.availableGrams,
        quantityIsKnown: true)
    })
  }

  public var urgencyByIngredient: [Int64: Double] {
    Dictionary(uniqueKeysWithValues: urgencies.map { ($0.ingredientId, $0.weightPerGram) })
  }
}

// MARK: - Fingerprint (stale-input detection)

/// Stable 64-bit FNV-1a over a canonical serialization of the inputs. Two
/// snapshots fingerprint equal only when recipes, stock (amounts AND
/// known/unknown flags), urgencies, constraints, slots, and objective all match.
/// This is staleness detection, not security.
public enum WeeklyPlanFingerprint {

  public static func compute(_ input: WeeklyPlanInput) -> String {
    var hasher = FNV1a64()

    func digest(_ text: String) { hasher.mix(text.utf8) }
    func digest(_ value: Double) {
      // Bit-exact: same gram value always hashes the same.
      var bits = value.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { hasher.mix($0) }
    }
    func digest(_ value: Int64) {
      var bits = value.littleEndian
      withUnsafeBytes(of: &bits) { hasher.mix($0) }
    }
    func digest(_ value: Int) {
      digest(Int64(value))
    }
    func digest(_ value: Bool) { digest(value ? Int64(1) : Int64(0)) }

    digest("weekly-plan-fingerprint-v1")
    digest(input.slots.count)
    for slot in input.slots.sorted(by: { $0.id < $1.id }) {
      digest(slot.id)
      digest(slot.label)
    }

    digest(input.recipes.count)
    for recipe in input.recipes.sorted(by: { $0.id < $1.id }) {
      digest(recipe.id)
      digest(recipe.title)
      digest(recipe.timeMinutes)
      digest(recipe.dietClass ?? "~nil")
      digest(recipe.needs.count)
      for need in recipe.needs.sorted(by: sortNeeds) {
        digest(need.ingredientId)
        digest(need.gramsPerServing)
        digest(need.isOptional)
        for sub in need.substitutes { digest(sub) }
        digest(Int64(need.substitutes.count))
      }
    }

    digest(input.stock.count)
    for item in input.stock.sorted(by: { $0.ingredientId < $1.ingredientId }) {
      digest(item.ingredientId)
      digest(item.availableGrams)
      digest(item.quantityIsKnown)
    }

    digest(input.urgencies.count)
    for urgency in input.urgencies.sorted(by: { $0.ingredientId < $1.ingredientId }) {
      digest(urgency.ingredientId)
      digest(urgency.weightPerGram)
    }

    digest(Int64(input.constraints.excludedIngredientIds.count))
    for excluded in input.constraints.excludedIngredientIds.sorted() {
      digest(excluded)
    }
    digest(input.constraints.requiredDietClass ?? "~nil")
    digest(input.constraints.maxCookTimeMinutes ?? -1)
    digest(input.constraints.servingsPerMeal)
    digest(input.constraints.maxRepeatsPerRecipe)

    digest(input.objective.useSoonWeight)
    digest(input.objective.timeWeightPerMinute)
    digest(input.objective.repetitionPenalty)

    return String(format: "%016llx", hasher.value)
  }

  private static func sortNeeds(_ lhs: WeeklyPlanNeed, _ rhs: WeeklyPlanNeed) -> Bool {
    lhs.ingredientId < rhs.ingredientId
  }

  struct FNV1a64 {
    var value: UInt64 = 0xcbf29ce484222325

    mutating func mix(_ bytes: some Sequence<UInt8>) {
      for byte in bytes {
        value ^= UInt64(byte)
        value = value &* 0x100000001b3
      }
    }
    mutating func mix(_ bytes: UnsafeRawBufferPointer) {
      for byte in bytes {
        value ^= UInt64(byte)
        value = value &* 0x100000001b3
      }
    }
  }
}

// MARK: - Shared comparison + shortage building (search-policy spec)

enum WeeklyPlanSearch {

  /// Score comparison used by every searcher: strictly better beyond epsilon;
  /// otherwise the lexicographically smaller recipe-id sequence wins. Shared so
  /// engine and oracle cannot drift on what "best" means.
  static func prefer(
    _ candidateScore: Double, _ candidateIDs: [Int64],
    over bestScore: Double, _ bestIDs: [Int64]?
  ) -> Bool {
    guard let bestIDs else { return true }
    if candidateScore > bestScore + 1e-9 { return true }
    if candidateScore < bestScore - 1e-9 { return false }
    return lexicographicallyLess(candidateIDs, bestIDs)
  }

  static func lexicographicallyLess(_ lhs: [Int64], _ rhs: [Int64]) -> Bool {
    for (a, b) in zip(lhs, rhs) {
      if a != b { return a < b }
    }
    return lhs.count < rhs.count
  }

  /// Builds the grouped shortage list from an allocation. One row per
  /// (ingredient, category); ingredients only appear when something is worth
  /// telling the user about.
  static func shortages(
    rows: [WeeklyPlanConsumptionRow],
    stock: [Int64: WeeklyPlanStockItem]
  ) -> [WeeklyPlanShortage] {
    struct Accumulator {
      var needed = 0.0
      var available = 0.0
      var shortfall = 0.0
      var recipes: Set<Int64> = []
      var substitute: Int64?
    }

    var grouped: [String: Accumulator] = [:]

    func key(_ id: Int64, _ category: WeeklyPlanShortageCategory) -> String {
      "\(id)|\(category.rawValue)"
    }

    for row in rows {
      let primaryStock = stock[row.ingredientId]

      if row.unresolvableExcluded {
        var acc = grouped[key(row.ingredientId, .missing)] ?? Accumulator()
        acc.needed += row.shortfallGrams
        acc.shortfall += row.shortfallGrams
        acc.recipes.insert(row.recipeId)
        grouped[key(row.ingredientId, .missing)] = acc
        continue
      }

      if row.substituted {
        var acc = grouped[key(row.ingredientId, .substituted)] ?? Accumulator()
        acc.needed += row.grams
        acc.available = primaryStock?.quantityIsKnown == true ? (primaryStock?.availableGrams ?? 0) : 0
        acc.recipes.insert(row.recipeId)
        acc.substitute = row.resolvedIngredientId
        grouped[key(row.ingredientId, .substituted)] = acc
        continue
      }

      if row.shortfallGrams > 1e-9 {
        let category: WeeklyPlanShortageCategory =
          primaryStock == nil
            ? .missing
            : (primaryStock?.quantityIsKnown == true ? .shortQuantity : .unknownAmount)
        var acc = grouped[key(row.ingredientId, category)] ?? Accumulator()
        acc.needed += row.grams + row.shortfallGrams
        acc.available = primaryStock?.quantityIsKnown == true ? (primaryStock?.availableGrams ?? 0) : 0
        acc.shortfall += row.shortfallGrams
        acc.recipes.insert(row.recipeId)
        grouped[key(row.ingredientId, category)] = acc
        continue
      }
    }

    return grouped
      .map { (key, acc) in
        let parts = key.split(separator: "|")
        let id = Int64(parts[0]) ?? 0
        let category = WeeklyPlanShortageCategory(rawValue: String(parts[1])) ?? .missing
        return WeeklyPlanShortage(
          ingredientId: id,
          category: category,
          neededGrams: acc.needed,
          availableGrams: acc.available,
          shortfallGrams: acc.shortfall,
          affectedRecipeIds: acc.recipes.sorted(),
          substituteIngredientId: acc.substitute)
      }
      .sorted {
        if $0.ingredientId != $1.ingredientId { return $0.ingredientId < $1.ingredientId }
        return $0.category.rawValue < $1.category.rawValue
      }
  }

  static func assignments(
    from assignment: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)],
    rows: [WeeklyPlanConsumptionRow],
    servings: Int
  ) -> [WeeklyPlanSlotAssignment] {
    assignment.map { slot, recipe in
      let substitutions = rows
        .filter { $0.slotId == slot.id && $0.recipeId == recipe.id && $0.substituted }
        .map { WeeklyPlanSubstitution(plannedIngredientId: $0.ingredientId, substituteIngredientId: $0.resolvedIngredientId) }
      return WeeklyPlanSlotAssignment(
        slotId: slot.id,
        slotLabel: slot.label,
        recipeId: recipe.id,
        recipeTitle: recipe.title,
        timeMinutes: recipe.timeMinutes,
        substitutions: substitutions,
        servings: servings)
    }
  }
}
