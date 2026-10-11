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
    return QuantityReviewNutrition(
      calories: macros.caloriesPerServing,
      protein: macros.protein,
      carbs: macros.carbs,
      fat: macros.fat)
  }

  func referencePerServingCalories(recipeID: Int64) throws -> Double? {
    // The original ingredient amounts, no swaps — the values the recommendation scored.
    try nutritionService.macros(for: recipeID, swaps: []).caloriesPerServing
  }
}
