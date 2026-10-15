import FLFeatureLogic
import Foundation

enum RecipeMatchTier: String, Sendable {
  case exact
  case nearMatch
}

/// Catalog identity for a recommendation drawn from the bundle-v2 catalog pool.
struct CatalogRecipeMatch: Hashable, Sendable {
  /// The stable public identity (`RecipeRef = {source, id, revision}`). Drawer, cook mode,
  /// and community features key off this; the synthesized `Recipe.id` stays nil.
  let ref: RecipeRef
  /// Set when this catalog recipe succeeds a legacy data.json recipe. A legacy recipe and
  /// its catalog successor never both appear in results; the legacy entry wins, because
  /// its integer id anchors cooking history, meals, and personalization.
  let successorToLegacyRecipeID: Int64?

  init(ref: RecipeRef, successorToLegacyRecipeID: Int64?) {
    self.ref = ref
    self.successorToLegacyRecipeID = successorToLegacyRecipeID
  }
}

/// Identity of a scored result across both pools: legacy integer rows and catalog ids.
/// Catalog entries carry nil `recipe.id`, so list identity must come from the catalog ref.
enum ScoredRecipeID: Hashable, Sendable {
  case legacy(Int64)
  case catalog(String)
  /// Unsaved legacy recipes (generated drafts) carry no integer id; the title keeps their
  /// identity stable within one result list.
  case unsaved(String)
}

/// A recipe with all computed scores for display in results.
struct ScoredRecipe: Identifiable, Sendable {
  let recipe: Recipe
  let matchedRequired: Int
  let totalRequired: Int
  let matchedOptional: Int
  let missingRequiredCount: Int
  let missingIngredientIds: [Int64]
  let macros: RecipeMacros
  let healthScore: HealthScore
  let personalScore: Double
  let rankingScore: Double
  let rankingReasons: [String]
  let matchTier: RecipeMatchTier
  /// Catalog provenance; nil for legacy-pool entries. `var` with a default so the
  /// memberwise initializer keeps a `catalog:` parameter (a defaulted `let` would drop it).
  var catalog: CatalogRecipeMatch? = nil

  var id: ScoredRecipeID {
    if let catalog { return .catalog(catalog.ref.id) }
    if let recipeID = recipe.id { return .legacy(recipeID) }
    return .unsaved(recipe.title)
  }

  /// Combined score for sorting. Higher is better.
  var combinedScore: Double { rankingScore }
}

// MARK: - Equatable / Hashable (identity = recipe.id + catalog ref)

extension ScoredRecipe: Equatable {
  static func == (lhs: ScoredRecipe, rhs: ScoredRecipe) -> Bool {
    lhs.recipe.id == rhs.recipe.id && lhs.catalog == rhs.catalog
  }
}

extension ScoredRecipe: Hashable {
  func hash(into hasher: inout Hasher) {
    hasher.combine(recipe.id)
    hasher.combine(catalog)
  }
}

extension RecipeRepository {
  static func sharedRankingScore(
    recipe: Recipe,
    matchedRequired: Int,
    totalRequired: Int,
    matchedOptional: Int,
    missingRequiredCount: Int,
    macros: RecipeMacros,
    healthScore: HealthScore,
    personalScore: Double,
    profile: HealthProfile
  ) -> Double {
    let requiredCoverage = Double(matchedRequired) / Double(max(totalRequired, 1))
    let optionalContribution = Double(matchedOptional) * 2.5
    let healthContribution = Double(healthScore.rating) * 6.5
    let personalizationContribution = personalScore * 8.0

    var score =
      requiredCoverage * 72.0
      + optionalContribution
      + healthContribution
      + personalizationContribution

    if recipe.timeMinutes <= 15 {
      score += 6.0
    } else if recipe.timeMinutes <= 30 {
      score += 3.0
    }

    switch profile.goal {
    case .muscleGain:
      score += min(macros.proteinPerServing / 8.0, 8.0)
    case .weightLoss:
      score += macros.caloriesPerServing <= 550 ? 5.0 : -3.0
    case .maintenance:
      score += (macros.caloriesPerServing >= 450 && macros.caloriesPerServing <= 750) ? 3.0 : 0.0
    case .general:
      break
    }

    if recipe.recipeTags.contains(.highProtein) || macros.proteinPerServing >= 24 {
      score += 4.0
    }

    score -= Double(max(0, missingRequiredCount)) * 24.0
    return score
  }

  static func rankingReasons(
    recipe: Recipe,
    missingRequiredCount: Int,
    macros: RecipeMacros,
    healthScore: HealthScore,
    profile: HealthProfile
  ) -> [String] {
    var reasons: [String] = []

    if missingRequiredCount == 0 {
      reasons.append("Complete match")
    } else {
      reasons.append("Almost there (missing \(missingRequiredCount))")
    }

    if recipe.timeMinutes <= 20 {
      reasons.append("Quick cook")
    }

    switch profile.goal {
    case .muscleGain:
      if macros.proteinPerServing >= 25 {
        reasons.append("Fits your goal")
      }
    case .weightLoss:
      if macros.caloriesPerServing <= 550 {
        reasons.append("Fits your goal")
      }
    case .maintenance:
      if macros.caloriesPerServing >= 450 && macros.caloriesPerServing <= 750 {
        reasons.append("Fits your goal")
      }
    case .general:
      break
    }

    if recipe.recipeTags.contains(.highProtein) || macros.proteinPerServing >= 24 {
      reasons.append("High protein")
    }

    if reasons.count < 2, healthScore.rating >= 4 {
      reasons.append("High health score")
    }

    return Array(reasons.prefix(4))
  }
}
