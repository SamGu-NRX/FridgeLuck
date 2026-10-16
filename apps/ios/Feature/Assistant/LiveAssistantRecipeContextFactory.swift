import FLFeatureLogic
import Foundation

/// Builds the LeChef recipe context for a scored result, over the same repository paths
/// the cooking guide and preview drawer use, so every surface that receives a
/// recommended recipe agrees on its content. A catalog result — the recommend pool
/// builds `Recipe(id: nil, …)` and carries the identity in the match's catalog ref —
/// resolves ingredients and structured steps from the catalog cook packet; a legacy
/// result keeps the legacy ingredient rows and free-text instructions. Extracted from
/// the views so tests exercise the exact production resolution.
struct LiveAssistantRecipeContextFactory {
  let recipeRepository: RecipeRepository

  func context(for scoredRecipe: ScoredRecipe) -> LiveAssistantRecipeContext {
    let ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]
    var catalogID: String?
    var catalogRevision: Int?
    var catalogSteps: [CookStep]?
    var instructions = scoredRecipe.recipe.instructions

    if let packet = try? recipeRepository.catalogCookPacket(for: scoredRecipe) {
      // Catalog entries have no legacy row: the context cooks the packet — structured
      // steps (timers, thermometer checks) and the packet's bridged ingredient lines.
      ingredients = (try? recipeRepository.cookPacketIngredients(packet)) ?? []
      catalogID = packet.catalogId
      catalogRevision = packet.revision
      catalogSteps = packet.steps
      let stepText = packet.steps.map(\.text).joined(separator: "\n")
      if !stepText.isEmpty {
        instructions = stepText
      }
    } else if let recipeID = scoredRecipe.recipe.id {
      ingredients = (try? recipeRepository.ingredientsForRecipe(id: recipeID)) ?? []
    } else {
      ingredients = []
    }

    return LiveAssistantRecipeContext(
      recipeID: scoredRecipe.recipe.id,
      title: scoredRecipe.recipe.title,
      timeMinutes: scoredRecipe.recipe.timeMinutes,
      servings: scoredRecipe.recipe.servings,
      instructions: instructions,
      ingredients: ingredients.map {
        LiveAssistantIngredientContext(
          name: $0.ingredient.name,
          quantityText: $0.quantity.displayQuantity,
          quantityGrams: $0.quantity.quantityGrams
        )
      },
      catalogID: catalogID,
      catalogRevision: catalogRevision,
      catalogSteps: catalogSteps
    )
  }
}
