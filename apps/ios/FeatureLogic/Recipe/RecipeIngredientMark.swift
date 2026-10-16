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
  /// Optional. The search doesn't record whether the user has it.
  case optional
  /// Replaced in the preview. Whether the user has the substitute isn't known.
  case substituted

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
}
