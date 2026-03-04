import Foundation
import GRDB

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

  /// Returns the total number of recipes currently persisted.
  func count() throws -> Int {
    try db.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") ?? 0
    }
  }

  /// Find recipes where ALL required ingredients are in the user's available set.
  /// Results include macros, health score, and personalization.
  func findMakeable(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    limit: Int = 20
  ) throws -> [ScoredRecipe] {
    try queryRecipes(
      with: availableIds,
      profile: profile,
      minMissingRequired: 0,
      maxMissingRequired: 0,
      matchTier: .exact,
      limit: limit
    )
  }

  func findNearMatch(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    maxMissingRequired: Int = 1,
    limit: Int = 20
  ) throws -> [ScoredRecipe] {
    guard maxMissingRequired >= 1 else { return [] }
    return try queryRecipes(
      with: availableIds,
      profile: profile,
      minMissingRequired: 1,
      maxMissingRequired: maxMissingRequired,
      matchTier: .nearMatch,
      limit: limit
    )
  }

  // MARK: - Quick Suggestion ("Make Something Now")

  /// Returns the single best recipe using the same unified ranking policy as result lists.
  func quickSuggestion(
    with availableIds: Set<Int64>,
    profile: HealthProfile
  ) throws -> ScoredRecipe? {
    if let exact = try findMakeable(with: availableIds, profile: profile, limit: 1).first {
      return exact
    }
    return try findNearMatch(with: availableIds, profile: profile, maxMissingRequired: 1, limit: 1)
      .first
  }

  // MARK: - Internal Querying

  private func queryRecipes(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    minMissingRequired: Int,
    maxMissingRequired: Int,
    matchTier: RecipeMatchTier,
    limit: Int
  ) throws -> [ScoredRecipe] {
    guard !availableIds.isEmpty else { return [] }

    let idList = availableIds.sorted().map(String.init).joined(separator: ",")
    let requiredTagMask = profile.requiredRecipeTagMask
    let tagFilter =
      requiredTagMask == 0 ? "" : "WHERE (r.tags & \(requiredTagMask)) = \(requiredTagMask)"

    let rows = try db.read { db -> [Row] in
      try Row.fetchAll(
        db,
        sql: """
          SELECT r.*,
              SUM(CASE WHEN ri.is_required = 1
                   AND ri.ingredient_id IN (\(idList)) THEN 1 ELSE 0 END) AS matched_req,
              SUM(CASE WHEN ri.is_required = 1 THEN 1 ELSE 0 END) AS total_req,
              SUM(CASE WHEN ri.is_required = 0
                   AND ri.ingredient_id IN (\(idList)) THEN 1 ELSE 0 END) AS matched_opt,
              SUM(CASE WHEN ri.is_required = 1
                   AND ri.ingredient_id NOT IN (\(idList)) THEN 1 ELSE 0 END) AS missing_req,
              GROUP_CONCAT(CASE WHEN ri.is_required = 1
                   AND ri.ingredient_id NOT IN (\(idList)) THEN ri.ingredient_id END) AS missing_req_ids
          FROM recipes r
          JOIN recipe_ingredients ri ON r.id = ri.recipe_id
          \(tagFilter)
          GROUP BY r.id
          HAVING missing_req BETWEEN ? AND ?
          ORDER BY missing_req ASC, matched_req DESC, matched_opt DESC, r.time_minutes ASC
          """,
        arguments: [minMissingRequired, maxMissingRequired]
      )
    }

    let excludedIngredientIds = Set(profile.parsedAllergenIds).union(
      profile.dietaryExcludedIngredientIds)
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

      if !excludedIngredientIds.isEmpty {
        let hasExcluded = try recipeContainsAnyIngredient(
          recipeId: recipeId,
          ingredientIds: excludedIngredientIds
        )
        if hasExcluded { continue }
      }

      let matchedRequired: Int = row["matched_req"]
      let totalRequired: Int = row["total_req"]
      let matchedOptional: Int = row["matched_opt"] as? Int ?? 0
      let missingRequired: Int =
        row["missing_req"] as? Int ?? max(totalRequired - matchedRequired, 0)
      let missingIngredientIds = parseIngredientIDList(row["missing_req_ids"] as String?)

      let macros = try nutritionService.macros(for: recipeId)
      let healthScore = try healthScoringService.score(macros: macros)
      let personalScore = try personalizationService.personalScore(for: recipeId)
      let rankingScore = Self.sharedRankingScore(
        recipe: recipe,
        matchedRequired: matchedRequired,
        totalRequired: totalRequired,
        matchedOptional: matchedOptional,
        missingRequiredCount: missingRequired,
        macros: macros,
        healthScore: healthScore,
        personalScore: personalScore,
        profile: profile
      )

      let reasons = Self.rankingReasons(
        recipe: recipe,
        missingRequiredCount: missingRequired,
        macros: macros,
        healthScore: healthScore,
        profile: profile
      )

      results.append(
        ScoredRecipe(
          recipe: recipe,
          matchedRequired: matchedRequired,
          totalRequired: totalRequired,
          matchedOptional: matchedOptional,
          missingRequiredCount: missingRequired,
          missingIngredientIds: missingIngredientIds,
          macros: macros,
          healthScore: healthScore,
          personalScore: personalScore,
          rankingScore: rankingScore,
          rankingReasons: reasons,
          matchTier: matchTier
        )
      )
    }

    results.sort { lhs, rhs in
      if lhs.rankingScore == rhs.rankingScore {
        if lhs.missingRequiredCount == rhs.missingRequiredCount {
          return lhs.recipe.timeMinutes < rhs.recipe.timeMinutes
        }
        return lhs.missingRequiredCount < rhs.missingRequiredCount
      }
      return lhs.rankingScore > rhs.rankingScore
    }

    if results.count > limit {
      return Array(results.prefix(limit))
    }
    return results
  }

  private func recipeContainsAnyIngredient(recipeId: Int64, ingredientIds: Set<Int64>) throws
    -> Bool
  {
    guard !ingredientIds.isEmpty else { return false }
    let ingredientList = ingredientIds.sorted().map(String.init).joined(separator: ",")

    return try db.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
              SELECT 1
              FROM recipe_ingredients
              WHERE recipe_id = ?
              AND ingredient_id IN (\(ingredientList))
          )
          """,
        arguments: [recipeId]
      ) ?? false
    }
  }

  private func parseIngredientIDList(_ csv: String?) -> [Int64] {
    guard let csv, !csv.isEmpty else { return [] }
    return
      csv
      .split(separator: ",")
      .compactMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  // MARK: - Recipe by ID

  func fetchRecipe(id: Int64) throws -> Recipe? {
    try db.read { db in
      try Recipe.fetchOne(db, key: id)
    }
  }

  /// Resolve a stable persisted recipe ID for downstream foreign-key writes.
  /// If a recipe row is unexpectedly missing, we attempt title-based recovery and
  /// finally insert a minimal row so cooking history can still be recorded.
  func resolvePersistedRecipeID(for recipe: Recipe) throws -> Int64 {
    try db.write { db in
      if let id = recipe.id, try Recipe.fetchOne(db, key: id) != nil {
        return id
      }

      let titleKey = recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !titleKey.isEmpty,
        let existingID = try Int64.fetchOne(
          db,
          sql: """
            SELECT id
            FROM recipes
            WHERE LOWER(TRIM(title)) = ?
            ORDER BY id ASC
            LIMIT 1
            """,
          arguments: [titleKey]
        )
      {
        return existingID
      }

      let safeTitle =
        recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Untitled Recipe" : recipe.title
      let safeTime = max(1, recipe.timeMinutes)
      let safeServings = max(1, recipe.servings)
      let safeInstructions =
        recipe.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "No instructions provided."
        : recipe.instructions

      try db.execute(
        sql: """
          INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [safeTitle, safeTime, safeServings, safeInstructions, recipe.tags, "bundled"]
      )
      return db.lastInsertedRowID
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
          notes: row["notes"],
          description: row["description"],
          categoryLabel: row["category_label"],
          spriteGroup: row["sprite_group"],
          spriteKey: row["sprite_key"]
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
      let mutableRecipe = recipe
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
