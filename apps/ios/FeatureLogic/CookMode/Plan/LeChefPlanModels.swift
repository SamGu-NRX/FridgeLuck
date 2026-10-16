import Foundation

/// Output model of the LeChef plan job (SPEC.md §7, `contracts/plan.schema.json`).
///
/// A plan is a frozen decision record: dinners in cook order, every ingredient line carrying one
/// of the five pantry-truth states, and a shopping list that is the merged shortfall across all
/// dinners. The fit line renders from line states only — never a percentage.
///
/// Recipe identity uses the shared `RecipeRef` contract ({source, id, revision}) from
/// FeatureLogic/Recipe/RecipeBundleV2.swift — its source enum is a superset of the plan
/// contract's (adds `generated`), and raw values are unchanged, so the wire form matches
/// `contracts/plan.schema.json`.

/// Pantry-truth state of one ingredient line (PR #86 §3.2, binding).
public enum PlanLineState: String, Equatable, Sendable, Codable {
  /// Stock covers the full requirement, from confirmed (non-estimate) lots.
  case sufficient
  /// Stock covers part of the requirement; `short` carries the missing amount.
  case short
  /// The recipe line carries no usable quantity. Never sufficient, never a buy amount.
  case quantityUnknown = "quantity_unknown"
  /// No stock at all, but the household marks the ingredient as always/usually on hand.
  case assumedStaple = "assumed_staple"
  /// The requirement is covered, but only by unconfirmed (photo-estimate) lots.
  case needsReconfirming = "needs_reconfirming"
}

/// An amount in grams. The whole plan works in grams because the inventory does.
public struct PlanQuantity: Equatable, Sendable, Codable {
  public let value: Double
  public let unit: String

  public init(value: Double, unit: String = "g") {
    self.value = value
    self.unit = unit
  }

  /// Grams rounded up to a whole gram, for display ("200 g").
  public var displayText: String {
    "\(Int(value.rounded(.up))) \(unit)"
  }
}

/// A substitution applied to one line while allocating.
public struct PlanSwap: Equatable, Sendable, Codable {
  public let originalID: Int64
  public let substituteID: Int64
  public let note: String?
  public let reviewed: Bool

  public init(originalID: Int64, substituteID: Int64, note: String?, reviewed: Bool) {
    self.originalID = originalID
    self.substituteID = substituteID
    self.note = note
    self.reviewed = reviewed
  }
}

/// One ingredient line of a planned dinner, with its pantry-truth state.
public struct PlanLine: Equatable, Sendable, Codable {
  public let ingredientID: Int64
  public let name: String
  /// Optional garnish lines make no availability claim: they never count in the fit line and
  /// never enter the shopping list (the recipe search treats optional rows the same way).
  public let isRequired: Bool
  /// `nil` exactly when the line state is `quantity_unknown`.
  public let required: PlanQuantity?
  public let lineState: PlanLineState
  /// Present exactly when the line state is `short`.
  public let short: PlanQuantity?
  public let swap: PlanSwap?

  public init(
    ingredientID: Int64, name: String, isRequired: Bool, required: PlanQuantity?,
    lineState: PlanLineState, short: PlanQuantity?, swap: PlanSwap?
  ) {
    self.ingredientID = ingredientID
    self.name = name
    self.isRequired = isRequired
    self.required = required
    self.lineState = lineState
    self.short = short
    self.swap = swap
  }
}

/// One planned dinner in cook order.
public struct PlannedDinner: Equatable, Sendable, Codable {
  public let position: Int
  public let dinnerID: String
  public let recipe: RecipeRef
  /// The app's `recipes.id`, for adapters and re-allocation after cooking.
  public let recipeDatabaseID: Int64
  public let title: String
  public let servings: Int
  public let timeMinutes: Int?
  public let lines: [PlanLine]
  /// Weekly horizon (§14 on #52): for a leftovers night, the dinner whose surplus covers this
  /// slot. `nil` for a freshly planned dinner. Leftovers nights carry no lines of their own.
  public let leftoverOfDinnerID: String?

  public init(
    position: Int, dinnerID: String, recipe: RecipeRef, recipeDatabaseID: Int64, title: String,
    servings: Int, timeMinutes: Int?, lines: [PlanLine], leftoverOfDinnerID: String? = nil
  ) {
    self.position = position
    self.dinnerID = dinnerID
    self.recipe = recipe
    self.recipeDatabaseID = recipeDatabaseID
    self.title = title
    self.servings = servings
    self.timeMinutes = timeMinutes
    self.lines = lines
    self.leftoverOfDinnerID = leftoverOfDinnerID
  }
}

/// One merged shortfall row of the shopping list.
public struct ShoppingLine: Equatable, Sendable, Codable {
  public let ingredientID: Int64
  public let name: String
  public let amount: PlanQuantity
  /// Staples the household marks as always/usually on hand appear struck through.
  public let assumedStaple: Bool

  public init(ingredientID: Int64, name: String, amount: PlanQuantity, assumedStaple: Bool) {
    self.ingredientID = ingredientID
    self.name = name
    self.amount = amount
    self.assumedStaple = assumedStaple
  }
}

/// Aggregate over the plan's line states. The fit line renders from this only.
public struct PlanFitSummary: Equatable, Sendable, Codable {
  public let sufficientLines: Int
  public let totalLines: Int
  public let swapCount: Int
  /// Ingredient names to check, when not every required line is sufficient.
  public let attention: [String]?

  public init(sufficientLines: Int, totalLines: Int, swapCount: Int, attention: [String]?) {
    self.sufficientLines = sufficientLines
    self.totalLines = totalLines
    self.swapCount = swapCount
    self.attention = attention
  }
}

/// The complete plan output. 1–7 dinners per the contract; an empty dinner list is the
/// nothing-feasible outcome and is a view-model state, not a persisted plan.
public struct LeChefPlan: Equatable, Sendable, Codable {
  public let planID: String
  public let createdAt: Date
  public let dinners: [PlannedDinner]
  public let shoppingList: [ShoppingLine]
  public let fitSummary: PlanFitSummary

  public init(
    planID: String, createdAt: Date, dinners: [PlannedDinner], shoppingList: [ShoppingLine],
    fitSummary: PlanFitSummary
  ) {
    self.planID = planID
    self.createdAt = createdAt
    self.dinners = dinners
    self.shoppingList = shoppingList
    self.fitSummary = fitSummary
  }

  /// The plan sheet's fit line, built from line states only (PR #86 §3.2: never a percentage).
  /// "9 of 10 · 1 swap" only when every required line is truly sufficient; otherwise
  /// "7 recorded · check eggs and oil".
  public var fitLineDescription: String {
    let requiredLines = dinners.flatMap { dinner in dinner.lines.filter { $0.isRequired } }
    guard !requiredLines.isEmpty else { return "" }
    let summary = fitSummary
    if summary.sufficientLines == summary.totalLines {
      var text = "\(summary.sufficientLines) of \(summary.totalLines)"
      if summary.swapCount > 0 {
        text += summary.swapCount == 1 ? " · 1 swap" : " · \(summary.swapCount) swaps"
      }
      return text
    }
    let names = (summary.attention ?? []).prefix(3)
    let check = names.joined(separator: " and ")
    return check.isEmpty ? "\(summary.sufficientLines) recorded" : "\(summary.sufficientLines) recorded · check \(check)"
  }
}
