import Foundation

// MARK: - Exact brute-force reference oracle
//
// Enumerates every recipe-to-slot assignment (respecting the repetition cap)
// and evaluates each one from first principles. No pruning, no heuristics —
// that is the point: within the guaranteed domain (≤ 6 recipes, ≤ 3 slots, so
// at most 6^3 = 216 assignments) it is the definition of "best feasible plan"
// that the engine must reproduce. Do not make it smarter; make the engine
// agree with it.

public enum WeeklyPlanOracle {

  /// Exhaustive search. Intended for the guaranteed domain; callers with
  /// larger catalogs should use `WeeklyPlanEngine`, and may use this as a
  /// reference with small catalogs only.
  public static func plan(_ input: WeeklyPlanInput) -> WeeklyPlanResult {
    let fingerprint = WeeklyPlanFingerprint.compute(input)
    let stockByID = input.stockByID
    let urgencyByIngredient = input.urgencyByIngredient

    let recipes = input.recipes.sorted { $0.id < $1.id }
    let slots = input.slots

    guard !slots.isEmpty, !recipes.isEmpty else {
      return WeeklyPlanResult(
        verdict: .infeasible([.noEligibleRecipe(slotId: slots.first?.id ?? -1)]),
        assignments: [], shortages: [], score: 0, inputFingerprint: fingerprint)
    }

    var bestScore = 0.0
    var bestIDs: [Int64]? = nil
    var bestRows: [WeeklyPlanConsumptionRow] = []
    var bestAssignment: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = []

    // Enumerate the full product, honoring the repetition cap.
    var current: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = []
    var currentIDs: [Int64] = []

    func walk(slotIndex: Int, uses: [Int64: Int]) {
      if slotIndex == slots.count {
        let rows = WeeklyPlanConsumption.allocate(
          assignment: current, stock: stockByID, constraints: input.constraints)
        guard WeeklyPlanConsumption.isFeasible(rows: rows) else { return }
        let score = WeeklyPlanConsumption.score(
          rows: rows, assignment: current, urgencies: urgencyByIngredient,
          objective: input.objective)
        if WeeklyPlanSearch.prefer(score, currentIDs, over: bestScore, bestIDs) {
          bestScore = score
          bestIDs = currentIDs
          bestRows = rows
          bestAssignment = current
        }
        return
      }

      let slot = slots[slotIndex]
      for recipe in recipes {
        // Eligibility (diet class, cook-time ceiling, hard exclusions) filters
        // enumeration exactly like the engine's per-slot candidate order.
        if eligibilityFailure(of: recipe, slotId: slot.id, input: input) != nil { continue }
        let used = uses[recipe.id] ?? 0
        guard used < input.constraints.maxRepeatsPerRecipe else { continue }
        current.append((slot, recipe))
        currentIDs.append(recipe.id)
        var nextUses = uses
        nextUses[recipe.id, default: 0] += 1
        walk(slotIndex: slotIndex + 1, uses: nextUses)
        current.removeLast()
        currentIDs.removeLast()
      }
    }

    walk(slotIndex: 0, uses: [:])

    guard let bestIDs else {
      return WeeklyPlanResult(
        verdict: .infeasible(diagnose(input: input, recipes: recipes)),
        assignments: [], shortages: [], score: 0, inputFingerprint: fingerprint)
    }

    return WeeklyPlanResult(
      verdict: .feasible,
      assignments: WeeklyPlanSearch.assignments(
        from: bestAssignment, rows: bestRows, servings: input.constraints.servingsPerMeal),
      shortages: WeeklyPlanSearch.shortages(rows: bestRows, stock: stockByID),
      score: bestScore,
      inputFingerprint: fingerprint)
  }

  /// Deterministic diagnosis of why nothing is feasible. Diagnostic wording
  /// only — the verdict (infeasible) never depends on it.
  static func diagnose(input: WeeklyPlanInput, recipes: [WeeklyPlanRecipe]) -> [WeeklyPlanViolation] {
    var violations: [WeeklyPlanViolation] = []
    let stockByID = input.stockByID

    var eligibleCounts: [Int64: Int] = [:]
    var reportedRecipes = Set<Int64>()

    for slot in input.slots {
      var eligible = 0
      for recipe in recipes {
        if let reason = eligibilityFailure(of: recipe, slotId: slot.id, input: input) {
          switch reason {
          case .dietClassMismatch:
            if !reportedRecipes.contains(recipe.id) {
              reportedRecipes.insert(recipe.id)
              violations.append(.dietClassMismatch(recipeId: recipe.id))
            }
          case .cookTimeExceeded:
            if !reportedRecipes.contains(recipe.id) {
              reportedRecipes.insert(recipe.id)
              violations.append(.cookTimeExceeded(recipeId: recipe.id, slotId: slot.id))
            }
          case .excludedIngredientRequired:
            if !reportedRecipes.contains(recipe.id) {
              reportedRecipes.insert(recipe.id)
              violations.append(reason)
            }
          case .noEligibleRecipe, .insufficientStock, .unknownAmountCannotCover:
            break
          }
          continue
        }
        eligible += 1
      }
      eligibleCounts[slot.id] = eligible
      if eligible == 0 {
        violations.append(.noEligibleRecipe(slotId: slot.id))
      }
    }

    // Stock-shaped failures: allocate a greedy assignment of the first
    // eligible recipe per slot and report its shortfalls.
    if eligibleCounts.values.allSatisfy({ $0 > 0 }) {
      let greedy: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = input.slots.compactMap { slot in
        let candidates = recipes.filter { eligibilityFailure(of: $0, slotId: slot.id, input: input) == nil }
        guard let first = candidates.first else { return nil }
        return (slot, first)
      }
      if greedy.count == input.slots.count {
        let rows = WeeklyPlanConsumption.allocate(
          assignment: greedy, stock: stockByID, constraints: input.constraints)
        for row in rows where row.isRequired && row.shortfallGrams > 1e-9 {
          if row.unresolvableExcluded {
            violations.append(
              .excludedIngredientRequired(recipeId: row.recipeId, ingredientId: row.ingredientId))
          } else if stockByID[row.ingredientId]?.quantityIsKnown != true {
            violations.append(.unknownAmountCannotCover(ingredientId: row.ingredientId))
          } else {
            violations.append(
              .insufficientStock(ingredientId: row.ingredientId, shortfallGrams: row.shortfallGrams))
          }
        }
      }
    }

    if violations.isEmpty {
      violations = input.slots.map { .noEligibleRecipe(slotId: $0.id) }
    }
    return violations.sorted { describe($0) < describe($1) }
  }

  /// nil when the recipe may fill the slot; otherwise the reason it may not.
  /// Stock feasibility is intentionally NOT part of this check — allocation
  /// owns it.
  static func eligibilityFailure(
    of recipe: WeeklyPlanRecipe, slotId: Int64, input: WeeklyPlanInput
  ) -> WeeklyPlanViolation? {
    if let required = input.constraints.requiredDietClass, recipe.dietClass != required {
      return .dietClassMismatch(recipeId: recipe.id)
    }
    if let ceiling = input.constraints.maxCookTimeMinutes, recipe.timeMinutes > ceiling {
      return .cookTimeExceeded(recipeId: recipe.id, slotId: slotId)
    }
    for need in recipe.needs where !need.isOptional {
      let candidates = [need.ingredientId] + need.substitutes
      if candidates.allSatisfy({ input.constraints.excludedIngredientIds.contains($0) }) {
        return .excludedIngredientRequired(recipeId: recipe.id, ingredientId: need.ingredientId)
      }
    }
    return nil
  }

  private static func describe(_ violation: WeeklyPlanViolation) -> String {
    switch violation {
    case .noEligibleRecipe(let slot): return "noEligibleRecipe \(slot)"
    case .excludedIngredientRequired(let r, let i): return "excluded \(r) \(i)"
    case .dietClassMismatch(let r): return "diet \(r)"
    case .cookTimeExceeded(let r, let s): return "time \(r) \(s)"
    case .insufficientStock(let i, _): return "stock \(i)"
    case .unknownAmountCannotCover(let i): return "unknown \(i)"
    }
  }
}
