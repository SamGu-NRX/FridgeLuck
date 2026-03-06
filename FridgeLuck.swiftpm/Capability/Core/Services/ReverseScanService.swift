import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "ReverseScanService")

struct ReverseScanRecipeCandidate: Identifiable, Sendable {
  let recipe: ScoredRecipe
  let confidenceScore: Double
  let matchedDetectedIngredients: Int
  let explanation: String?

  var id: Int64 {
    recipe.id ?? Int64(abs(recipe.recipe.title.hashValue))
  }
}

struct ReverseScanAnalysis: Sendable {
  let detections: [Detection]
  let categorized: ConfidenceRouter.CategorizedResults
  let overallDetectionConfidence: Double
  let candidateRecipes: [ReverseScanRecipeCandidate]
  let confidenceAssessment: ConfidenceAssessment
  let deterministicRecipeReady: Bool
  let fallbackTemplate: DishTemplate?
  let fallbackEstimate: PreparedDishEstimate?
  let usedCloudAgent: Bool
  let cloudSummary: String?
}

/// Reverse-scan flow:
/// meal photo -> detected ingredients -> confidence-scored recipe candidates.
/// If confidence is high enough, recipe macros can be treated as deterministic after user confirmation.
final class ReverseScanService: Sendable {
  private let visionService: VisionService
  private let recipeRepository: RecipeRepository
  private let healthScoringService: HealthScoringService
  private let dishEstimateService: DishEstimateService
  private let geminiCloudAgent: GeminiCloudAgent?
  private let confidenceLearningService: ConfidenceLearningService

  init(
    visionService: VisionService,
    recipeRepository: RecipeRepository,
    healthScoringService: HealthScoringService,
    dishEstimateService: DishEstimateService,
    geminiCloudAgent: GeminiCloudAgent? = nil,
    confidenceLearningService: ConfidenceLearningService
  ) {
    self.visionService = visionService
    self.recipeRepository = recipeRepository
    self.healthScoringService = healthScoringService
    self.dishEstimateService = dishEstimateService
    self.geminiCloudAgent = geminiCloudAgent
    self.confidenceLearningService = confidenceLearningService
  }

  func analyzeMealPhoto(_ image: UIImage) async throws -> ReverseScanAnalysis {
    guard let cgImage = image.cgImage else {
      throw NSError(
        domain: "ReverseScanService",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Unable to read image data for reverse scan."]
      )
    }
    logger.info(
      "Reverse scan started. imageWidth=\(cgImage.width, privacy: .public), imageHeight=\(cgImage.height, privacy: .public)"
    )

    let scanResult = try await visionService.scan(image: cgImage)
    let categorized = ConfidenceRouter.categorize(scanResult.detections)

    let detections = scanResult.detections
    let overallDetectionConfidence = averageConfidence(for: detections)
    logger.info(
      "Reverse scan detections ready. total=\(detections.count, privacy: .public), auto=\(categorized.confirmed.count, privacy: .public), confirm=\(categorized.needsConfirmation.count, privacy: .public), possible=\(categorized.possible.count, privacy: .public), overall=\(overallDetectionConfidence, privacy: .public)"
    )

    let ingredientIDs = Set(
      (categorized.confirmed + categorized.needsConfirmation).map(\.ingredientId)
    )

    var candidates: [ReverseScanRecipeCandidate] = []
    var usedCloudAgent = false
    var cloudSummary: String?
    if !ingredientIDs.isEmpty {
      let profile = try healthScoringService.fetchHealthProfile()
      let exact = try recipeRepository.findMakeable(
        with: ingredientIDs,
        profile: profile,
        limit: 6
      )
      let near = try recipeRepository.findNearMatch(
        with: ingredientIDs,
        profile: profile,
        maxMissingRequired: 2,
        limit: 8
      )

      let deduped = dedupeRecipes(exact + near)
      candidates = deduped.map { scoredRecipe in
        let matchedDetectedIngredients = max(
          0,
          scoredRecipe.matchedRequired + scoredRecipe.matchedOptional
        )

        let candidateConfidence = confidenceScore(
          for: scoredRecipe,
          overallDetectionConfidence: overallDetectionConfidence,
          detectedIngredientCount: ingredientIDs.count
        )

        return ReverseScanRecipeCandidate(
          recipe: scoredRecipe,
          confidenceScore: candidateConfidence,
          matchedDetectedIngredients: matchedDetectedIngredients,
          explanation: nil
        )
      }
      .sorted { lhs, rhs in
        if lhs.confidenceScore == rhs.confidenceScore {
          return lhs.recipe.rankingScore > rhs.recipe.rankingScore
        }
        return lhs.confidenceScore > rhs.confidenceScore
      }

      logger.info(
        "Local reverse-scan candidates computed. ingredientSignals=\(ingredientIDs.count, privacy: .public), candidates=\(candidates.count, privacy: .public)"
      )
    }

    if let geminiCloudAgent,
      geminiCloudAgent.isConfigured,
      !candidates.isEmpty
    {
      let preferLocal = overallDetectionConfidence >= 0.93
      if !preferLocal {
        logger.debug("Attempting cloud re-ranking for reverse scan.")
        do {
          let photoJPEGData = image.jpegData(compressionQuality: 0.72)
          if let cloudRankings = try await geminiCloudAgent.rankReverseScanCandidates(
            detections: detections,
            candidates: candidates,
            photoJPEGData: photoJPEGData
          ),
            !cloudRankings.isEmpty
          {
            let rankingByID = Dictionary(
              uniqueKeysWithValues: cloudRankings.map { ($0.recipeID, $0) })

            candidates = candidates.map { candidate in
              guard let recipeID = candidate.recipe.recipe.id,
                let cloud = rankingByID[recipeID]
              else {
                return candidate
              }

              let blendedConfidence =
                (candidate.confidenceScore * 0.55) + (cloud.confidenceScore * 0.45)
              return ReverseScanRecipeCandidate(
                recipe: candidate.recipe,
                confidenceScore: max(0, min(blendedConfidence, 1.0)),
                matchedDetectedIngredients: candidate.matchedDetectedIngredients,
                explanation: cloud.reason
              )
            }
            .sorted { lhs, rhs in
              if lhs.confidenceScore == rhs.confidenceScore {
                return lhs.recipe.rankingScore > rhs.recipe.rankingScore
              }
              return lhs.confidenceScore > rhs.confidenceScore
            }

            usedCloudAgent = true
            cloudSummary = candidates.first?.explanation
            logger.info(
              "Cloud re-ranking applied. rankedCandidates=\(candidates.count, privacy: .public)"
            )
          }
        } catch {
          logger.error("Cloud re-ranking failed: \(error.localizedDescription, privacy: .public)")
          // Keep deterministic local candidate ranking when cloud path is unavailable.
        }
      } else {
        logger.debug("Skipping cloud re-ranking due to very high local confidence.")
      }
    }

    let fallbackTemplate = try fallbackTemplate(for: detections)
    let fallbackEstimate = fallbackTemplate.map {
      dishEstimateService.estimate(template: $0, size: .normal)
    }

    let confidenceAssessment = confidenceLearningService.assess(
      signals: confidenceSignals(
        overallDetectionConfidence: overallDetectionConfidence,
        candidates: candidates
      ),
      hardFailReasons: confidenceHardFailReasons(candidates: candidates)
    )

    let deterministicReady =
      isDeterministicReady(
        candidates: candidates,
        autoDetectedIngredientCount: Set(categorized.confirmed.map(\.ingredientId)).count
      ) && confidenceAssessment.deterministicReady

    logger.info(
      "Reverse scan finalized. deterministicReady=\(deterministicReady, privacy: .public), mode=\(confidenceAssessment.mode.rawValue, privacy: .public), overallConfidence=\(confidenceAssessment.overallScore, privacy: .public), candidates=\(candidates.count, privacy: .public), usedCloud=\(usedCloudAgent, privacy: .public)"
    )
    if !confidenceAssessment.reasons.isEmpty {
      logger.debug(
        "Confidence reasons: \(confidenceAssessment.reasons.joined(separator: " | "), privacy: .public)"
      )
    }

    return ReverseScanAnalysis(
      detections: detections,
      categorized: categorized,
      overallDetectionConfidence: overallDetectionConfidence,
      candidateRecipes: candidates,
      confidenceAssessment: confidenceAssessment,
      deterministicRecipeReady: deterministicReady,
      fallbackTemplate: fallbackTemplate,
      fallbackEstimate: fallbackEstimate,
      usedCloudAgent: usedCloudAgent,
      cloudSummary: cloudSummary
    )
  }

  private func dedupeRecipes(_ recipes: [ScoredRecipe]) -> [ScoredRecipe] {
    var seen = Set<Int64>()
    var deduped: [ScoredRecipe] = []

    for recipe in recipes {
      guard let recipeID = recipe.id else { continue }
      guard seen.insert(recipeID).inserted else { continue }
      deduped.append(recipe)
    }

    return deduped
  }

  private func averageConfidence(for detections: [Detection]) -> Double {
    guard !detections.isEmpty else { return 0 }
    let sum = detections.reduce(0.0) { partial, detection in
      partial + max(0, min(Double(detection.confidence), 1.0))
    }
    return sum / Double(detections.count)
  }

  private func confidenceScore(
    for scoredRecipe: ScoredRecipe,
    overallDetectionConfidence: Double,
    detectedIngredientCount: Int
  ) -> Double {
    let requiredCoverage =
      Double(scoredRecipe.matchedRequired) / Double(max(scoredRecipe.totalRequired, 1))
    let missingPenalty = Double(scoredRecipe.missingRequiredCount) * 0.18
    let optionalCoverage =
      Double(scoredRecipe.matchedOptional) / Double(max(detectedIngredientCount, 1))

    let rawScore =
      (requiredCoverage * 0.62)
      + (overallDetectionConfidence * 0.24)
      + (optionalCoverage * 0.14)
      - missingPenalty

    return max(0, min(rawScore, 1.0))
  }

  private func confidenceSignals(
    overallDetectionConfidence: Double,
    candidates: [ReverseScanRecipeCandidate]
  ) -> [ConfidenceSignalInput] {
    let topCandidate = candidates.first
    let topScore = topCandidate?.confidenceScore ?? 0

    let requiredCoverage: Double
    if let top = topCandidate {
      requiredCoverage =
        Double(top.recipe.matchedRequired) / Double(max(top.recipe.totalRequired, 1))
    } else {
      requiredCoverage = 0
    }

    let marginScore: Double
    if candidates.count >= 2 {
      let margin = max(0, (candidates[0].confidenceScore - candidates[1].confidenceScore))
      marginScore = max(0, min(0.5 + margin, 1.0))
    } else if candidates.count == 1 {
      marginScore = 0.82
    } else {
      marginScore = 0
    }

    return [
      ConfidenceSignalInput(
        key: "reverse_scan.vision_detection",
        rawScore: overallDetectionConfidence,
        weight: 0.32,
        reason: "ingredient detection"
      ),
      ConfidenceSignalInput(
        key: "reverse_scan.recipe_match",
        rawScore: topScore,
        weight: 0.30,
        reason: "recipe match"
      ),
      ConfidenceSignalInput(
        key: "reverse_scan.required_coverage",
        rawScore: requiredCoverage,
        weight: 0.23,
        reason: "required ingredient coverage"
      ),
      ConfidenceSignalInput(
        key: "reverse_scan.candidate_margin",
        rawScore: marginScore,
        weight: 0.15,
        reason: "candidate ambiguity"
      ),
    ]
  }

  private func confidenceHardFailReasons(candidates: [ReverseScanRecipeCandidate]) -> [String] {
    guard let top = candidates.first else {
      return ["No confident recipe candidate."]
    }

    if top.recipe.missingRequiredCount > 2 {
      return ["Too many required ingredients are missing."]
    }

    if candidates.count >= 2 {
      let gap = top.confidenceScore - candidates[1].confidenceScore
      if gap < 0.06 {
        return ["Top recipe candidates are highly ambiguous."]
      }
    }

    return []
  }

  private func isDeterministicReady(
    candidates: [ReverseScanRecipeCandidate],
    autoDetectedIngredientCount: Int
  ) -> Bool {
    guard let best = candidates.first else { return false }
    let recipe = best.recipe

    let exactMatch = recipe.matchTier == .exact && recipe.missingRequiredCount == 0
    let enoughIngredientSignals = autoDetectedIngredientCount >= max(2, recipe.totalRequired / 2)
    return exactMatch && enoughIngredientSignals && best.confidenceScore >= 0.82
  }

  private func fallbackTemplate(for detections: [Detection]) throws -> DishTemplate? {
    let templates = try dishEstimateService.templates()
    guard !templates.isEmpty else { return nil }

    let corpus = detections.map { $0.label.lowercased() }.joined(separator: " ")

    let ranked = templates.sorted { lhs, rhs in
      templateScore(lhs, corpus: corpus) > templateScore(rhs, corpus: corpus)
    }

    return ranked.first
  }

  private func templateScore(_ template: DishTemplate, corpus: String) -> Int {
    let name = template.name.lowercased()

    if name.contains("fried") && corpus.contains("rice") { return 6 }
    if name.contains("curry") && (corpus.contains("curry") || corpus.contains("coconut")) {
      return 6
    }
    if name.contains("pasta") && (corpus.contains("pasta") || corpus.contains("noodle")) {
      return 6
    }
    if name.contains("soup") && (corpus.contains("broth") || corpus.contains("soup")) {
      return 6
    }
    if name.contains("stir") && (corpus.contains("pepper") || corpus.contains("broccoli")) {
      return 5
    }
    if name.contains("sandwich") && (corpus.contains("bread") || corpus.contains("toast")) {
      return 5
    }

    return 1
  }
}
