import Foundation

/// What the recipe preview's leading icon says about one ingredient row.
///
/// The preview used to show a green check on every required ingredient, so an ingredient the
/// results card listed as missing (Cucumber, 2026-10-07 walk) looked like one the user had.
/// The recipe search only knows availability for required ingredients, through the missing IDs
/// it returns; optional and substituted rows make no availability claim.
public enum RecipeIngredientMark: Equatable, Sendable {
  /// Required, among the ingredients the search used, and the kitchen holds enough of it.
  case have
  /// Required and in the kitchen, but confirmed stock is short of the amount by `grams`.
  case short(grams: Double)
  /// Required and in the kitchen, but part of the stock is an estimate, so the amount is unproven.
  case checkAmount
  /// Required, and not among the ingredients the search used.
  case missing
  /// An assumed staple the kitchen doesn't list. The recipe expects most kitchens to keep it,
  /// which is a guess, not a have (sesame oil and butter showed green checks, 2026-10-16 walk).
  case usuallyOnHand
  /// Optional. The search doesn't record whether the user has it.
  case optional
  /// Replaced in the preview. Whether the user has the substitute isn't known.
  case substituted

  /// A legacy recipe's row, from the ids the search reported for the recipe.
  public static func mark(
    ingredientID: Int64,
    isRequired: Bool,
    isSubstituted: Bool,
    missingRequiredIDs: Set<Int64>,
    insufficientSupply: [Int64: IngredientSupply] = [:]
  ) -> RecipeIngredientMark {
    if isSubstituted { return .substituted }
    guard isRequired else { return .optional }
    if missingRequiredIDs.contains(ingredientID) { return .missing }
    switch insufficientSupply[ingredientID] {
    case .short(let grams): return .short(grams: grams)
    case .checkAmount: return .checkAmount
    case .have, .missing, nil: return .have
    }
  }

  /// A catalog line, judged where the search judges it, so the preview and the results card
  /// read from one verdict per line. Ids can't carry this: a catalog line bridges to several app
  /// ingredients and two lines can share one (olives and olive oil), so an id-keyed lookup
  /// marked a line by its neighbour's verdict.
  ///
  /// An assumed staple never blocks a match, but its supply is still real: one the kitchen
  /// lacks is "usually on hand", and one held short or only as an estimate says so.
  public static func line(
    isRequired: Bool, isAssumedStaple: Bool, supply: IngredientSupply
  ) -> RecipeIngredientMark {
    if !isAssumedStaple, !isRequired { return .optional }
    switch supply {
    case .have: return .have
    case .short(let grams): return .short(grams: grams)
    case .checkAmount: return .checkAmount
    case .missing: return isAssumedStaple ? .usuallyOnHand : .missing
    }
  }
}
