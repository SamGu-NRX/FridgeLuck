import Foundation

// MARK: - Deterministic planning engine
//
// Depth-first search over slots in order, with a single sound pruning rule: a
// partial assignment whose prefix allocation already fails a required need
// cannot be completed (allocation is sequential in slot order, so prefix rows
// never change when later slots are appended). No score-based pruning anywhere
// — an epsilon tie resolves lexicographically, and a score bound could drop
// the lexicographic winner.
//
// Within the exact domain (`isExactDomain`, ≤ 6 recipes × ≤ 3 slots) the DFS
// visits every admissible assignment, so its result is identical to the
// brute-force oracle's, which tests and the eval harness verify.
//
// Beyond the exact domain (the full bundled catalog), branching per slot is
// capped to the top candidates by a static heuristic, still fully
// deterministic. Optimality is only guaranteed inside the exact domain; the
// UI states this plainly.

public enum WeeklyPlanEngine {

  public static let exactDomainMaxRecipes = 6
  public static let exactDomainMaxSlots = 3
  /// Per-slot candidate cap when planning beyond the exact domain.
  public static let wideCatalogBeamWidth = 4

  public static func isExactDomain(recipeCount: Int, slotCount: Int) -> Bool {
    recipeCount <= exactDomainMaxRecipes && slotCount <= exactDomainMaxSlots
  }

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

    let exact = isExactDomain(recipeCount: recipes.count, slotCount: slots.count)
    let candidatesForSlot = candidateOrder(recipes: recipes, input: input, exact: exact)

    var bestScore = 0.0
    var bestIDs: [Int64]? = nil
    var bestRows: [WeeklyPlanConsumptionRow] = []
    var bestAssignment: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = []

    var current: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)] = []
    var currentIDs: [Int64] = []
    var usedCounts: [Int64: Int] = [:]

    func prefixIsSound(rows: [WeeklyPlanConsumptionRow]) -> Bool {
      // Required shortfalls in a prefix are final — prune the whole branch.
      WeeklyPlanConsumption.isFeasible(rows: rows)
    }

    func walk(slotIndex: Int) {
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
      let candidates = candidatesForSlot[slot.id] ?? []
      let branch = exact ? candidates : Array(candidates.prefix(wideCatalogBeamWidth))
      for recipe in branch {
        let used = usedCounts[recipe.id] ?? 0
        guard used < input.constraints.maxRepeatsPerRecipe else { continue }

        current.append((slot, recipe))
        currentIDs.append(recipe.id)
        usedCounts[recipe.id, default: 0] += 1

        // Prune on the prefix allocation when it already fails a required need.
        if exact {
          let prefixRows = WeeklyPlanConsumption.allocate(
            assignment: current, stock: stockByID, constraints: input.constraints)
          if prefixIsSound(rows: prefixRows) {
            walk(slotIndex: slotIndex + 1)
          }
        } else {
          walk(slotIndex: slotIndex + 1)
        }

        usedCounts[recipe.id, default: 0] -= 1
        if usedCounts[recipe.id] == 0 { usedCounts[recipe.id] = nil }
        current.removeLast()
        currentIDs.removeLast()
      }
    }

    walk(slotIndex: 0)

    guard let bestIDs else {
      return WeeklyPlanResult(
        verdict: .infeasible(WeeklyPlanOracle.diagnose(input: input, recipes: recipes)),
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

  /// Deterministic per-slot candidate order: recipe id ascending within the
  /// exact domain; beyond it, by static desirability (urgency potential minus
  /// time), then id — the beam keeps a bounded search over big catalogs.
  static func candidateOrder(
    recipes: [WeeklyPlanRecipe], input: WeeklyPlanInput, exact: Bool
  ) -> [Int64: [WeeklyPlanRecipe]] {
    let urgencyByIngredient = input.urgencyByIngredient
    var order: [Int64: [WeeklyPlanRecipe]] = [:]

    for slot in input.slots {
      let eligible = recipes.filter { WeeklyPlanOracle.eligibilityFailure(of: $0, slotId: slot.id, input: input) == nil }
      if exact {
        order[slot.id] = eligible
      } else {
        let ranked = eligible.sorted { a, b in
          let sa = desirability(of: a, urgencies: urgencyByIngredient)
          let sb = desirability(of: b, urgencies: urgencyByIngredient)
          if sa != sb { return sa > sb }
          return a.id < b.id
        }
        order[slot.id] = ranked
      }
    }
    return order
  }

  static func desirability(of recipe: WeeklyPlanRecipe, urgencies: [Int64: Double]) -> Double {
    var potential = 0.0
    for need in recipe.needs {
      let weight = urgencies[need.ingredientId]
        ?? urgencies[need.substitutes.first ?? -1]
        ?? 0
      potential += weight * need.gramsPerServing
    }
    return potential - Double(recipe.timeMinutes) * 0.01
  }
}
