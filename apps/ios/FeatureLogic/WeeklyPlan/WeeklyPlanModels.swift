import Foundation

// MARK: - Weekly planning core (pure, deterministic)
//
// This directory is the single source of truth for weekly-plan feasibility and
// selection. It is deliberately Foundation-only: no GRDB, no UIKit, no app
// types, so the `weekly-plan-check` tool package can compile it unchanged via
// the `WeeklyPlanCore` symlink and run it on Linux.
//
// Ownership boundaries (do not grow silently):
// - No database migrations (the shared registrar in Migrations.swift is not
//   touched); persistence is a standalone JSON plan store.
// - No repository queries; callers adapt app models into these inputs.
// - Selections neither reserve nor consume stock, and there is no purchase
//   integration. Planning is read-only over the household snapshot it is given.

// MARK: - Inputs

/// One ingredient a recipe needs, per single serving.
///
/// `isOptional` needs may come up short without breaking feasibility; required
/// needs must be fully covered by known-quantity stock (or a substitute).
public struct WeeklyPlanNeed: Sendable, Equatable, Codable {
  public var ingredientId: Int64
  public var gramsPerServing: Double
  /// `true` for garnish-style items: a shortfall is reported, never fatal.
  public var isOptional: Bool
  /// Allowed substitute ingredient IDs in preference order (after the primary).
  /// Substitution is planned 1:1 by grams.
  public var substitutes: [Int64]

  public init(ingredientId: Int64, gramsPerServing: Double, isOptional: Bool = false, substitutes: [Int64] = []) {
    self.ingredientId = ingredientId
    self.gramsPerServing = gramsPerServing
    self.isOptional = isOptional
    self.substitutes = substitutes
  }
}

/// One recipe offered to the planner.
///
/// `dietClass` is the canonical diet ID the recipe satisfies (e.g. "vegan"),
/// or nil for an unrestricted recipe. When the constraints carry a required
/// diet, only recipes whose class matches are eligible; diet-related excluded
/// ingredient IDs also arrive through the hard exclusion set.
public struct WeeklyPlanRecipe: Sendable, Equatable, Codable {
  public var id: Int64
  public var title: String
  public var timeMinutes: Int
  public var dietClass: String?
  public var needs: [WeeklyPlanNeed]

  public init(id: Int64, title: String, timeMinutes: Int, dietClass: String? = nil, needs: [WeeklyPlanNeed]) {
    self.id = id
    self.title = title
    self.timeMinutes = timeMinutes
    self.dietClass = dietClass
    self.needs = needs
  }
}

/// One household stock row. `quantityIsKnown == false` is a photo-intake guess
/// the user never confirmed: it cannot back feasibility, whatever its amount.
public struct WeeklyPlanStockItem: Sendable, Equatable, Codable {
  public var ingredientId: Int64
  public var availableGrams: Double
  public var quantityIsKnown: Bool

  public init(ingredientId: Int64, availableGrams: Double, quantityIsKnown: Bool = true) {
    self.ingredientId = ingredientId
    self.availableGrams = availableGrams
    self.quantityIsKnown = quantityIsKnown
  }
}

/// Use-soon urgency for one ingredient, in objective points per gram consumed.
/// The app derives it from expiry dates (sooner = higher); the planner only
/// multiplies and sums. Zero for anything not expiring in the use-soon window.
public struct WeeklyPlanUrgency: Sendable, Equatable, Codable {
  public var ingredientId: Int64
  public var weightPerGram: Double

  public init(ingredientId: Int64, weightPerGram: Double) {
    self.ingredientId = ingredientId
    self.weightPerGram = weightPerGram
  }
}

/// One meal slot in the week (e.g. Monday dinner). Order matters: it is the
/// deterministic order slots are filled and consumption is allocated in.
public struct WeeklyPlanSlot: Sendable, Equatable, Codable {
  public var id: Int64
  public var label: String

  public init(id: Int64, label: String) {
    self.id = id
    self.label = label
  }
}

// MARK: - Constraints

/// Hard and soft constraints. Anything in `excludedIngredientIds` is HARD:
/// allergen groups ∪ individual exclusions ∪ diet-excluded IDs, computed by the
/// caller with `AllergenExclusions`/`HealthProfile`. The planner can never waive
/// these to improve a score — an otherwise-optimal plan that needs an excluded
/// required ingredient is infeasible, full stop.
public struct WeeklyPlanConstraints: Sendable, Equatable {
  /// Hard exclusions: no required need may resolve (primary or substitute) to
  /// any of these IDs.
  public var excludedIngredientIds: Set<Int64>
  /// When set, only recipes with this `dietClass` are eligible.
  public var requiredDietClass: String?
  /// Per-slot active cook-time ceiling in minutes; nil = no ceiling.
  public var maxCookTimeMinutes: Int?
  /// Servings cooked per meal. Need grams scale linearly with it.
  public var servingsPerMeal: Int
  /// How many slots one recipe may appear in. 1 = no repetition; 0 is
  /// normalized to 1.
  public var maxRepeatsPerRecipe: Int

  public init(
    excludedIngredientIds: Set<Int64> = [],
    requiredDietClass: String? = nil,
    maxCookTimeMinutes: Int? = nil,
    servingsPerMeal: Int = 2,
    maxRepeatsPerRecipe: Int = 1
  ) {
    self.excludedIngredientIds = excludedIngredientIds
    self.requiredDietClass = requiredDietClass
    self.maxCookTimeMinutes = maxCookTimeMinutes
    self.servingsPerMeal = max(1, servingsPerMeal)
    self.maxRepeatsPerRecipe = max(1, maxRepeatsPerRecipe)
  }
}

// MARK: - Objective

/// Objective weights. The score of an assignment is
///
///     useSoonWeight × Σ(urgency × grams consumed)
///   − timeWeightPerMinute × Σ(recipe minutes)
///   − repetitionPenalty × (extra uses of a recipe beyond its first)
///
/// Use-soon coverage is the point: the time and repetition terms are tie-break
/// shaped, not goals of their own. Nutrient goals are NOT in this objective —
/// they are user preferences surfaced in the UI, never outcomes the optimizer
/// claims to achieve.
public struct WeeklyPlanObjective: Sendable, Equatable {
  public var useSoonWeight: Double
  public var timeWeightPerMinute: Double
  public var repetitionPenalty: Double

  public init(useSoonWeight: Double = 1.0, timeWeightPerMinute: Double = 0.05, repetitionPenalty: Double = 2.0) {
    self.useSoonWeight = useSoonWeight
    self.timeWeightPerMinute = timeWeightPerMinute
    self.repetitionPenalty = repetitionPenalty
  }
}

// MARK: - Results

public enum WeeklyPlanShortageCategory: String, Sendable, Codable, CaseIterable {
  /// A required ingredient with no stock at all.
  case missing
  /// Known stock exists but does not cover the planned grams.
  case shortQuantity = "short_quantity"
  /// Stock exists only as an unconfirmed estimate; it cannot back feasibility.
  case unknownAmount = "unknown_amount"
  /// The plan cooks a substitute in place of the planned ingredient.
  case substituted
}

/// One grouped shortage row: everything the plan needs for an ingredient,
/// aggregated over slots, with the resolution the plan assumes.
public struct WeeklyPlanShortage: Sendable, Equatable, Codable {
  public var ingredientId: Int64
  public var category: WeeklyPlanShortageCategory
  /// Total grams the accepted plan would need (scaled to meal servings).
  public var neededGrams: Double
  /// Known-quantity grams available at planning time.
  public var availableGrams: Double
  /// `needed − available` clamped at zero; zero for unknown-amount rows.
  public var shortfallGrams: Double
  /// Recipes whose plans touch this ingredient.
  public var affectedRecipeIds: [Int64]
  /// Substitute the plan would cook instead, when applicable.
  public var substituteIngredientId: Int64?

  public init(
    ingredientId: Int64, category: WeeklyPlanShortageCategory, neededGrams: Double,
    availableGrams: Double, shortfallGrams: Double, affectedRecipeIds: [Int64],
    substituteIngredientId: Int64? = nil
  ) {
    self.ingredientId = ingredientId
    self.category = category
    self.neededGrams = neededGrams
    self.availableGrams = availableGrams
    self.shortfallGrams = shortfallGrams
    self.affectedRecipeIds = affectedRecipeIds
    self.substituteIngredientId = substituteIngredientId
  }
}

/// Why a slot could not be filled, in deterministic, stable wording.
public enum WeeklyPlanViolation: Sendable, Equatable {
  case noEligibleRecipe(slotId: Int64)
  case excludedIngredientRequired(recipeId: Int64, ingredientId: Int64)
  case dietClassMismatch(recipeId: Int64)
  case cookTimeExceeded(recipeId: Int64, slotId: Int64)
  case insufficientStock(ingredientId: Int64, shortfallGrams: Double)
  case unknownAmountCannotCover(ingredientId: Int64)
}

public enum WeeklyPlanVerdict: Sendable, Equatable {
  case feasible
  case infeasible([WeeklyPlanViolation])
}

/// One slot's planned meal, with any substitutions the plan assumes.
public struct WeeklyPlanSlotAssignment: Sendable, Equatable, Codable {
  public var slotId: Int64
  public var slotLabel: String
  public var recipeId: Int64
  public var recipeTitle: String
  public var timeMinutes: Int
  /// (planned ingredient → substitute actually used), empty when none.
  public var substitutions: [WeeklyPlanSubstitution]
  /// Servings this slot cooks.
  public var servings: Int

  public init(
    slotId: Int64, slotLabel: String, recipeId: Int64, recipeTitle: String,
    timeMinutes: Int, substitutions: [WeeklyPlanSubstitution], servings: Int
  ) {
    self.slotId = slotId
    self.slotLabel = slotLabel
    self.recipeId = recipeId
    self.recipeTitle = recipeTitle
    self.timeMinutes = timeMinutes
    self.substitutions = substitutions
    self.servings = servings
  }
}

public struct WeeklyPlanSubstitution: Sendable, Equatable, Codable {
  public var plannedIngredientId: Int64
  public var substituteIngredientId: Int64

  public init(plannedIngredientId: Int64, substituteIngredientId: Int64) {
    self.plannedIngredientId = plannedIngredientId
    self.substituteIngredientId = substituteIngredientId
  }
}

/// Everything the planner produces for one household snapshot.
public struct WeeklyPlanResult: Sendable, Equatable {
  public var verdict: WeeklyPlanVerdict
  /// Empty when infeasible.
  public var assignments: [WeeklyPlanSlotAssignment]
  /// Grouped shortages for the produced plan (feasible) or the reasons it
  /// cannot exist (infeasible ⇒ empty; see `verdict`).
  public var shortages: [WeeklyPlanShortage]
  /// Objective value of the produced plan; 0 when infeasible.
  public var score: Double
  /// Fingerprint of the exact inputs that produced this plan.
  public var inputFingerprint: String
}
