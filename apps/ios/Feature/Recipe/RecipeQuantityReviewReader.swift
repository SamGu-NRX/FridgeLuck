import Foundation
import FLFeatureLogic

/// Production adapter: the amount review's reads ride the same synchronous GRDB services
/// the rest of the app uses. No new persistence or network layer is introduced.
///
/// The active substitutions passed in are the plan's already-selected swaps — the same
/// mapping `RecipePreviewIngredientSection` renders — so the review shows exactly the
/// plan as it stands, read fresh from the database.
struct AppRecipeQuantityReviewReader: RecipeQuantityReviewReading {
  let recipeRepository: RecipeRepository
  let nutritionService: NutritionService
  let activeSubstitutions: [Int64: (substitution: Substitution, ingredient: Ingredient)]

  func fetchRecipeServings(id: Int64) throws -> Int? {
    try recipeRepository.fetchRecipe(id: id)?.servings
  }

  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    try recipeRepository.ingredientsForRecipe(id: recipeID).map { item in
      let substitute = activeSubstitutions[item.quantity.ingredientId]
      return QuantityReviewJoinedRow(
        ingredientID: item.quantity.ingredientId,
        recipeID: item.quantity.recipeId,
        isRequired: item.quantity.isRequired,
        quantityGrams: item.quantity.quantityGrams,
        displayName: item.ingredient.displayName,
        substituteID: substitute?.substitution.substituteId,
        substituteName: substitute?.ingredient.displayName,
        substituteRatio: substitute.map { $0.substitution.ratio })
    }
  }

  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    let macros = try nutritionService.ingredientMacros(ingredientId: ingredientID, grams: grams)
    // `ingredientMacros` reports all-zero for an id with no ingredients row instead of
    // throwing. For a substitute, the plan's loaded ingredient row disambiguates the two:
    // an all-zero database read against non-zero facts at selection time means the row
    // vanished — refuse the read rather than counting absent food as zero energy. A
    // genuinely zero-macro ingredient (both reads zero) passes through honestly.
    if let planned = activeSubstitutions.values.first(where: {
      $0.substitution.substituteId == ingredientID
    })?.ingredient, planned.hasAnyNutrition, macros.isAllZero {
      throw SubstituteRowMissing(ingredientID: ingredientID)
    }
    return QuantityReviewNutrition(
      calories: macros.caloriesPerServing,
      protein: macros.proteinPerServing,
      carbs: macros.carbsPerServing,
      fat: macros.fatPerServing)
  }

  /// The substitute's ingredients row disappeared after it was selected — the read is
  /// refused, never papered over with zeros.
  private struct SubstituteRowMissing: Error {
    let ingredientID: Int64
  }

  func referencePerServingCalories(recipeID: Int64) throws -> Double? {
    // The original ingredient amounts, no swaps — the values the recommendation scored.
    try nutritionService.macros(for: recipeID, swaps: []).caloriesPerServing
  }
}

/// `ingredientMacros` answers a missing row with zeros; these helpers tell that shape
/// apart from a genuinely zero-macro ingredient without touching either type's file.
private extension RecipeMacros {
  var isAllZero: Bool {
    caloriesPerServing == 0 && proteinPerServing == 0 && carbsPerServing == 0
      && fatPerServing == 0 && fiberPerServing == 0 && sugarPerServing == 0
      && sodiumPerServing == 0
  }
}

private extension Ingredient {
  /// True when the plan's snapshot of this ingredient carried any non-zero fact.
  var hasAnyNutrition: Bool {
    calories != 0 || protein != 0 || carbs != 0 || fat != 0
      || fiber != 0 || sugar != 0 || sodium != 0
  }
}
