import FLFeatureLogic
import Foundation

struct RecommendationSections: Sendable {
  var exact: [ScoredRecipe]
  var nearMatch: [ScoredRecipe]

  static let empty = RecommendationSections(exact: [], nearMatch: [])

  var all: [ScoredRecipe] { exact + nearMatch }
}

struct RecommendationExplanationPayload: Sendable {
  let policySummary: String
  let activeDietaryBadges: [String]
}

/// Orchestrates the full flow from detected ingredients to scored recipe recommendations.
/// Ties together RecipeRepository, HealthScoring, and RecipeGenerator.
@MainActor
final class RecommendationEngine: ObservableObject {
  private let recipeRepository: RecipeRepository
  private let healthScoringService: HealthScoringService
  private let recipeGenerator: RecipeGenerating

  @Published var recommendations: [ScoredRecipe] = []
  @Published var sections: RecommendationSections = .empty
  @Published var quickSuggestion: ScoredRecipe?
  @Published var aiGeneratedRecipe: GeneratedRecipeResult?
  @Published var explanationPayload = RecommendationExplanationPayload(
    policySummary:
      "Complete matches rank first, then near matches missing one required ingredient.",
    activeDietaryBadges: []
  )
  @Published var aiEnhancementNotice: String?
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
    self.aiEnhancementNotice = recipeGenerator.enhancementAvailability.noticeText
  }

  // MARK: - Find Recipes

  /// Given a set of detected/confirmed ingredient IDs, find all matching recipes.
  func findRecipes(for ingredientIds: Set<Int64>) async {
    isLoading = true
    error = nil

    defer { isLoading = false }

    do {
      let profile = try healthScoringService.fetchHealthProfile()
      let effectiveIngredientIDs = RecommendationPolicy.effectiveIngredientIDs(from: ingredientIds)

      let exact = try recipeRepository.findMakeable(
        with: effectiveIngredientIDs,
        profile: profile,
        limit: 20
      )
      var near = try recipeRepository.findNearMatch(
        with: effectiveIngredientIDs,
        profile: profile,
        maxMissingRequired: 1,
        limit: RecommendationPolicy.nearMatchLimit(hasExactMatches: !exact.isEmpty)
      )

      if RecommendationPolicy.shouldWidenNearMatchSearch(
        exactCount: exact.count,
        nearMatchCount: near.count
      ) {
        near = try recipeRepository.findNearMatch(
          with: effectiveIngredientIDs,
          profile: profile,
          maxMissingRequired: 2,
          limit: 20
        )
      }

      sections = RecommendationSections(exact: exact, nearMatch: near)
      recommendations = sections.all
      quickSuggestion = exact.first ?? near.first

      explanationPayload = RecommendationExplanationPayload(
        policySummary:
          "Complete matches rank first, then near matches missing one required ingredient.",
        activeDietaryBadges: profile.activeDietaryBadges
      )
    } catch {
      self.error = error
      recommendations = []
      sections = .empty
      quickSuggestion = nil
      explanationPayload = RecommendationExplanationPayload(
        policySummary:
          "Complete matches rank first, then near matches missing one required ingredient.",
        activeDietaryBadges: []
      )
    }
  }

  // MARK: - AI Recipe Generation

  /// Attempt to generate a novel recipe from the given ingredient names.
  func generateAIRecipe(
    ingredientNames: [String],
    dietaryRestrictions: [String] = []
  ) async {
    let normalizedNames = await AIIngredientNormalizer.enhancedNormalize(ingredientNames)

    do {
      aiGeneratedRecipe = try await recipeGenerator.generate(
        from: normalizedNames,
        dietaryRestrictions: dietaryRestrictions
      )
    } catch {
      aiGeneratedRecipe = nil
    }
  }
}
