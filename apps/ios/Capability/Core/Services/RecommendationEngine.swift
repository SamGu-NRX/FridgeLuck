import FLFeatureLogic
import Foundation
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "RecommendationEngine")

struct RecommendationSections: Sendable {
  var exact: [ScoredRecipe]
  var nearMatch: [ScoredRecipe]

  static let empty = RecommendationSections(exact: [], nearMatch: [])

  var all: [ScoredRecipe] { exact + nearMatch }

  var isEmpty: Bool { exact.isEmpty && nearMatch.isEmpty }

  /// The Best Match hero: the first exact match, else the first near match.
  var bestMatch: ScoredRecipe? { exact.first ?? nearMatch.first }

  /// The lists shown under the Best Match hero. Repeating the hero under "Almost there" read
  /// as a duplicate result (2026-10-07 walk), so the lists leave it out. The header's exact
  /// and near counts still describe the full sections.
  var belowBestMatch: RecommendationSections {
    guard let heroID = bestMatch?.recipe.id else { return self }
    return RecommendationSections(
      exact: exact.filter { $0.recipe.id != heroID },
      nearMatch: nearMatch.filter { $0.recipe.id != heroID }
    )
  }
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
  private let kitchenIngredientIDs: (() throws -> Set<Int64>)?
  private let ingredientRepository: IngredientRepository?

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
  /// Size of the ingredient set the last search used, including Kitchen items when requested.
  @Published var searchedIngredientCount: Int?
  @Published var isLoading = false
  @Published var error: Error?

  init(
    recipeRepository: RecipeRepository,
    healthScoringService: HealthScoringService,
    recipeGenerator: RecipeGenerating,
    geminiCloudAgent: GeminiCloudAgent? = nil,
    confidenceLearningService: ConfidenceLearningService? = nil,
    kitchenIngredientIDs: (() throws -> Set<Int64>)? = nil,
    ingredientRepository: IngredientRepository? = nil
  ) {
    self.recipeRepository = recipeRepository
    self.healthScoringService = healthScoringService
    self.recipeGenerator = recipeGenerator
    self.geminiCloudAgent = geminiCloudAgent
    self.confidenceLearningService = confidenceLearningService
    self.kitchenIngredientIDs = kitchenIngredientIDs
    self.ingredientRepository = ingredientRepository
    self.aiEnhancementNotice = recipeGenerator.enhancementAvailability.noticeText
  }

  // MARK: - Find Recipes

  /// Given a set of detected/confirmed ingredient IDs, find all matching recipes.
  /// `includingKitchen` adds the active Kitchen inventory, so a scan of one shelf still matches
  /// recipes that need food confirmed earlier. Home already recommends from that inventory.
  func findRecipes(for scannedIngredientIds: Set<Int64>, includingKitchen: Bool = false) async {
    isLoading = true
    error = nil

    var ingredientIds = scannedIngredientIds
    if includingKitchen, let kitchenIngredientIDs {
      do {
        ingredientIds.formUnion(try kitchenIngredientIDs())
      } catch {
        logger.error(
          "Kitchen inventory read failed; matching scanned ingredients only: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    searchedIngredientCount = ingredientIds.count
    logger.info(
      "Finding recipes. scanned=\(scannedIngredientIds.count, privacy: .public), total=\(ingredientIds.count, privacy: .public)"
    )

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
      quickSuggestion = sections.bestMatch
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

    // The user's allergens gate every AI recipe. Resolve their ingredient IDs to names here so
    // call sites stay unchanged. Anything that cannot be established fails closed: no avoid
    // list, no AI card.
    let avoidIngredients: [String]
    do {
      avoidIngredients = try Self.allergenAvoidIngredients(
        healthScoringService: healthScoringService,
        ingredientRepository: ingredientRepository
      )
    } catch {
      aiGeneratedRecipe = nil
      logger.error(
        "AI recipe generation skipped: the allergen avoid list could not be resolved; failing closed. \(String(describing: error), privacy: .public)"
      )
      return
    }

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
        let cloudRecipe = try await geminiCloudAgent.generateRecipe(
          ingredientNames: normalizedNames,
          dietaryRestrictions: dietaryRestrictions,
          avoidIngredients: avoidIngredients,
          photoJPEGData: photoJPEGData,
          scanConfidenceScore: scanConfidenceScore
        )
        if let cloudRecipe = screenedRecipe(
          cloudRecipe,
          avoidingIngredients: avoidIngredients,
          source: "cloud"
        ) {
          aiGeneratedRecipe = cloudRecipe
          aiEnhancementNotice = "Cloud Gemini recipe synthesis active."
          logger.info("Cloud recipe generation returned successfully.")
          return
        }
        logger.info(
          "Cloud recipe did not pass the allergen screen; falling back to the local generator.")
      } catch {
        logger.error(
          "Cloud recipe generation failed: \(error.localizedDescription, privacy: .public)")
        // Fall through to local generator
      }
    }

    do {
      let localRecipe = try await recipeGenerator.generate(
        from: normalizedNames,
        dietaryRestrictions: dietaryRestrictions,
        avoidIngredients: avoidIngredients
      )
      let screened = screenedRecipe(
        localRecipe,
        avoidingIngredients: avoidIngredients,
        source: "local"
      )
      aiGeneratedRecipe = screened
      if localRecipe == nil {
        logger.notice("Local recipe generation returned no result.")
      } else if screened == nil {
        logger.notice("Local recipe generation result was withheld by the allergen screen.")
      } else {
        aiEnhancementNotice = recipeGenerator.enhancementAvailability.noticeText
        logger.info("Local recipe generation returned successfully.")
      }
    } catch {
      aiGeneratedRecipe = nil
      logger.error(
        "Local recipe generation failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Allergen Screening

  /// Returns the recipe only when it clears the allergen screen; otherwise nil. The rejection
  /// log names the avoided ingredient and the field matched, never the recipe text.
  private func screenedRecipe(
    _ recipe: GeneratedRecipeResult?,
    avoidingIngredients: [String],
    source: String
  ) -> GeneratedRecipeResult? {
    guard let recipe else { return nil }
    guard
      let rejection = AllergenScreening.rejection(
        title: recipe.title,
        instructions: recipe.instructions,
        avoidingIngredients: avoidingIngredients
      )
    else { return recipe }

    logger.error(
      "AI recipe rejected by allergen screen. source=\(source, privacy: .public), field=\(rejection.field.rawValue, privacy: .public), avoidedIngredient=\(rejection.avoidedIngredient), matchedTerm=\(rejection.matchedTerm)"
    )
    return nil
  }

  /// Resolves the profile's allergen ingredient IDs to names for prompts and screening.
  /// Throws when the avoid list cannot be fully established — callers must fail closed.
  private static func allergenAvoidIngredients(
    healthScoringService: HealthScoringService,
    ingredientRepository: IngredientRepository?
  ) throws -> [String] {
    let profile = try healthScoringService.fetchHealthProfile()
    let allergenIds = profile.parsedAllergenIds
    guard !allergenIds.isEmpty else { return [] }
    guard let ingredientRepository else {
      throw AllergenAvoidListResolutionError.repositoryUnavailable
    }

    let ingredients = try ingredientRepository.fetch(ids: Set(allergenIds))
    var namesByID: [Int64: String] = [:]
    for ingredient in ingredients {
      guard let id = ingredient.id else { continue }
      namesByID[id] = ingredient.name
    }

    for id in allergenIds where namesByID[id] == nil {
      logger.error(
        "Allergen ingredient \(id) missing from the catalog; failing closed.")
      throw AllergenAvoidListResolutionError.unresolvedIngredientID(id)
    }

    return AllergenAvoidList.names(forIDs: allergenIds, idToName: namesByID)
  }

  private enum AllergenAvoidListResolutionError: Error {
    case repositoryUnavailable
    case unresolvedIngredientID(Int64)
  }
}
