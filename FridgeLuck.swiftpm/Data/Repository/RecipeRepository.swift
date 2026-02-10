import Foundation
import GRDB

/// A recipe with all computed scores for display in results.
struct ScoredRecipe: Identifiable, Sendable {
  let recipe: Recipe
  let matchedRequired: Int
  let totalRequired: Int
  let matchedOptional: Int
  let macros: RecipeMacros
  let healthScore: HealthScore
  let personalScore: Double

  var id: Int64? { recipe.id }

  /// Combined score for sorting. Higher is better.
  var combinedScore: Double {
    let matchScore = Double(matchedRequired) * 10.0 + Double(matchedOptional) * 3.0
    let healthBoost = Double(healthScore.rating) * 5.0
    let timeBonus = recipe.timeMinutes <= 15 ? 3.0 : 0.0
    return matchScore + healthBoost + timeBonus + personalScore
  }
}

/// Central repository for all recipe queries.
final class RecipeRepository: Sendable {
  private let db: DatabaseQueue
  private let nutritionService: NutritionService
  private let healthScoringService: HealthScoringService
  private let personalizationService: PersonalizationService

  init(
    db: DatabaseQueue,
    nutritionService: NutritionService,
    healthScoringService: HealthScoringService,
    personalizationService: PersonalizationService
  ) {
    self.db = db
    self.nutritionService = nutritionService
    self.healthScoringService = healthScoringService
    self.personalizationService = personalizationService
  }

  // MARK: - Find Makeable Recipes

  /// Find recipes where ALL required ingredients are in the user's available set.
  /// Results include macros, health score, and personalization.
  func findMakeable(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    limit: Int = 20
  ) throws -> [ScoredRecipe] {
    guard !availableIds.isEmpty else { return [] }

    let idList = availableIds.map(String.init).joined(separator: ",")

    let rows = try db.read { db -> [Row] in
      try Row.fetchAll(
        db,
        sql: """
          SELECT r.*,
              SUM(CASE WHEN ri.is_required = 1
                   AND ri.ingredient_id IN (\(idList)) THEN 1 ELSE 0 END) as matched_req,
              SUM(CASE WHEN ri.is_required = 1 THEN 1 ELSE 0 END) as total_req,
              SUM(CASE WHEN ri.is_required = 0
                   AND ri.ingredient_id IN (\(idList)) THEN 1 ELSE 0 END) as matched_opt
          FROM recipes r
          JOIN recipe_ingredients ri ON r.id = ri.recipe_id
          GROUP BY r.id
          HAVING matched_req = total_req
          ORDER BY matched_req DESC, matched_opt DESC, r.time_minutes ASC
          """)
    }

    let allergenIds = Set(profile.parsedAllergenIds)

    var results: [ScoredRecipe] = []

    for row in rows {
      let recipe = Recipe(
        id: row["id"],
        title: row["title"],
        timeMinutes: row["time_minutes"],
        servings: row["servings"],
        instructions: row["instructions"],
        tags: row["tags"],
        source: RecipeSource(rawValue: row["source"] as String) ?? .bundled,
        createdAt: row["created_at"]
      )

      guard let recipeId = recipe.id else { continue }

      // Filter out recipes containing allergens
      if !allergenIds.isEmpty {
        let hasAllergen =
          try db.read { db in
            try Bool.fetchOne(
              db,
              sql: """
                SELECT EXISTS(
                    SELECT 1 FROM recipe_ingredients
                    WHERE recipe_id = ?
                    AND ingredient_id IN (\(allergenIds.map(String.init).joined(separator: ",")))
                )
                """, arguments: [recipeId])
          } ?? false

        if hasAllergen { continue }
      }

      let macros = try nutritionService.macros(for: recipeId)
      let healthScore = try healthScoringService.score(macros: macros)
      let personalScore = try personalizationService.personalScore(for: recipeId)

      results.append(
        ScoredRecipe(
          recipe: recipe,
          matchedRequired: row["matched_req"] as Int,
          totalRequired: row["total_req"] as Int,
          matchedOptional: row["matched_opt"] as? Int ?? 0,
          macros: macros,
          healthScore: healthScore,
          personalScore: personalScore
        ))

      if results.count >= limit { break }
    }

    // Sort by combined score
    results.sort { $0.combinedScore > $1.combinedScore }

    return results
  }

  // MARK: - Quick Suggestion ("Make Something Now")

  /// Returns the single best recipe optimized for speed + health + freshness.
  func quickSuggestion(
    with availableIds: Set<Int64>,
    profile: HealthProfile
  ) throws -> ScoredRecipe? {
    var candidates = try findMakeable(with: availableIds, profile: profile, limit: 5)

    // Re-sort prioritizing quick cook time
    candidates.sort { a, b in
      let aScore =
        Double(a.healthScore.rating) * 10.0
        - Double(a.recipe.timeMinutes)
        + a.personalScore * 5.0
      let bScore =
        Double(b.healthScore.rating) * 10.0
        - Double(b.recipe.timeMinutes)
        + b.personalScore * 5.0
      return aScore > bScore
    }

    return candidates.first
  }

  // MARK: - Recipe by ID

  func fetchRecipe(id: Int64) throws -> Recipe? {
    try db.read { db in
      try Recipe.fetchOne(db, key: id)
    }
  }

  /// Get all ingredients for a recipe with their quantities.
  func ingredientsForRecipe(id: Int64) throws -> [(
    ingredient: Ingredient, quantity: RecipeIngredient
  )] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT i.*, ri.recipe_id, ri.ingredient_id, ri.is_required,
                 ri.quantity_grams, ri.display_quantity
          FROM recipe_ingredients ri
          JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ri.recipe_id = ?
          ORDER BY ri.is_required DESC
          """, arguments: [id])

      return rows.map { row in
        let ingredient = Ingredient(
          id: row["id"],
          name: row["name"],
          calories: row["calories"],
          protein: row["protein"],
          carbs: row["carbs"],
          fat: row["fat"],
          fiber: row["fiber"],
          sugar: row["sugar"],
          sodium: row["sodium"],
          typicalUnit: row["typical_unit"],
          storageTip: row["storage_tip"],
          pairsWith: row["pairs_with"],
          notes: row["notes"]
        )
        let ri = RecipeIngredient(
          recipeId: row["recipe_id"],
          ingredientId: row["ingredient_id"],
          isRequired: row["is_required"],
          quantityGrams: row["quantity_grams"],
          displayQuantity: row["display_quantity"]
        )
        return (ingredient: ingredient, quantity: ri)
      }
    }
  }

  // MARK: - Save User/AI Recipes

  func saveRecipe(
    _ recipe: Recipe, ingredients: [(ingredientId: Int64, grams: Double, required: Bool)]
  ) throws -> Int64 {
    try db.write { db in
      var mutableRecipe = recipe
      try mutableRecipe.insert(db)
      let recipeId = db.lastInsertedRowID

      for ing in ingredients {
        try db.execute(
          sql: """
            INSERT INTO recipe_ingredients
                (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [recipeId, ing.ingredientId, ing.required, ing.grams, "\(Int(ing.grams))g"])
      }

      return recipeId
    }
  }
}
