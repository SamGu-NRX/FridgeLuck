import Foundation

/// Pure scaling math for the amount review.
///
/// The two invariants this type owns:
/// - the serving factor `selectedServings / recipeServings` is applied to each base amount
///   exactly once, and
/// - a selected substitute's existing ratio is applied exactly once on top of the
///   serving-scaled amount — never re-applied, never compounded across recomputes.
///
/// Calories always scale the stored energy value the nutrition read returned; nothing here
/// reconstructs energy from macros.
public enum RecipeQuantityReviewCalculator {
  /// The finite set of serving counts the review offers. Positive and finite by
  /// construction — zero, negatives, and free-text values never enter the flow.
  public static let servingOptions: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12]

  /// The default reviewed serving count: the recipe's own serving count when the options
  /// carry it exactly, otherwise the closest option below it (or the smallest above it
  /// when every option is smaller).
  public static func defaultSelectedServings(recipeServings: Int) -> Double? {
    guard recipeServings > 0 else { return nil }
    let exact = Double(recipeServings)
    if let match = servingOptions.first(where: { $0 == exact }) { return match }
    let below = servingOptions.last(where: { $0 < exact })
    if let below { return below }
    return servingOptions.first
  }

  /// `selectedServings / recipeServings`, refusing every non-positive or non-finite input.
  public static func servingFactor(selectedServings: Double, recipeServings: Int) throws -> Double {
    guard selectedServings.isFinite, selectedServings > 0 else {
      throw RecipeQuantityReviewFailure.inconsistentRows(
        "Selected servings must be finite and positive, got \(selectedServings)")
    }
    guard recipeServings > 0 else {
      throw RecipeQuantityReviewFailure.invalidRecipeServings(recipeServings)
    }
    return selectedServings / Double(recipeServings)
  }

  /// Scaled amounts for one row. The serving factor scales the base once; the substitute's
  /// ratio, when present, scales the already-scaled original once.
  public static func amounts(row: RecipeQuantityReviewSnapshot.Row, servingFactor: Double) -> RowAmounts {
    let original = row.baseOriginalGrams * servingFactor
    let replacement = row.substituteRatio.map { original * $0 }
    let originalCalories = row.originalNutrition.map { $0.calories * servingFactor }
    let replacementCalories = row.replacementNutrition.map { $0.calories * servingFactor }
    return RowAmounts(
      originalGrams: original,
      replacementGrams: replacement,
      originalCalories: originalCalories,
      replacementCalories: replacementCalories)
  }

  public struct RowAmounts: Sendable, Equatable {
    public let originalGrams: Double
    public let replacementGrams: Double?
    public let originalCalories: Double?
    public let replacementCalories: Double?
  }

  /// Calories across the required rows at the given factor. Nil when any required row's
  /// nutrition is unavailable — a hole is never filled with a zero.
  public static func requiredTotalCalories(
    rows: [RecipeQuantityReviewSnapshot.Row], servingFactor: Double
  ) -> Double? {
    totalCalories(rows: rows.filter(\.isRequired), servingFactor: servingFactor)
  }

  /// Calories across the optional rows, computed separately on purpose: optional items are
  /// listed explicitly and are never silently added to the required total.
  public static func optionalTotalCalories(
    rows: [RecipeQuantityReviewSnapshot.Row], servingFactor: Double
  ) -> Double? {
    totalCalories(rows: rows.filter { !$0.isRequired }, servingFactor: servingFactor)
  }

  private static func totalCalories(
    rows: [RecipeQuantityReviewSnapshot.Row], servingFactor: Double
  ) -> Double? {
    guard !rows.isEmpty else { return nil }
    var total = 0.0
    for row in rows {
      let rowAmounts = amounts(row: row, servingFactor: servingFactor)
      // A substituted row's plan amount is the substitute's, so its total contribution is
      // the substitute's calories; otherwise the original's.
      guard let calories = rowAmounts.replacementCalories ?? rowAmounts.originalCalories else {
        return nil
      }
      total += calories
    }
    return total
  }
}
