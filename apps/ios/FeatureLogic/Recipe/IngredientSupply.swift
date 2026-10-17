import Foundation

/// What the kitchen holds of one ingredient, summed over its open inventory lots.
///
/// Estimated grams come from lots flagged `quantity_is_estimate` (photo intake guesses); they
/// are kept apart because an estimate never proves there is enough.
public struct OnHandStock: Equatable, Sendable {
  public var confirmedGrams: Double
  public var estimatedGrams: Double

  public init(confirmedGrams: Double = 0, estimatedGrams: Double = 0) {
    self.confirmedGrams = confirmedGrams
    self.estimatedGrams = estimatedGrams
  }

  public static func + (lhs: OnHandStock, rhs: OnHandStock) -> OnHandStock {
    OnHandStock(
      confirmedGrams: lhs.confirmedGrams + rhs.confirmedGrams,
      estimatedGrams: lhs.estimatedGrams + rhs.estimatedGrams)
  }
}

/// Whether the kitchen covers one required recipe line.
///
/// The recipe search used to call a line "had" whenever the ingredient was present, so 50 g of
/// egg satisfied a recipe needing 100 g and the results said "Complete match" (2026-10-16 walk).
public enum IngredientSupply: Equatable, Sendable {
  /// Confirmed stock covers the amount.
  case have
  /// Confirmed stock falls short of the amount by `grams`, and no estimate could cover it.
  case short(grams: Double)
  /// Some of the stock is an estimate, and the confirmed part alone does not cover the amount,
  /// so the kitchen may or may not have enough.
  case checkAmount
  /// The search didn't have the ingredient at all.
  case missing

  /// Judges one required line.
  ///
  /// - Parameters:
  ///   - requiredGrams: the line's amount for the servings shown, or nil when the recipe states
  ///     no gram amount (nothing to compare, so presence decides).
  ///   - isAvailable: whether the searched ingredient set contains the ingredient.
  ///   - stock: the kitchen's open lots for it, or nil when the kitchen records none. That
  ///     happens for an ingredient confirmed in a scan but not stocked; FridgeLuck has no amount
  ///     to compare there, so presence decides, as it did before amounts were checked.
  public static func judge(
    requiredGrams: Double?,
    isAvailable: Bool,
    stock: OnHandStock?
  ) -> IngredientSupply {
    guard isAvailable else { return .missing }
    guard let requiredGrams, requiredGrams > 0, let stock else { return .have }
    if stock.confirmedGrams >= requiredGrams { return .have }
    if stock.estimatedGrams > 0 { return .checkAmount }
    return .short(grams: requiredGrams - stock.confirmedGrams)
  }
}

/// A required line the kitchen doesn't fully cover, with the ingredient ids that stand for it.
/// A catalog line can stand for several app ingredients; a legacy line stands for one.
public struct InsufficientRequiredLine: Equatable, Sendable {
  public let ingredientIDs: [Int64]
  /// `.short` or `.checkAmount`; `.have` and `.missing` lines are never recorded here.
  public let supply: IngredientSupply
  /// A catalog staple line the kitchen holds short. It is not counted among the recipe's required
  /// lines ("1/1 required"), so it never lowers that count; it only keeps the match from being
  /// complete.
  public let isAssumedStaple: Bool

  public init(ingredientIDs: [Int64], supply: IngredientSupply, isAssumedStaple: Bool = false) {
    self.ingredientIDs = ingredientIDs
    self.supply = supply
    self.isAssumedStaple = isAssumedStaple
  }

  /// Short label for a chip or a row's second line: "Short 50 g" or "Check amount".
  public var label: String {
    switch supply {
    case .short(let grams): "Short \(Self.formatGrams(grams))"
    case .checkAmount: "Check amount"
    case .have, .missing: ""
    }
  }

  /// Whole grams, rounded up so a shortfall of 0.4 g never reads as "Short 0 g".
  public static func formatGrams(_ grams: Double) -> String {
    "\(Int(grams.rounded(.up))) g"
  }
}

/// A required line the kitchen doesn't hold at all, named the way the recipe names it.
///
/// Results used to name a missing line once per app ingredient its catalog key bridges to, so
/// "green onion" (bridged to three ingredients, two of them USDA rows the static lexicon has no
/// name for) read "Green Onion, Unknown, Unknown" under a summary saying "missing 1"
/// (2026-10-16 walk at alpha a32bfe3).
public struct MissingRequiredLine: Equatable, Sendable {
  public let name: String
  /// The app ingredients that stand for the line; empty when no app ingredient does.
  public let ingredientIDs: [Int64]

  public init(name: String, ingredientIDs: [Int64]) {
    self.name = name
    self.ingredientIDs = ingredientIDs
  }
}
