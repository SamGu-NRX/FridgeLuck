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
  /// Use-soon ordering prefers the earliest recorded expiry before the standard score;
  /// standard ordering remains the default for reverse-scan recipe matching.
  func findMakeable(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    limit: Int = 20,
    order: RecipeRankingOrder = .standard,
    now: Date = Date()
  ) throws -> [ScoredRecipe] {
    try queryRecipes(
      with: availableIds,
      profile: profile,
      minMissingRequired: 0,
      maxMissingRequired: 0,
      matchTier: .exact,
      limit: limit,
      order: order,
      now: now
    )
  }

  func findNearMatch(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    maxMissingRequired: Int = 1,
    limit: Int = 20,
    order: RecipeRankingOrder = .standard,
    now: Date = Date()
  ) throws -> [ScoredRecipe] {
    guard maxMissingRequired >= 1 else { return [] }
    return try queryRecipes(
      with: availableIds,
      profile: profile,
      minMissingRequired: 1,
      maxMissingRequired: maxMissingRequired,
      matchTier: .nearMatch,
      limit: limit,
      order: order,
      now: now
    )
  }

  // MARK: - Quick Suggestion ("Make Something Now")

  /// Returns the single best recipe under the standard health and preference ranking.
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
    limit: Int,
    order: RecipeRankingOrder,
    now: Date
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

    let useSoon = order == .useSoon
      ? try useSoonEvidence(availableIDs: availableIds, now: now)
      : [:]
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

      var reasons = Self.rankingReasons(
        recipe: recipe,
        missingRequiredCount: missingRequired,
        macros: macros,
        healthScore: healthScore,
        profile: profile
      )

      if let evidence = useSoon[recipeId] {
        reasons.insert("Uses \(evidence.ingredientName) from your use-soon stock", at: 0)
      }

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
      if order == .useSoon {
        // Keep fewer missing ingredients ahead of urgency within the near-match section.
        if lhs.missingRequiredCount != rhs.missingRequiredCount {
          return lhs.missingRequiredCount < rhs.missingRequiredCount
        }
        let lhsExpiry = lhs.id.flatMap { useSoon[$0]?.expiresAt } ?? .distantFuture
        let rhsExpiry = rhs.id.flatMap { useSoon[$0]?.expiresAt } ?? .distantFuture
        if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
      }
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

  private struct UseSoonEvidence {
    let expiresAt: Date
    let ingredientName: String
  }

  private func useSoonEvidence(availableIDs: Set<Int64>, now: Date) throws
    -> [Int64: UseSoonEvidence]
  {
    let idList = availableIDs.sorted().map(String.init).joined(separator: ",")
    // Use the existing spoilage nudge's three-day window, without inventing a score weight.
    let cutoff = now.addingTimeInterval(3 * 24 * 60 * 60)
    return try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ri.recipe_id, i.name, il.expires_at
          FROM recipe_ingredients ri
          JOIN inventory_lots il ON il.ingredient_id = ri.ingredient_id
          JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ri.is_required = 1 AND ri.quantity_grams > 0
            AND ri.ingredient_id IN (\(idList))
            AND il.remaining_grams > 0
            AND il.expires_at > ? AND il.expires_at <= ?
          ORDER BY il.expires_at ASC, i.id ASC, il.id ASC
          """,
        arguments: [now, cutoff]
      )
      var evidence: [Int64: UseSoonEvidence] = [:]
      for row in rows {
        let recipeID: Int64 = row["recipe_id"]
        if evidence[recipeID] == nil {
          let name: String = row["name"]
          evidence[recipeID] = UseSoonEvidence(
            expiresAt: row["expires_at"],
            ingredientName: name.replacingOccurrences(of: "_", with: " ")
          )
        }
      }
      return evidence
    }
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

  // MARK: - Browse & Search

  /// Fetch all recipes, ordered by title, with an optional limit.
  func fetchAllRecipes(limit: Int = 200) throws -> [Recipe] {
    try db.read { db in
      try Recipe
        .order(Recipe.Columns.title.asc)
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// Search recipes by title using a case-insensitive LIKE query.
  func searchRecipes(query: String, limit: Int = 60) throws -> [Recipe] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return try fetchAllRecipes(limit: limit) }

    return try db.read { db in
      try Recipe
        .filter(Recipe.Columns.title.like("%\(trimmed)%"))
        .order(Recipe.Columns.title.asc)
        .limit(limit)
        .fetchAll(db)
    }
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
      try resolvePersistedRecipeID(in: db, for: recipe)
    }
  }

  /// Transaction-scoped recipe resolution used by higher-level services that
  /// need to compose multiple DB writes atomically.
  func resolvePersistedRecipeID(in db: Database, for recipe: Recipe) throws -> Int64 {
    let titleKey = normalizedTitleKey(recipe.title)

    if let id = recipe.id, try Recipe.fetchOne(db, key: id) != nil {
      // Prefer recipes that have ingredient rows so downstream macro and inventory
      // calculations are deterministic for dashboard/journal aggregates.
      if try recipeHasIngredients(in: db, recipeId: id) {
        return id
      }

      if !titleKey.isEmpty,
        let recoveredID = try ingredientBackedRecipeID(
          in: db,
          normalizedTitleKey: titleKey
        )
      {
        return recoveredID
      }

      return id
    }

    if !titleKey.isEmpty,
      let existingID = try bestMatchingRecipeID(
        in: db,
        normalizedTitleKey: titleKey
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
      arguments: [
        safeTitle,
        safeTime,
        safeServings,
        safeInstructions,
        recipe.tags,
        recipe.source.rawValue,
      ]
    )
    return db.lastInsertedRowID
  }

  private func normalizedTitleKey(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func bestMatchingRecipeID(
    in db: Database,
    normalizedTitleKey: String
  ) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT r.id
        FROM recipes r
        LEFT JOIN recipe_ingredients ri ON ri.recipe_id = r.id
        WHERE LOWER(TRIM(r.title)) = ?
        GROUP BY r.id
        ORDER BY
          CASE WHEN COUNT(ri.ingredient_id) > 0 THEN 0 ELSE 1 END ASC,
          COUNT(ri.ingredient_id) DESC,
          r.id ASC
        LIMIT 1
        """,
      arguments: [normalizedTitleKey]
    )
  }

  private func ingredientBackedRecipeID(
    in db: Database,
    normalizedTitleKey: String
  ) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT r.id
        FROM recipes r
        JOIN recipe_ingredients ri ON ri.recipe_id = r.id
        WHERE LOWER(TRIM(r.title)) = ?
        GROUP BY r.id
        ORDER BY COUNT(ri.ingredient_id) DESC, r.id ASC
        LIMIT 1
        """,
      arguments: [normalizedTitleKey]
    )
  }

  private func recipeHasIngredients(in db: Database, recipeId: Int64) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1
          FROM recipe_ingredients
          WHERE recipe_id = ?
          LIMIT 1
        )
        """,
      arguments: [recipeId]
    ) ?? false
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
