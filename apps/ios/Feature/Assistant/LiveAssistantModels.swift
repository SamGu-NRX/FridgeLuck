import FLFeatureLogic
import Foundation
import Observation

struct LiveAssistantIngredientContext: Identifiable, Codable, Hashable, Sendable {
  let id: String
  let name: String
  let quantityText: String?
  let quantityGrams: Double?

  init(id: String = UUID().uuidString, name: String, quantityText: String? = nil, quantityGrams: Double? = nil) {
    self.id = id
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
  /// The catalog identity this session cooks at, when the recipe is a catalog recipe:
  /// the cook session links the exact `(catalogId, revision)` that was cooked. nil keeps
  /// the legacy integer-id session reference.
  let catalogID: String?
  let catalogRevision: Int?
  /// The packet's structured steps — stated timers and thermometer checks — verbatim
  /// from the installed bundle-v2 revision. nil for legacy recipes, which cook from the
  /// parsed `instructions` text.
  let catalogSteps: [CookStep]?

  init(
    recipeID: Int64?,
    title: String,
    timeMinutes: Int,
    servings: Int,
    instructions: String,
    ingredients: [LiveAssistantIngredientContext],
    matchedAt: Date = .now,
    catalogID: String? = nil,
    catalogRevision: Int? = nil,
    catalogSteps: [CookStep]? = nil
  ) {
    self.id = recipeID.map(String.init) ?? UUID().uuidString
    self.recipeID = recipeID
    self.title = title
    self.timeMinutes = timeMinutes
    self.servings = servings
    self.instructions = instructions
    self.ingredients = ingredients
    self.matchedAt = matchedAt
    self.catalogID = catalogID
    self.catalogRevision = catalogRevision
    self.catalogSteps = catalogSteps
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
