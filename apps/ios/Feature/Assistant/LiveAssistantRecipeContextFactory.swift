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
    var liveIngredients: [LiveAssistantIngredientContext] = []
    var catalogID: String?
    var catalogRevision: Int?
    var catalogSteps: [CookStep]?
    var instructions = scoredRecipe.recipe.instructions

    if let packet = try? recipeRepository.catalogCookPacket(for: scoredRecipe) {
      // The backend allergen canon resolves ingredientBill.ingredientId as a
      // catalog key, so keep the packet key instead of the app's numeric bridge id.
      liveIngredients = packet.lines.map {
        LiveAssistantIngredientContext(
          id: $0.key,
          name: $0.displayName ?? $0.key,
          quantityText: Self.quantityText($0.quantity),
          quantityGrams: Self.quantityGrams($0.quantity))
      }
      catalogID = packet.catalogId
      catalogRevision = packet.revision
      catalogSteps = packet.steps
      let stepText = packet.steps.map(\.text).joined(separator: "\n")
      if !stepText.isEmpty { instructions = stepText }
    } else if let recipeID = scoredRecipe.recipe.id {
      let ingredients = (try? recipeRepository.ingredientsForRecipe(id: recipeID)) ?? []
      liveIngredients = ingredients.map {
        LiveAssistantIngredientContext(
          id: $0.ingredient.name,
          name: $0.ingredient.name,
          quantityText: $0.quantity.displayQuantity,
          quantityGrams: $0.quantity.quantityGrams)
      }
    }

    return LiveAssistantRecipeContext(
      recipeID: scoredRecipe.recipe.id,
      title: scoredRecipe.recipe.title,
      timeMinutes: scoredRecipe.recipe.timeMinutes,
      servings: scoredRecipe.recipe.servings,
      instructions: instructions,
      ingredients: liveIngredients,
      catalogID: catalogID,
      catalogRevision: catalogRevision,
      catalogSteps: catalogSteps)
  }

  private static func quantityGrams(_ quantity: CookQuantity) -> Double? {
    switch quantity {
    case .grams(let grams): return grams
    case .household(_, _, let grams), .count(_, _, let grams): return grams
    case .unknown: return nil
    }
  }

  private static func quantityText(_ quantity: CookQuantity) -> String {
    switch quantity {
    case .grams(let grams): return "\(grams) g"
    case .household(let amount, let unit, _), .count(let amount, let unit, _): return "\(amount) \(unit)"
    case .unknown(let note): return note ?? "unknown"
    }
  }
}
