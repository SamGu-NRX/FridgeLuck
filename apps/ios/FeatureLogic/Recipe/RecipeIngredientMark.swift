import Foundation

/// What the recipe preview's leading icon says about one ingredient row.
///
/// The preview used to show a green check on every required ingredient, so an ingredient the
/// results card listed as missing (Cucumber, 2026-10-07 walk) looked like one the user had.
/// The recipe search only knows availability for required ingredients, through the missing IDs
/// it returns; optional and substituted rows make no availability claim.
public enum RecipeIngredientMark: Equatable, Sendable {
  /// Required, and among the ingredients the search used.
  case have
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
    missingRequiredIDs: Set<Int64>
  ) -> RecipeIngredientMark {
    if isSubstituted { return .substituted }
    guard isRequired else { return .optional }
    return missingRequiredIDs.contains(ingredientID) ? .missing : .have
  }
}
