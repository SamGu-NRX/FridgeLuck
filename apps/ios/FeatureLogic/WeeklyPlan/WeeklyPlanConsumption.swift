import Foundation

// MARK: - Consumption semantics (canonical allocator)
//
// Both the search engine and the brute-force oracle evaluate an assignment
// through this allocator, so stock-resolution rules and arithmetic have exactly
// one implementation. What the oracle independently verifies is eligibility and
// optimality of the search — the parts a planner can get wrong — not the
// definition of a gram.

/// Resolution of one need inside one planned slot.
public struct WeeklyPlanConsumptionRow: Sendable, Equatable {
  public var slotId: Int64
  public var recipeId: Int64
  /// The need as planned (primary ingredient).
  public var ingredientId: Int64
  public var isRequired: Bool
  /// Grams the slot would take from the resolved ingredient.
  public var grams: Double
  /// The ingredient actually cooked (substitute, when applied).
  public var resolvedIngredientId: Int64
  public var substituted: Bool
  /// Planned grams that could not be covered. Always 0 for satisfied needs.
  public var shortfallGrams: Double
  /// True when every candidate (primary + substitutes) was hard-excluded.
  /// The row then consumes nothing; a required unresolvable need is infeasible.
  public var unresolvableExcluded: Bool

  public init(
    slotId: Int64, recipeId: Int64, ingredientId: Int64, isRequired: Bool,
    grams: Double, resolvedIngredientId: Int64, substituted: Bool,
    shortfallGrams: Double, unresolvableExcluded: Bool = false
  ) {
    self.slotId = slotId
    self.recipeId = recipeId
    self.ingredientId = ingredientId
    self.isRequired = isRequired
    self.grams = grams
    self.resolvedIngredientId = resolvedIngredientId
    self.substituted = substituted
    self.shortfallGrams = shortfallGrams
    self.unresolvableExcluded = unresolvableExcluded
  }
}

public enum WeeklyPlanConsumption {

  /// Resolves a recipe's ingredient choices for a whole assignment.
  ///
  /// Substitution policy: the primary ingredient if it is not hard-excluded and
  /// its known-quantity stock covers the need; otherwise the first substitute
  /// that is not hard-excluded and covers it; otherwise the first allowed
  /// candidate (substitute inherits the need's optionality). An optional need
  /// with every candidate hard-excluded is dropped; a required one is reported
  /// as an unresolvable row, which makes the plan infeasible.
  ///
  /// Allocation order is canonical: slots in given order, then needs sorted by
  /// ingredient id (ties by grams). Unknown-amount stock never covers anything.
  public static func allocate(
    assignment: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)],
    stock: [Int64: WeeklyPlanStockItem],
    constraints: WeeklyPlanConstraints
  ) -> [WeeklyPlanConsumptionRow] {
    var remaining = stock
    var rows: [WeeklyPlanConsumptionRow] = []
    rows.reserveCapacity(assignment.reduce(0) { $0 + $1.recipe.needs.count })

    for (slot, recipe) in assignment {
      let scaled = recipe.needs
        .map { need in
          WeeklyPlanNeed(
            ingredientId: need.ingredientId,
            gramsPerServing: need.gramsPerServing * Double(constraints.servingsPerMeal),
            isOptional: need.isOptional,
            substitutes: need.substitutes
          )
        }
        .sorted { lhs, rhs in
          if lhs.ingredientId != rhs.ingredientId { return lhs.ingredientId < rhs.ingredientId }
          return lhs.gramsPerServing < rhs.gramsPerServing
        }

      for need in scaled {
        let candidates = [need.ingredientId] + need.substitutes
        let allowed = candidates.filter { !constraints.excludedIngredientIds.contains($0) }

        if allowed.isEmpty {
          // Every candidate is hard-excluded. Nothing is consumed; a required
          // need still surfaces as an unresolvable row so feasibility fails.
          if !need.isOptional {
            rows.append(
              WeeklyPlanConsumptionRow(
                slotId: slot.id, recipeId: recipe.id, ingredientId: need.ingredientId,
                isRequired: true, grams: 0, resolvedIngredientId: need.ingredientId,
                substituted: false, shortfallGrams: need.gramsPerServing,
                unresolvableExcluded: true))
          }
          continue
        }

        // First allowed candidate that fully covers with known-quantity stock.
        var chosen = allowed[0]
        for candidate in allowed {
          if let item = remaining[candidate], item.quantityIsKnown,
            item.availableGrams >= need.gramsPerServing - 1e-9
          {
            chosen = candidate
            break
          }
        }

        let known = remaining[chosen]?.quantityIsKnown == true
        let available = known ? (remaining[chosen]?.availableGrams ?? 0) : 0
        let taken = min(need.gramsPerServing, available)
        let shortfall = need.gramsPerServing - taken

        if known {
          remaining[chosen] = WeeklyPlanStockItem(
            ingredientId: chosen,
            availableGrams: available - taken,
            quantityIsKnown: true)
        }

        rows.append(
          WeeklyPlanConsumptionRow(
            slotId: slot.id,
            recipeId: recipe.id,
            ingredientId: need.ingredientId,
            isRequired: !need.isOptional,
            grams: taken,
            resolvedIngredientId: chosen,
            substituted: chosen != need.ingredientId,
            shortfallGrams: shortfall
          ))
      }
    }
    return rows
  }

  /// Objective value of a fully allocated assignment. Iteration order matches
  /// `allocate`, so engine and oracle sum identically.
  public static func score(
    rows: [WeeklyPlanConsumptionRow],
    assignment: [(slot: WeeklyPlanSlot, recipe: WeeklyPlanRecipe)],
    urgencies: [Int64: Double],
    objective: WeeklyPlanObjective
  ) -> Double {
    var useSoon = 0.0
    for row in rows {
      let weight = urgencies[row.resolvedIngredientId] ?? 0
      useSoon += weight * row.grams
    }

    let timePenalty = objective.timeWeightPerMinute
      * Double(assignment.reduce(0) { $0 + $1.recipe.timeMinutes })

    var uses: [Int64: Int] = [:]
    for (_, recipe) in assignment { uses[recipe.id, default: 0] += 1 }
    let extraUses = uses.values.reduce(0) { $0 + max(0, $1 - 1) }
    let repetition = objective.repetitionPenalty * Double(extraUses)

    return objective.useSoonWeight * useSoon - timePenalty - repetition
  }

  /// Global feasibility over an allocation: every required need fully covered.
  /// Required needs may be satisfied through substitution; shortfalls and
  /// unresolvable exclusions are fatal; optional shortfalls never are.
  public static func isFeasible(rows: [WeeklyPlanConsumptionRow]) -> Bool {
    rows.allSatisfy { row in
      !(row.isRequired && (row.shortfallGrams > 1e-9 || row.unresolvableExcluded))
    }
  }
}
