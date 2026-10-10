// GENERATED FILE - DO NOT EDIT BY HAND. Regenerate with:
//   python3 make_vendored.py
// Parity: text between REPLAY-VENDORED-REGION markers is byte-identical to the
// production files at the pinned base (see RegionManifest.json). Everything else
// in this file is replay-side scaffolding and is NOT part of the parity claim.

import Foundation

// SCAFFOLD-BEGIN (replay-side; NOT parity)
/// Replay-side replacement: production HealthGoal carries a GRDB conformance in
/// its declaration; the cases and raw values below match production exactly.
enum HealthGoal: String, Codable, Sendable {
  case general
  case weightLoss = "weight_loss"
  case muscleGain = "muscle_gain"
  case maintenance
}

/// Replay-side replacement: production RecipeSource carries a GRDB conformance.
enum RecipeSource: String, Codable, Sendable {
  case bundled
  case user
  case aiGenerated = "ai_generated"
}
// SCAFFOLD-END

// REPLAY-VENDORED-REGION-START HealthScore_struct
struct HealthScore: Sendable {
  let rating: Int  // 1-5 stars
  let label: String  // "Great match", "Good", etc.
  let reasoning: String  // "High protein · Light meal"

  static let labels = ["", "Not aligned", "Indulgent", "Moderate", "Good", "Great match"]
}
// REPLAY-VENDORED-REGION-END HealthScore_struct

final class HealthScoringServiceReplay {
// REPLAY-VENDORED-REGION-START computeScore_func
  private func computeScore(macros: RecipeMacros, profile: HealthProfile) -> HealthScore {
    var points: Double = 0

    if let targetCal = profile.dailyCalories {
      let mealTarget = Double(targetCal) / 3.0
      let ratio = macros.caloriesPerServing / mealTarget
      switch ratio {
      case 0.7...1.1: points += 30
      case 0.5..<0.7: points += 20
      case 1.1..<1.4: points += 15
      default: points += 5
      }
    } else {
      points += 20
    }

    let split = macros.macroSplit
    let proteinDiff = abs(split.proteinPct - profile.proteinPct)
    let carbsDiff = abs(split.carbsPct - profile.carbsPct)
    let fatDiff = abs(split.fatPct - profile.fatPct)
    let avgDiff = (proteinDiff + carbsDiff + fatDiff) / 3.0

    points += max(5, 40 * (1.0 - avgDiff * 3.0))

    if macros.fiberPerServing >= 5 { points += 10 }
    if macros.sugarPerServing <= 10 { points += 10 }
    if macros.sodiumPerServing <= 600 { points += 10 }

    let rating = min(5, max(1, Int(ceil(points / 20.0))))

    let reasoning = buildReasoning(macros: macros, split: split)

    return HealthScore(
      rating: rating,
      label: HealthScore.labels[rating],
      reasoning: reasoning
    )
  }
// REPLAY-VENDORED-REGION-END computeScore_func

// REPLAY-VENDORED-REGION-START buildReasoning_func
  private func buildReasoning(
    macros: RecipeMacros,
    split: (proteinPct: Double, carbsPct: Double, fatPct: Double)
  ) -> String {
    var notes: [String] = []

    if split.proteinPct > 0.30 {
      notes.append("High protein")
    } else if split.proteinPct > 0.25 {
      notes.append("Good protein")
    }

    if macros.caloriesPerServing < 350 {
      notes.append("Light meal")
    } else if macros.caloriesPerServing > 700 {
      notes.append("Hearty portion")
    }

    if macros.fiberPerServing >= 5 { notes.append("Good fiber") }
    if macros.sugarPerServing > 15 { notes.append("Higher sugar") }
    if macros.sodiumPerServing > 800 { notes.append("High sodium") }

    return notes.isEmpty ? "Balanced" : notes.joined(separator: " · ")
  }
// REPLAY-VENDORED-REGION-END buildReasoning_func

  // SCAFFOLD-BEGIN (replay-side access wrappers; NOT parity)
  func replayScore(macros: RecipeMacros, profile: HealthProfile) -> HealthScore {
    computeScore(macros: macros, profile: profile)
  }

  func replayReasoning(
    macros: RecipeMacros,
    split: (proteinPct: Double, carbsPct: Double, fatPct: Double)
  ) -> String {
    buildReasoning(macros: macros, split: split)
  }
  // SCAFFOLD-END
}

// REPLAY-VENDORED-REGION-START RecipeMacros_struct
struct RecipeMacros: Sendable {
  let caloriesPerServing: Double
  let proteinPerServing: Double  // grams
  let carbsPerServing: Double  // grams
  let fatPerServing: Double  // grams
  let fiberPerServing: Double  // grams
  let sugarPerServing: Double  // grams
  let sodiumPerServing: Double  // milligrams (converted from g for display)

  /// Macro calorie percentages (protein + carbs + fat = ~100%).
  var macroSplit: (proteinPct: Double, carbsPct: Double, fatPct: Double) {
    let proteinCal = proteinPerServing * 4  // 4 kcal per gram protein
    let carbsCal = carbsPerServing * 4  // 4 kcal per gram carbs
    let fatCal = fatPerServing * 9  // 9 kcal per gram fat
    let total = proteinCal + carbsCal + fatCal

    guard total > 0 else { return (0.33, 0.33, 0.33) }
    return (proteinCal / total, carbsCal / total, fatCal / total)
  }

  /// Short summary string for display: "~420 kcal · 32g P · 45g C · 12g F"
  var summaryText: String {
    let cal = Int(caloriesPerServing.rounded())
    let pro = Int(proteinPerServing.rounded())
    let carb = Int(carbsPerServing.rounded())
    let fat = Int(fatPerServing.rounded())
    return "~\(cal) kcal · \(pro)g P · \(carb)g C · \(fat)g F"
  }
}
// REPLAY-VENDORED-REGION-END RecipeMacros_struct

// REPLAY-VENDORED-REGION-START RecipeTags_struct
struct RecipeTags: OptionSet, Sendable, Codable {
  let rawValue: Int

  static let quick = RecipeTags(rawValue: 1 << 0)
  static let vegetarian = RecipeTags(rawValue: 1 << 1)
  static let vegan = RecipeTags(rawValue: 1 << 2)
  static let asian = RecipeTags(rawValue: 1 << 3)
  static let breakfast = RecipeTags(rawValue: 1 << 4)
  static let budget = RecipeTags(rawValue: 1 << 5)
  static let comfort = RecipeTags(rawValue: 1 << 6)
  static let mediterranean = RecipeTags(rawValue: 1 << 7)
  static let mexican = RecipeTags(rawValue: 1 << 8)
  static let highProtein = RecipeTags(rawValue: 1 << 9)
  static let lowCarb = RecipeTags(rawValue: 1 << 10)
  static let onePot = RecipeTags(rawValue: 1 << 11)

  static let allTags: [(String, RecipeTags)] = [
    ("quick", .quick),
    ("vegetarian", .vegetarian),
    ("vegan", .vegan),
    ("asian", .asian),
    ("breakfast", .breakfast),
    ("budget", .budget),
    ("comfort", .comfort),
    ("mediterranean", .mediterranean),
    ("mexican", .mexican),
    ("high_protein", .highProtein),
    ("low_carb", .lowCarb),
    ("one_pot", .onePot),
  ]

  var labels: [String] {
    Self.allTags.compactMap { name, tag in
      self.contains(tag) ? name : nil
    }
  }
}
// REPLAY-VENDORED-REGION-END RecipeTags_struct

// REPLAY-VENDORED-REGION-START Recipe_struct
struct Recipe: Identifiable, Sendable, Codable {
  var id: Int64?
  var title: String
  var timeMinutes: Int
  var servings: Int
  var instructions: String
  var tags: Int
  var source: RecipeSource
  var createdAt: Date?

  var recipeTags: RecipeTags {
    RecipeTags(rawValue: tags)
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case timeMinutes = "time_minutes"
    case servings
    case instructions
    case tags
    case source
    case createdAt = "created_at"
  }
}
// REPLAY-VENDORED-REGION-END Recipe_struct

// REPLAY-VENDORED-REGION-START HealthProfile_struct
struct HealthProfile: Sendable, Codable {
  var id: Int64 = 1
  var displayName: String
  var age: Int?
  var goal: HealthGoal
  var dailyCalories: Int?
  var proteinPct: Double
  var carbsPct: Double
  var fatPct: Double
  var dietaryRestrictions: String  // JSON array string
  var allergenIngredientIds: String  // JSON array string
  var updatedAt: Date?

  static let `default` = HealthProfile(
    displayName: "",
    age: nil,
    goal: .general,
    dailyCalories: 2000,
    proteinPct: 0.25,
    carbsPct: 0.45,
    fatPct: 0.30,
    dietaryRestrictions: "[]",
    allergenIngredientIds: "[]"
  )

  var parsedDietaryRestrictions: [String] {
    guard let data = dietaryRestrictions.data(using: .utf8),
      let array = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return array
  }

  var normalizedDietaryRestrictionIDs: Set<String> {
    Set(
      parsedDietaryRestrictions.map {
        $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      })
  }

  var parsedAllergenIds: [Int64] {
    guard let data = allergenIngredientIds.data(using: .utf8),
      let array = try? JSONDecoder().decode([Int64].self, from: data)
    else {
      return []
    }
    return array
  }
}
// REPLAY-VENDORED-REGION-END HealthProfile_struct

public enum RecipeRepositoryReplay {}

extension RecipeRepositoryReplay {
// REPLAY-VENDORED-REGION-START sharedRankingScore_and_rankingReasons
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
// REPLAY-VENDORED-REGION-END sharedRankingScore_and_rankingReasons
}
