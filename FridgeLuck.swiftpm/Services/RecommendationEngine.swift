import Foundation

/// Orchestrates the full flow from detected ingredients to scored recipe recommendations.
/// Ties together RecipeRepository, HealthScoring, and RecipeGenerator.
@MainActor
final class RecommendationEngine: ObservableObject {
  private let recipeRepository: RecipeRepository
  private let healthScoringService: HealthScoringService
  private let recipeGenerator: RecipeGenerating

  @Published var recommendations: [ScoredRecipe] = []
  @Published var quickSuggestion: ScoredRecipe?
  @Published var aiGeneratedRecipe: GeneratedRecipeResult?
  @Published var isLoading = false
  @Published var error: Error?

  init(
    recipeRepository: RecipeRepository,
    healthScoringService: HealthScoringService,
    recipeGenerator: RecipeGenerating
  ) {
    self.recipeRepository = recipeRepository
    self.healthScoringService = healthScoringService
    self.recipeGenerator = recipeGenerator
  }

  // MARK: - Find Recipes

  /// Given a set of detected/confirmed ingredient IDs, find all matching recipes.
  func findRecipes(for ingredientIds: Set<Int64>) async {
    isLoading = true
    error = nil

    do {
      let profile = try healthScoringService.fetchHealthProfile()

      // Find bundled/saved recipes
      let results = try recipeRepository.findMakeable(
        with: ingredientIds,
        profile: profile,
        limit: 20
      )
      recommendations = results

      // Quick suggestion
      quickSuggestion = try recipeRepository.quickSuggestion(
        with: ingredientIds,
        profile: profile
      )

    } catch {
      self.error = error
    }

    isLoading = false
  }

  // MARK: - AI Recipe Generation

  /// Attempt to generate a novel recipe from the given ingredient names.
  func generateAIRecipe(
    ingredientNames: [String],
    dietaryRestrictions: [String] = []
  ) async {
    do {
      aiGeneratedRecipe = try await recipeGenerator.generate(
        from: ingredientNames,
        dietaryRestrictions: dietaryRestrictions
      )
    } catch {
      // AI generation is optional — don't surface as error
      aiGeneratedRecipe = nil
    }
  }
}
