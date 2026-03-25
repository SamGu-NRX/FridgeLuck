import Foundation
import GRDB

/// Health rating for a recipe relative to the user's health profile.
struct HealthScore: Sendable {
  let rating: Int  // 1-5 stars
  let label: String  // "Great match", "Good", etc.
  let reasoning: String  // "High protein · Light meal"

  static let labels = ["", "Not aligned", "Indulgent", "Moderate", "Good", "Great match"]
}

/// Scores recipes against the user's health goals.
/// Score is based on:
///   1. Calorie alignment with per-meal target (0-30 points)
///   2. Macro balance alignment (0-40 points)
///   3. Nutritional quality bonuses — fiber, sugar, sodium (0-30 points)
final class HealthScoringService: Sendable {
  private let nutritionService: NutritionService
  private let db: DatabaseQueue

  init(nutritionService: NutritionService, db: DatabaseQueue) {
    self.nutritionService = nutritionService
    self.db = db
  }

  // MARK: - Scoring

  func score(recipeId: Int64) throws -> HealthScore {
    let macros = try nutritionService.macros(for: recipeId)
    let profile = try fetchHealthProfile()
    return computeScore(macros: macros, profile: profile)
  }

  func score(macros: RecipeMacros) throws -> HealthScore {
    let profile = try fetchHealthProfile()
    return computeScore(macros: macros, profile: profile)
  }

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

  // MARK: - Reasoning

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

  // MARK: - Profile

  func fetchHealthProfile() throws -> HealthProfile {
    try db.read { db in
      try HealthProfile.fetchOne(db, key: 1) ?? .default
    }
  }

  func saveHealthProfile(_ profile: HealthProfile) throws {
    try db.write { db in
      var mutable = profile
      mutable.id = 1
      try mutable.save(db)
    }
  }
}
