import FLFeatureLogic
import Foundation
import GRDB

/// Catalog-pool recommendation matching (bundle v2), merged with the legacy search.
///
/// Matching is by exact ingredient identity only: a catalog line participates when its
/// canonical key was resolved to app ingredient ids by the hydration-time bridge
/// (`recipes_catalog_ingredient_bridge`). A line whose key has no bridge rows is "not in
/// your kitchen" — it counts as missing and is never matched by name similarity.
///
/// Scoring uses the shared `RecipeScoring` weights, unchanged. The one added signal is
/// use-soon urgency (the pantry holds an inventory lot for an ingredient the recipe uses,
/// expiring within the horizon), applied identically to both pools.

extension ScoredRecipeID {
  /// True when the identity names a catalog recipe rather than a legacy integer id.
  var isCatalog: Bool {
    if case .catalog = self { return true }
    return false
  }
}

extension RecipeRepository {
  /// Ranking bonus for a recipe that uses a use-soon ingredient. Same magnitude as the
  /// existing quick-cook bonus (the ≤15-minute term in `sharedRankingScore`).
  static let useSoonBonus: Double = 6.0
  /// Inventory horizon for use-soon urgency, mirroring
  /// `InventoryRepository.useSoonSuggestions` (its default 3-day window).
  static let useSoonHorizonDays = 3
  static let useSoonReason = "Use soon (expiring in your kitchen)"

  /// Scores the catalog pool for a pantry. `minMissingRequired`/`maxMissingRequired`
  /// select the tier: exact (0–0) or near-match (1–max).
  func catalogMatches(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    minMissingRequired: Int,
    maxMissingRequired: Int,
    matchTier: RecipeMatchTier,
    limit: Int
  ) throws -> [ScoredRecipe] {
    guard !availableIds.isEmpty else { return [] }
    let bridge = try bridgeIDsByKey()
    guard !bridge.isEmpty else { return [] }

    let useSoon = try useSoonIngredientIDs()

    // The household boundary every offering surface shares. Allergen groups are re-derived
    // from the stored ids at query time (keyword groups over the CURRENT ingredient table),
    // so ingredient rows added after onboarding — later FDC vocabulary additions among
    // them — are covered.
    let boundary = try db.read { db in try HouseholdSafetyBoundary.load(profile: profile, in: db) }

    let rows = try db.read { db -> [Row] in
      try Row.fetchAll(
        db,
        sql: """
          SELECT r.catalog_id, r.revision, r.title, r.minutes, r.servings,
                 r.claims, r.nutrition, r.legacy_recipe_id,
                 l.ingredient_key, l.is_required, l.assumed_staple
          FROM recipes_catalog r
          LEFT JOIN recipes_catalog_lines l ON l.catalog_id = r.catalog_id
          WHERE r.rights_status = 'original'
          ORDER BY r.catalog_id ASC, l.position ASC
          """)
    }

    // Group lines under their recipe header (the first row of each catalog_id).
    var headers: [String: Row] = [:]
    var linesByCatalogID: [String: [Row]] = [:]
    var order: [String] = []
    for row in rows {
      let catalogId: String = row["catalog_id"]
      if headers[catalogId] == nil {
        headers[catalogId] = row
        order.append(catalogId)
      }
      if row["ingredient_key"] != nil {
        linesByCatalogID[catalogId, default: []].append(row)
      }
    }

    var results: [ScoredRecipe] = []
    for catalogId in order {
      let header = headers[catalogId]!
      let lineRows = linesByCatalogID[catalogId] ?? []

      // The household admission rule, shared with the weekly plan: the composition screen
      // (keto fails closed there too), the explicit exclusions over every bridge row of
      // every line, and the diet claim gate.
      let claimsData: String? = header["claims"]
      guard
        boundary.admitsCatalogRecipe(
          lineKeys: lineRows.map { row -> String in
            let key: String? = row["ingredient_key"]
            return key ?? ""
          },
          claimsJSON: claimsData)
      else { continue }

      var usedIDs = Set<Int64>()
      var matchedRequired = 0
      var totalRequired = 0
      var matchedOptional = 0
      var missingRequired = 0
      var missingIDs = Set<Int64>()

      for lineRow in lineRows {
        let key: String = lineRow["ingredient_key"]
        let bridged = bridge[key] ?? []
        usedIDs.formUnion(bridged)
        let matched = !bridged.isDisjoint(with: availableIds)
        let required: Bool = lineRow["is_required"] ?? true
        let assumedStaple: Bool = lineRow["assumed_staple"] ?? false

        if required, !assumedStaple {
          // Assumed-staple lines never block a match: they mark pantry-stable items the
          // fridge need not contain. When present they count like optional matches.
          totalRequired += 1
          if matched {
            matchedRequired += 1
          } else {
            missingRequired += 1
            missingIDs.formUnion(bridged)
          }
        } else if matched {
          matchedOptional += 1
        }
      }

      guard missingRequired >= minMissingRequired,
        missingRequired <= maxMissingRequired
      else { continue }
      guard totalRequired > 0 else { continue }

      let title: String = header["title"]
      let minutes: Int = header["minutes"] ?? 30
      let servings: Int = header["servings"] ?? 2
      let recipe = Recipe(
        id: nil,
        title: title,
        timeMinutes: minutes,
        servings: servings,
        instructions: "",
        tags: 0,
        source: .bundled,
        createdAt: nil
      )

      let macros = Self.catalogMacros(fromJSON: header["nutrition"])
      let healthScore = try healthScoringService.score(macros: macros)
      // Catalog recipes carry no cooking history yet, so personalization is neutral zero;
      // a successor entry inherits its legacy recipe's personalization via the legacy
      // pool entry it yields to.
      let personalScore = 0.0
      var rankingScore = Self.sharedRankingScore(
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

      if !useSoon.isEmpty && !usedIDs.isDisjoint(with: useSoon) {
        rankingScore += Self.useSoonBonus
        reasons.append(Self.useSoonReason)
      }

      let revision: Int = header["revision"] ?? 1
      let legacyRecipeID: Int64? = header["legacy_recipe_id"]
      results.append(
        ScoredRecipe(
          recipe: recipe,
          matchedRequired: matchedRequired,
          totalRequired: totalRequired,
          matchedOptional: matchedOptional,
          missingRequiredCount: missingRequired,
          missingIngredientIds: missingIDs.sorted(),
          macros: macros,
          healthScore: healthScore,
          personalScore: personalScore,
          rankingScore: rankingScore,
          rankingReasons: reasons,
          matchTier: matchTier,
          catalog: CatalogRecipeMatch(
            ref: .catalog(id: catalogId, revision: revision),
            successorToLegacyRecipeID: legacyRecipeID
          )
        ))
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

  /// Merges legacy and catalog pools into one ranked list.
  ///
  /// 1. Successor dedupe: a catalog recipe whose legacy successor matches the pantry
  ///    anywhere in the engine's tiers (0–2 missing required) is dropped, so the dish
  ///    appears once, as the legacy entry (its integer id anchors cooking history,
  ///    meals, and personalization).
  /// 2. Use-soon bonus applied to legacy entries the same way the catalog pool applies it.
  /// 3. Shared sort: ranking score desc, then missing count asc, then time asc.
  func mergedResults(
    legacy: [ScoredRecipe],
    catalog: [ScoredRecipe],
    availableIds: Set<Int64>,
    profile: HealthProfile,
    limit: Int
  ) throws -> [ScoredRecipe] {
    let catalogSuccessors = Set(catalog.compactMap { $0.catalog?.successorToLegacyRecipeID })
    var dedupedCatalog = catalog
    if !catalogSuccessors.isEmpty {
      let matchableLegacy = try legacyRecipeIDsMatching(
        with: availableIds,
        profile: profile,
        maxMissingRequired: 2
      )
      dedupedCatalog = catalog.filter { entry in
        guard let successorID = entry.catalog?.successorToLegacyRecipeID else { return true }
        return !matchableLegacy.contains(successorID)
      }
    }

    var boostedLegacy = legacy
    let useSoon = try useSoonIngredientIDs()
    if !useSoon.isEmpty && !legacy.isEmpty {
      let legacyUsingSoon = try legacyRecipeIDsUsingUseSoon(useSoon)
      boostedLegacy = legacy.map { scored in
        guard let id = scored.recipe.id, legacyUsingSoon.contains(id) else { return scored }
        return ScoredRecipe(
          recipe: scored.recipe,
          matchedRequired: scored.matchedRequired,
          totalRequired: scored.totalRequired,
          matchedOptional: scored.matchedOptional,
          missingRequiredCount: scored.missingRequiredCount,
          missingIngredientIds: scored.missingIngredientIds,
          macros: scored.macros,
          healthScore: scored.healthScore,
          personalScore: scored.personalScore,
          rankingScore: scored.rankingScore + Self.useSoonBonus,
          rankingReasons: scored.rankingReasons + [Self.useSoonReason],
          matchTier: scored.matchTier,
          catalog: scored.catalog
        )
      }
    }

    var merged = boostedLegacy + dedupedCatalog
    merged.sort { lhs, rhs in
      if lhs.rankingScore == rhs.rankingScore {
        if lhs.missingRequiredCount == rhs.missingRequiredCount {
          return lhs.recipe.timeMinutes < rhs.recipe.timeMinutes
        }
        return lhs.missingRequiredCount < rhs.missingRequiredCount
      }
      return lhs.rankingScore > rhs.rankingScore
    }
    if merged.count > limit {
      return Array(merged.prefix(limit))
    }
    return merged
  }

  // MARK: - Shared Queries

  /// Bridge map: canonical key -> app ingredient ids it stands for.
  func bridgeIDsByKey() throws -> [String: Set<Int64>] {
    try db.read { db in
      var map: [String: Set<Int64>] = [:]
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge")
      for row in rows {
        guard let key: String = row["ingredient_key"], let id: Int64 = row["ingredient_id"]
        else { continue }
        map[key, default: []].insert(id)
      }
      return map
    }
  }

  /// App ingredient rows by id, for rendering catalog lines that bridge to real
  /// ingredients (drawer ingredient section, substitution targets).
  func ingredients(withIDs ids: Set<Int64>) throws -> [Int64: Ingredient] {
    guard !ids.isEmpty else { return [:] }
    let idList = ids.sorted().map(String.init).joined(separator: ",")
    return try db.read { db in
      var map: [Int64: Ingredient] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT * FROM ingredients WHERE id IN (\(idList))") {
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
        if let id = ingredient.id {
          map[id] = ingredient
        }
      }
      return map
    }
  }
  /// Pantry ingredient ids with an open inventory lot expiring within the use-soon
  /// horizon. Mirrors `InventoryRepository.useSoonSuggestions`' predicate.
  func useSoonIngredientIDs() throws -> Set<Int64> {
    try db.read { db in
      Set(
        try Int64.fetchAll(
          db,
          sql: """
            SELECT DISTINCT ingredient_id FROM inventory_lots
            WHERE remaining_grams > 0
              AND expires_at IS NOT NULL
              AND datetime(expires_at) >= datetime('now')
              AND datetime(expires_at) <= datetime('now', '+\(Self.useSoonHorizonDays) days')
            """))
    }
  }

  /// Legacy recipe ids that use any of the given ingredients.
  func legacyRecipeIDsUsingUseSoon(_ ingredientIds: Set<Int64>) throws -> Set<Int64> {
    guard !ingredientIds.isEmpty else { return [] }
    let idList = ingredientIds.sorted().map(String.init).joined(separator: ",")
    return try db.read { db in
      Set(
        try Int64.fetchAll(
          db,
          sql: """
            SELECT DISTINCT recipe_id FROM recipe_ingredients
            WHERE ingredient_id IN (\(idList))
            """))
    }
  }

  /// Legacy recipe ids matching the pantry with 0–`maxMissingRequired` missing required
  /// ingredients that the household boundary admits, the same screen the legacy search
  /// applies. Used for successor dedupe: if the legacy recipe can appear anywhere in results,
  /// its catalog successor stays out; a refused legacy recipe cannot appear, so its successor
  /// may.
  func legacyRecipeIDsMatching(
    with availableIds: Set<Int64>,
    profile: HealthProfile,
    maxMissingRequired: Int
  ) throws -> Set<Int64> {
    guard !availableIds.isEmpty else { return [] }
    let idList = availableIds.sorted().map(String.init).joined(separator: ",")

    return try db.read { db in
      let boundary = try HouseholdSafetyBoundary.load(profile: profile, in: db)
      let linesByRecipe = try Self.legacyIngredientIDsByRecipe(in: db)
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT r.id AS id, r.tags AS tags,
              SUM(CASE WHEN ri.is_required = 1
                   AND ri.ingredient_id NOT IN (\(idList)) THEN 1 ELSE 0 END) AS missing_req
          FROM recipes r
          JOIN recipe_ingredients ri ON r.id = ri.recipe_id
          GROUP BY r.id
          HAVING missing_req BETWEEN 0 AND \(maxMissingRequired)
          """)

      var ids = Set<Int64>()
      for row in rows {
        let recipeId: Int64 = row["id"]
        let tags: Int = row["tags"] ?? 0
        guard
          boundary.legacyRecipeVerdict(
            ingredientIDs: linesByRecipe[recipeId] ?? [], tags: tags
          ).isAllowed
        else { continue }
        ids.insert(recipeId)
      }
      return ids
    }
  }

  /// Per-serving macros for a catalog recipe from its bundled nutrition snapshot, or
  /// zeros when the row carries none (health scoring then rates honestly low).
  static func catalogMacros(fromJSON json: String?) -> RecipeMacros {
    guard let json,
      let nutrition = try? JSONDecoder().decode(RecipeCatalogNutrition.self, from: Data(json.utf8))
    else {
      return RecipeMacros(
        caloriesPerServing: 0, proteinPerServing: 0, carbsPerServing: 0, fatPerServing: 0,
        fiberPerServing: 0, sugarPerServing: 0, sodiumPerServing: 0)
    }
    // The bundle snapshot has no sugar field; the macros struct keeps sugar for the
    // legacy pipeline, so catalog entries report it as unset (0 g).
    return RecipeMacros(
      caloriesPerServing: nutrition.kcal,
      proteinPerServing: nutrition.proteinG,
      carbsPerServing: nutrition.carbsG,
      fatPerServing: nutrition.fatG,
      fiberPerServing: nutrition.fiberG,
      sugarPerServing: 0,
      sodiumPerServing: nutrition.sodiumMg
    )
  }
}
