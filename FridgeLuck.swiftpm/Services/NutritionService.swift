import Foundation
import GRDB

/// Per-serving macro breakdown for a recipe.
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

/// Computes per-recipe macros from ingredient quantities and serving sizes.
/// All calculations use: (nutrient_per_100g / 100) * quantity_grams / servings
final class NutritionService: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// Compute full macros for a recipe by summing all ingredient contributions.
  func macros(for recipeId: Int64) throws -> RecipeMacros {
    try db.read { db in
      // Get servings
      let servings =
        try Double.fetchOne(
          db,
          sql: "SELECT servings FROM recipes WHERE id = ?",
          arguments: [recipeId]
        ) ?? 1.0

      // Join recipe_ingredients with ingredients to get nutrition + quantities
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT i.calories, i.protein, i.carbs, i.fat,
                 i.fiber, i.sugar, i.sodium,
                 ri.quantity_grams
          FROM recipe_ingredients ri
          JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ri.recipe_id = ? AND ri.is_required = 1
          """, arguments: [recipeId])

      var totalCal = 0.0
      var totalPro = 0.0
      var totalCarb = 0.0
      var totalFat = 0.0
      var totalFib = 0.0
      var totalSug = 0.0
      var totalSod = 0.0

      for row in rows {
        let grams: Double = row["quantity_grams"]
        let factor = grams / 100.0  // nutrition is per 100g

        totalCal += (row["calories"] as Double) * factor
        totalPro += (row["protein"] as Double) * factor
        totalCarb += (row["carbs"] as Double) * factor
        totalFat += (row["fat"] as Double) * factor
        totalFib += (row["fiber"] as Double) * factor
        totalSug += (row["sugar"] as Double) * factor
        totalSod += (row["sodium"] as Double) * factor
      }

      return RecipeMacros(
        caloriesPerServing: totalCal / servings,
        proteinPerServing: totalPro / servings,
        carbsPerServing: totalCarb / servings,
        fatPerServing: totalFat / servings,
        fiberPerServing: totalFib / servings,
        sugarPerServing: totalSug / servings,
        sodiumPerServing: (totalSod / servings) * 1000  // g → mg
      )
    }
  }

  /// Compute macros for a single ingredient at a given quantity.
  func ingredientMacros(ingredientId: Int64, grams: Double) throws -> RecipeMacros {
    try db.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM ingredients WHERE id = ?",
          arguments: [ingredientId]
        )
      else {
        return RecipeMacros(
          caloriesPerServing: 0, proteinPerServing: 0,
          carbsPerServing: 0, fatPerServing: 0,
          fiberPerServing: 0, sugarPerServing: 0,
          sodiumPerServing: 0
        )
      }

      let factor = grams / 100.0
      return RecipeMacros(
        caloriesPerServing: (row["calories"] as Double) * factor,
        proteinPerServing: (row["protein"] as Double) * factor,
        carbsPerServing: (row["carbs"] as Double) * factor,
        fatPerServing: (row["fat"] as Double) * factor,
        fiberPerServing: (row["fiber"] as Double) * factor,
        sugarPerServing: (row["sugar"] as Double) * factor,
        sodiumPerServing: (row["sodium"] as Double) * factor * 1000
      )
    }
  }
}
