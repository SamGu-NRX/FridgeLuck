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

extension ScoredRecipeID {
  /// Stable identifier fragment for UI automation: `catalog_<id>` for bundle recipes,
  /// `legacy_<row>` for the demo pool. The journey test asserts it tapped a catalog
  /// recipe, not a demo-only legacy row.
  var uiTestFragment: String {
    switch self {
    case .catalog(let catalogID): return "catalog_\(catalogID)"
    case .legacy(let legacyID): return "legacy_\(legacyID)"
    case .unsaved(let title): return "unsaved_\(title)"
    }
  }
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
  /// Required lines the kitchen holds but doesn't fully cover (short, or only estimated).
  /// They count in `matchedRequired`, which stays presence-based so ranking scores are
  /// unchanged; they keep a recipe out of the exact tier.
  var insufficientRequiredLines: [InsufficientRequiredLine] = []

  /// Every required line is in the kitchen in full. Only these are "Complete match" and
  /// belong in the exact tier.
  var isCompleteMatch: Bool {
    missingRequiredCount == 0 && insufficientRequiredLines.isEmpty
  }

  /// Required lines the kitchen covers in full: the "x/y required" the hero shows.
  var requiredHadInFull: Int {
    max(matchedRequired - insufficientRequiredLines.count, 0)
  }

  /// The supply verdict for each ingredient id of an insufficient line, for the preview marks.
  var insufficientSupplyByIngredientID: [Int64: IngredientSupply] {
    var map: [Int64: IngredientSupply] = [:]
    for line in insufficientRequiredLines {
      for id in line.ingredientIDs { map[id] = line.supply }
    }
    return map
  }

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
  /// Whether a recipe belongs in the tier a search asked for (`minMissingRequired`...
  /// `maxMissingRequired` absent required ingredients). A recipe with every ingredient present
  /// but some not covered in full counts as one short of complete, so it lands in the near
  /// tier instead of the exact one.
  static func belongsInTier(
    missingRequired: Int,
    insufficientRequired: Int,
    minMissingRequired: Int,
    maxMissingRequired: Int
  ) -> Bool {
    let gap = missingRequired > 0 ? missingRequired : (insufficientRequired > 0 ? 1 : 0)
    return gap >= minMissingRequired && gap <= maxMissingRequired
  }

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
    insufficientLines: [InsufficientRequiredLine] = [],
    macros: RecipeMacros,
    healthScore: HealthScore,
    profile: HealthProfile
  ) -> [String] {
    var reasons: [String] = []

    let shortCount = insufficientLines.filter {
      if case .short = $0.supply { return true }
      return false
    }.count
    if missingRequiredCount > 0 {
      reasons.append("Almost there (missing \(missingRequiredCount))")
    } else if shortCount > 0 {
      reasons.append("Short on \(shortCount) ingredient\(shortCount == 1 ? "" : "s")")
    } else if !insufficientLines.isEmpty {
      reasons.append("Check amounts")
    } else {
      reasons.append("Complete match")
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
