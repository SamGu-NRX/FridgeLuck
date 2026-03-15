import Foundation
import Observation

struct LiveAssistantIngredientContext: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  let quantityText: String?
  let quantityGrams: Double?

  init(name: String, quantityText: String? = nil, quantityGrams: Double? = nil) {
    self.id = UUID().uuidString
    self.name = name
    self.quantityText = quantityText
    self.quantityGrams = quantityGrams
  }
}

struct LiveAssistantRecipeContext: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let recipeID: Int64?
  let title: String
  let timeMinutes: Int
  let servings: Int
  let instructions: String
  let ingredients: [LiveAssistantIngredientContext]
  let matchedAt: Date

  init(
    recipeID: Int64?,
    title: String,
    timeMinutes: Int,
    servings: Int,
    instructions: String,
    ingredients: [LiveAssistantIngredientContext],
    matchedAt: Date = .now
  ) {
    self.id = recipeID.map(String.init) ?? UUID().uuidString
    self.recipeID = recipeID
    self.title = title
    self.timeMinutes = timeMinutes
    self.servings = servings
    self.instructions = instructions
    self.ingredients = ingredients
    self.matchedAt = matchedAt
  }
}

extension LiveAssistantRecipeContext {
  init(
    scoredRecipe: ScoredRecipe,
    ingredients: [(ingredient: Ingredient, quantity: RecipeIngredient)]
  ) {
    self.init(
      recipeID: scoredRecipe.recipe.id,
      title: scoredRecipe.recipe.title,
      timeMinutes: scoredRecipe.recipe.timeMinutes,
      servings: scoredRecipe.recipe.servings,
      instructions: scoredRecipe.recipe.instructions,
      ingredients: ingredients.map {
        LiveAssistantIngredientContext(
          name: $0.ingredient.name,
          quantityText: $0.quantity.displayQuantity,
          quantityGrams: $0.quantity.quantityGrams
        )
      }
    )
  }
}

struct LiveAssistantTranscriptEntry: Identifiable, Hashable, Sendable {
  enum Role: String, Sendable {
    case user
    case assistant
    case system
  }

  let id: UUID
  let role: Role
  let text: String
  let createdAt: Date

  init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
  }
}

@Observable
final class LiveAssistantCoordinator {
  var matchedRecipe: ScoredRecipe?
  var matchedRecipeContext: LiveAssistantRecipeContext?
  var shouldPresentLesson = false

  func storeRecipeMatch(
    scoredRecipe: ScoredRecipe,
    context: LiveAssistantRecipeContext
  ) {
    matchedRecipe = scoredRecipe
    matchedRecipeContext = context
    shouldPresentLesson = true
  }

  func clearPendingLesson() {
    shouldPresentLesson = false
  }
}
