import FLFeatureLogic
import Foundation
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "RecommendationEngine")

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
  private let geminiCloudAgent: GeminiCloudAgent?
  private let confidenceLearningService: ConfidenceLearningService?

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
    recipeGenerator: RecipeGenerating,
    geminiCloudAgent: GeminiCloudAgent? = nil,
    confidenceLearningService: ConfidenceLearningService? = nil
  ) {
    self.recipeRepository = recipeRepository
    self.healthScoringService = healthScoringService
    self.recipeGenerator = recipeGenerator
    self.geminiCloudAgent = geminiCloudAgent
    self.confidenceLearningService = confidenceLearningService
    self.aiEnhancementNotice = recipeGenerator.enhancementAvailability.noticeText
  }

  // MARK: - Find Recipes

  /// Given a set of detected/confirmed ingredient IDs, find all matching recipes.
  func findRecipes(for ingredientIds: Set<Int64>) async {
    isLoading = true
    error = nil
    logger.info("Finding recipes. ingredientIds=\(ingredientIds.count, privacy: .public)")

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
      let totalResults = exact.count + near.count
      logger.info(
        "Recipe search completed. exact=\(exact.count, privacy: .public), near=\(near.count, privacy: .public), total=\(totalResults, privacy: .public)"
      )

      explanationPayload = RecommendationExplanationPayload(
        policySummary:
          "Complete matches rank first, then near matches missing one required ingredient.",
        activeDietaryBadges: profile.activeDietaryBadges
      )
    } catch {
      self.error = error
      logger.error("Recipe search failed: \(error.localizedDescription, privacy: .public)")
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
    photoJPEGData: Data? = nil,
    scanConfidenceScore: Double? = nil,
    dietaryRestrictions: [String] = []
  ) async {
    let normalizedNames = await AIIngredientNormalizer.enhancedNormalize(ingredientNames)
    logger.info(
      "Generate AI recipe requested. normalizedIngredients=\(normalizedNames.count, privacy: .public), hasPhoto=\(photoJPEGData != nil, privacy: .public), scanConfidence=\(scanConfidenceScore ?? -1, privacy: .public)"
    )

    let hasHighConfidenceLocalPath: Bool
    if let confidenceLearningService {
      let scanSignal = ConfidenceSignalInput(
        key: "recipe_generation.scan_confidence",
        rawScore: scanConfidenceScore ?? 0.55,
        weight: 0.65,
        reason: "scan confidence"
      )
      let ingredientCoverageSignal = ConfidenceSignalInput(
        key: "recipe_generation.ingredient_coverage",
        rawScore: min(Double(normalizedNames.count) / 7.0, 1.0),
        weight: 0.35,
        reason: "ingredient coverage"
      )
      let assessment = confidenceLearningService.assess(
        signals: [scanSignal, ingredientCoverageSignal],
        hardFailReasons: normalizedNames.isEmpty ? ["No confirmed ingredients yet."] : []
      )
      hasHighConfidenceLocalPath = assessment.mode == .exact && photoJPEGData == nil
      logger.debug(
        "Recipe generation confidence mode=\(assessment.mode.rawValue, privacy: .public), overall=\(assessment.overallScore, privacy: .public)"
      )
    } else {
      hasHighConfidenceLocalPath = (scanConfidenceScore ?? 0) >= 0.93 && photoJPEGData == nil
      logger.debug(
        "Recipe generation using legacy local-path heuristic. localPath=\(hasHighConfidenceLocalPath, privacy: .public)"
      )
    }

    if !hasHighConfidenceLocalPath,
      let geminiCloudAgent,
      geminiCloudAgent.isConfigured
    {
      logger.info("Routing recipe generation to cloud Gemini.")
      do {
        if let cloudRecipe = try await geminiCloudAgent.generateRecipe(
          ingredientNames: normalizedNames,
          dietaryRestrictions: dietaryRestrictions,
          photoJPEGData: photoJPEGData,
          scanConfidenceScore: scanConfidenceScore
        ) {
          aiGeneratedRecipe = cloudRecipe
          aiEnhancementNotice = "Cloud Gemini recipe synthesis active."
          logger.info("Cloud recipe generation returned successfully.")
          return
        }
      } catch {
        logger.error(
          "Cloud recipe generation failed: \(error.localizedDescription, privacy: .public)")
        // Fall through to local generator
      }
    }

    do {
      aiGeneratedRecipe = try await recipeGenerator.generate(
        from: normalizedNames,
        dietaryRestrictions: dietaryRestrictions
      )
      if aiGeneratedRecipe != nil {
        aiEnhancementNotice = recipeGenerator.enhancementAvailability.noticeText
        logger.info("Local recipe generation returned successfully.")
      } else {
        logger.notice("Local recipe generation returned no result.")
      }
    } catch {
      aiGeneratedRecipe = nil
      logger.error(
        "Local recipe generation failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
