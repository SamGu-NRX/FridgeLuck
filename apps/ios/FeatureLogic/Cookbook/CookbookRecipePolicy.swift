import Foundation

/// Pure validation for cookbook drafts. No I/O, no GRDB, no SwiftUI — the same
/// rules the editor surfaces live and the transaction service enforces at the
/// write boundary.
///
/// Quantity rule: grams must be finite and strictly positive. `Double.isFinite`
/// rejects NaN and both infinities; zero and negative grams are meaningless on
/// a recipe line and are rejected rather than clamped, so the user sees the
/// real problem instead of a silently rewritten amount.
public enum CookbookRecipePolicy {
  public static let maxTitleLength = 120
  public static let minServings = 1
  public static let minTimeMinutes = 1

  /// Finite and strictly positive — the only quantity a recipe line may carry.
  public static func isFinitePositive(_ value: Double) -> Bool {
    value.isFinite && value > 0
  }

  /// Returns every problem with the draft, empty when it is savable.
  /// Catalog binding (ingredient ids actually existing) is enforced by the
  /// transaction service against the live database, not here.
  public static func validate(_ draft: CookbookRecipeDraft) -> [CookbookValidationProblem] {
    var problems: [CookbookValidationProblem] = []

    let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedTitle.isEmpty {
      problems.append(.emptyTitle)
    } else if trimmedTitle.count > maxTitleLength {
      problems.append(.titleTooLong(limit: maxTitleLength))
    }

    if draft.timeMinutes < minTimeMinutes {
      problems.append(.invalidTimeMinutes(draft.timeMinutes))
    }

    if draft.servings < minServings {
      problems.append(.invalidServings(draft.servings))
    }

    if draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems.append(.emptyInstructions)
    }

    if draft.ingredientLines.isEmpty {
      problems.append(.noIngredientLines)
    }

    var seenIngredientIds = Set<Int64>()
    for line in draft.ingredientLines {
      if !isFinitePositive(line.grams) {
        problems.append(.invalidQuantity(ingredientId: line.ingredientId))
      }
      if !seenIngredientIds.insert(line.ingredientId).inserted {
        problems.append(.duplicateIngredient(ingredientId: line.ingredientId))
      }
    }

    return problems
  }

  /// True when the draft passes every check this policy owns.
  public static func isSavable(_ draft: CookbookRecipeDraft) -> Bool {
    validate(draft).isEmpty
  }
}
