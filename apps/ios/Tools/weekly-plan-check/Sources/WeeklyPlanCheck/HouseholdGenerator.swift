import Foundation
import WeeklyPlanCore

// MARK: - Seeded synthetic households
//
// Generates reproducible WeeklyPlanInput states that exercise the behaviors
// under test: quantity shortages, unknown amounts, optional needs, 1:1
// substitutions, repetition pressure, diet classes, hard exclusions, and
// cook-time ceilings. Every draw comes from the seeded stream, so the same
// seed produces the identical corpus everywhere.

public struct HouseholdGenerator {
  public let seed: UInt64
  public var rng: SeededRandom

  public init(seed: UInt64) {
    self.seed = seed
    self.rng = SeededRandom(seed: seed)
  }

  /// Generates `count` states, one per derived seed (`seed` + index).
  public mutating func generate(count: Int) -> [WeeklyPlanInput] {
    (0..<count).map { index in
      var inner = SeededRandom(seed: seed &+ UInt64(bitPattern: Int64(index)) &+ 0x517CC1B727220A95)
      return HouseholdGenerator.oneState(&inner, index: index)
    }
  }

  static func oneState(_ rng: inout SeededRandom, index: Int) -> WeeklyPlanInput {
    let recipeCount = rng.nextInt(2, 8)
    let slotCount = rng.nextInt(1, 3)

    // Ingredient pool 1...40, referenced by id everywhere.
    let ingredientIds = (1...40).map { Int64($0) }

    // Diet class: sometimes constrain, then tag recipes accordingly.
    let dietClasses: [String?] = [nil, "vegan", "vegetarian", "keto"]
    let requiredDiet = dietClasses[rng.nextInt(0, dietClasses.count - 1)]

    // Hard exclusions: 0-2 ingredient ids the plan may never require.
    var excludedIds: Set<Int64> = []
    if rng.chance(0.45) {
      let excludedCount = rng.nextInt(1, 2)
      for _ in 0..<excludedCount {
        if let id = rng.pick(ingredientIds) { excludedIds.insert(id) }
      }
    }

    // Recipes.
    var recipes: [WeeklyPlanRecipe] = []
    for r in 0..<recipeCount {
      let recipeId = Int64(1000 + r)
      let needCount = rng.nextInt(2, 5)
      var needs: [WeeklyPlanNeed] = []
      var usedIngredients: Set<Int64> = []
      for _ in 0..<needCount {
        guard let base = rng.pick(ingredientIds), !usedIngredients.contains(base) else { continue }
        usedIngredients.insert(base)
        let grams = Double(rng.nextInt(20, 400))
        let isOptional = rng.chance(0.25)
        var substitutes: [Int64] = []
        if rng.chance(0.3), let sub = rng.pick(ingredientIds), sub != base,
          !usedIngredients.contains(sub)
        {
          substitutes.append(sub)
        }
        needs.append(
          WeeklyPlanNeed(
            ingredientId: base, gramsPerServing: grams, isOptional: isOptional,
            substitutes: substitutes))
      }
      guard needs.count >= 1 else { continue }

      var dietClass: String? = nil
      if let required = requiredDiet {
        // Most recipes match the required class; some deliberately do not so
        // eligibility filtering has teeth.
        dietClass =
          rng.chance(0.75) ? required : ["vegan", "vegetarian", "keto", nil][rng.nextInt(0, 3)]
      }
      let timeMinutes = rng.nextInt(10, 90)

      recipes.append(
        WeeklyPlanRecipe(
          id: recipeId, title: "Recipe-\(index)-\(recipeId)", timeMinutes: timeMinutes,
          dietClass: dietClass, needs: needs))
    }
    if recipes.isEmpty {
      // Degenerate draw: force a minimal recipe so the state is still valid.
      recipes.append(
        WeeklyPlanRecipe(
          id: 1000, title: "Recipe-\(index)-1000", timeMinutes: 30, dietClass: nil,
          needs: [WeeklyPlanNeed(ingredientId: 1, gramsPerServing: 100, isOptional: false, substitutes: [])]))
    }

    // Slots.
    let slotLabels = ["Monday dinner", "Tuesday lunch", "Wednesday dinner"]
    let slots = (0..<slotCount).map { WeeklyPlanSlot(id: Int64(10 + $0), label: slotLabels[$0]) }

    // Stock: cover every referenced ingredient with a mix of ample, short,
    // zero, and unknown-quantity entries, plus a few unused extras.
    var stock: [WeeklyPlanStockItem] = []
    var usedExtras = Set<Int64>()
    var referencedIds = Set<Int64>()
    for recipe in recipes {
      for need in recipe.needs {
        referencedIds.insert(need.ingredientId)
        for sub in need.substitutes { referencedIds.insert(sub) }
      }
    }
    for id in referencedIds.sorted() {
      let roll = rng.nextDouble()
      let quantityKnown = !(roll < 0.2)  // ~20% unknown amounts
      let amount: Double
      if !quantityKnown {
        amount = 0
      } else if roll < 0.45 {
        amount = 0  // known empty: definite shortage
      } else if roll < 0.65 {
        amount = Double(rng.nextInt(10, 120))  // likely short
      } else {
        amount = Double(rng.nextInt(400, 2000))  // ample
      }
      stock.append(
        WeeklyPlanStockItem(ingredientId: id, availableGrams: amount, quantityIsKnown: quantityKnown))
    }
    for _ in 0..<rng.nextInt(0, 4) {
      if let id = rng.pick(ingredientIds), !referencedIds.contains(id),
        usedExtras.insert(id).inserted
      {
        stock.append(
          WeeklyPlanStockItem(
            ingredientId: id, availableGrams: Double(rng.nextInt(50, 900)), quantityIsKnown: true))
      }
    }

    // Urgency weights for a third of referenced ingredients (use-soon pull).
    var urgency: [Int64: Double] = [:]
    for id in referencedIds.sorted() where rng.chance(0.33) {
      urgency[id] = 0.001 + rng.nextDouble() * 0.009
    }

    let constraints = WeeklyPlanConstraints(
      excludedIngredientIds: excludedIds,
      requiredDietClass: requiredDiet,
      maxCookTimeMinutes: rng.chance(0.5) ? rng.nextInt(20, 60) : nil,
      servingsPerMeal: rng.nextInt(1, 4),
      maxRepeatsPerRecipe: rng.nextInt(1, 3))

    return WeeklyPlanInput(
      slots: slots, recipes: recipes, stock: stock,
      urgencies: urgency.map { WeeklyPlanUrgency(ingredientId: $0.key, weightPerGram: $0.value) },
      constraints: constraints)
  }

  /// A constructed state where every feasible-looking plan requires an
  /// excluded ingredient: the only recipe's required need has its primary and
  /// sole substitute both excluded. The planner must return infeasible and
  /// must never waive the exclusion.
  public static func waiverTemptation(excluded: Int64 = 7, sub: Int64 = 8) -> WeeklyPlanInput {
    let recipe = WeeklyPlanRecipe(
      id: 2000, title: "Temptation", timeMinutes: 30, dietClass: nil,
      needs: [
        WeeklyPlanNeed(ingredientId: excluded, gramsPerServing: 100, isOptional: false, substitutes: [sub])
      ])
    let slot = WeeklyPlanSlot(id: 1, label: "Dinner")
    let stock = [
      WeeklyPlanStockItem(ingredientId: excluded, availableGrams: 5_000, quantityIsKnown: true),
      WeeklyPlanStockItem(ingredientId: sub, availableGrams: 5_000, quantityIsKnown: true),
    ]
    return WeeklyPlanInput(
      slots: [slot], recipes: [recipe], stock: stock,
      constraints: WeeklyPlanConstraints(
        excludedIngredientIds: [excluded, sub], requiredDietClass: nil,
        maxCookTimeMinutes: nil, servingsPerMeal: 2, maxRepeatsPerRecipe: 1))
  }
}
