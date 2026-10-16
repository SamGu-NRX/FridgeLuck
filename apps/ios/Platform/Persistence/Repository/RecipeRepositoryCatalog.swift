import FLFeatureLogic
import Foundation
import GRDB

/// Catalog read paths on the central recipe repository: structured lines and steps for
/// recipe detail and cook mode, plus the legacy-id bridge that keeps cooking history
/// resolving to structured content. The legacy `recipes` rows are never rewritten.
extension RecipeRepository {
  /// Full structured catalog recipe, or nil when the id is unknown. Rows hydrated from the
  /// legacy data.json come back with empty `steps` and nil `nutrition`.
  func catalogRecipe(catalogId: String) throws -> RecipeCatalogRecipe? {
    try db.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM recipes_catalog WHERE catalog_id = ?",
          arguments: [catalogId]
        )
      else { return nil }
      return try Self.makeCatalogRecipe(from: row, db: db)
    }
  }

  /// All catalog recipes, ordered by title. Enough for browse surfaces; use
  /// `catalogRecipe(catalogId:)` for detail and cook mode.
  func catalogRecipes(limit: Int = 300) throws -> [RecipeCatalogRecipe] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT * FROM recipes_catalog ORDER BY title LIMIT ?",
        arguments: [limit]
      )
      return try rows.map { try Self.makeCatalogRecipe(from: $0, db: db) }
    }
  }

  /// The catalog id a legacy recipe id resolves to, so a cooking-history row pointing at
  /// the legacy integer id can open structured content.
  func catalogRecipeID(forLegacyRecipeID legacyID: Int64) throws -> String? {
    try db.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT catalog_id FROM recipes_catalog
          WHERE legacy_recipe_id = ?
          ORDER BY revision DESC
          LIMIT 1
          """,
        arguments: [legacyID]
      )
    }
  }

  /// The per-serving nutrition snapshot stored for a specific revision. Historical rows are
  /// written once and never rewritten, so meals logged against an older revision keep the
  /// values they were logged with.
  func catalogNutrition(catalogId: String, revision: Int) throws -> RecipeCatalogNutrition? {
    try db.read { db in
      guard
        let json = try String.fetchOne(
          db,
          sql:
            "SELECT nutrition FROM recipes_catalog_nutrition WHERE catalog_id = ? AND revision = ?",
          arguments: [catalogId, revision]
        )
      else { return nil }
      return try Self.decodeJSON(RecipeCatalogNutrition.self, from: json)
    }
  }

  /// The per-serving nutrition snapshot the meal was logged against: the frozen
  /// `recipes_catalog_nutrition` row at the revision recorded for that history entry
  /// (`recipes_cooking_catalog_refs`). Nil when the meal has no catalog link (a legacy
  /// cook) or the linked revision row is absent — never a re-derivation from the
  /// currently installed revision, which would rewrite history.
  func catalogNutrition(forHistoryID historyId: Int64) throws -> RecipeCatalogNutrition? {
    try db.read { db in
      guard
        let json = try String.fetchOne(
          db,
          sql: """
            SELECT n.nutrition
            FROM recipes_cooking_catalog_refs r
            JOIN recipes_catalog_nutrition n
              ON n.catalog_id = r.catalog_id AND n.revision = r.revision
            WHERE r.history_id = ?
            """,
          arguments: [historyId]
        )
      else { return nil }
      return try Self.decodeJSON(RecipeCatalogNutrition.self, from: json)
    }
  }

  // MARK: - Row assembly

  private static func makeCatalogRecipe(from row: Row, db: Database) throws -> RecipeCatalogRecipe {
    let catalogId: String = row["catalog_id"]
    let revision: Int = row["revision"]

    let lines = try Row.fetchAll(
      db,
      sql: """
        SELECT ingredient_key, quantity_kind, quantity_grams, quantity_amount,
               quantity_unit, quantity_note, is_required, assumed_staple, note
        FROM recipes_catalog_lines
        WHERE catalog_id = ?
        ORDER BY position ASC
        """,
      arguments: [catalogId]
    ).map { lineRow -> RecipeCatalogLine in
      let kind: String = lineRow["quantity_kind"]
      let quantity: RecipeCatalogQuantity
      switch kind {
      case "grams":
        quantity = .grams(lineRow["quantity_grams"] ?? 0)
      case "count":
        quantity = .count(
          amount: lineRow["quantity_amount"] ?? 0,
          unit: lineRow["quantity_unit"] ?? "",
          grams: lineRow["quantity_grams"]
        )
      case "household":
        quantity = .household(
          amount: lineRow["quantity_amount"] ?? 0,
          unit: lineRow["quantity_unit"] ?? "",
          grams: lineRow["quantity_grams"]
        )
      default:
        quantity = .unknown(note: lineRow["quantity_note"])
      }
      return RecipeCatalogLine(
        key: lineRow["ingredient_key"],
        quantity: quantity,
        required: lineRow["is_required"] ?? true,
        assumedStaple: lineRow["assumed_staple"] ?? false,
        note: lineRow["note"]
      )
    }

    let steps = try Row.fetchAll(
      db,
      sql: """
        SELECT text, uses, timer_seconds, thermometer_endpoint_c,
               thermometer_food, thermometer_source
        FROM recipes_catalog_steps
        WHERE catalog_id = ?
        ORDER BY position ASC
        """,
      arguments: [catalogId]
    ).map { stepRow -> RecipeCatalogStep in
      let usesJSON: String = stepRow["uses"]
      let uses = (try? Self.decodeJSON([Int].self, from: usesJSON)) ?? []
      let endpoint: Double? = stepRow["thermometer_endpoint_c"]
      let thermometer: RecipeCatalogThermometer?
      if let endpoint,
        let food: String = stepRow["thermometer_food"],
        let source: String = stepRow["thermometer_source"]
      {
        thermometer = RecipeCatalogThermometer(endpointC: endpoint, food: food, source: source)
      } else {
        thermometer = nil
      }
      return RecipeCatalogStep(
        text: stepRow["text"],
        uses: uses,
        timerSeconds: stepRow["timer_seconds"],
        thermometer: thermometer
      )
    }

    let claimsJSON: String = row["claims"]
    let claims =
      (try? Self.decodeJSON(RecipeCatalogClaims.self, from: claimsJSON))
      ?? RecipeCatalogClaims(vegetarian: nil, vegan: nil, glutenFree: nil, dairyFree: nil)

    let nutritionJSON: String? = row["nutrition"]
    let nutrition = nutritionJSON.flatMap {
      try? Self.decodeJSON(RecipeCatalogNutrition.self, from: $0)
    }

    let rights = RecipeCatalogRights(
      status: RecipeCatalogRightsStatus(rawValue: row["rights_status"] ?? "") ?? .quarantined,
      evidence: row["rights_evidence"] ?? ""
    )

    let mealSlotsJSON: String = row["meal_slots"]
    let collectionsJSON: String = row["collections"]
    let equipmentJSON: String = row["equipment"]
    let keywordsJSON: String = row["keywords"]

    return RecipeCatalogRecipe(
      catalogId: catalogId,
      revision: revision,
      title: row["title"],
      cuisine: RecipeCatalogCuisine(rawValue: row["cuisine"] ?? "") ?? .american,
      mealSlots: (try? Self.decodeJSON([RecipeCatalogMealSlot].self, from: mealSlotsJSON)) ?? [],
      collections: (try? Self.decodeJSON([RecipeCatalogCollection].self, from: collectionsJSON))
        ?? [],
      minutes: row["minutes"],
      servings: row["servings"],
      equipment: (try? Self.decodeJSON([String].self, from: equipmentJSON)) ?? [],
      lines: lines,
      steps: steps,
      claims: claims,
      nutrition: nutrition,
      rights: rights,
      keywords: (try? Self.decodeJSON([String].self, from: keywordsJSON)) ?? [],
      legacyRecipeId: row["legacy_recipe_id"]
    )
  }

  private static func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }
}

// MARK: - Cook Packet (Preview Drawer + Cook Mode)

/// A catalog recipe's structured cook content in the FLFeatureLogic shapes the preview
/// drawer and cook mode consume: ingredient lines as `CookQuantity`, steps as `CookStep`
/// (timers and thermometer checks carried verbatim from the bundle).
struct RecipeCatalogCookPacket: Equatable, Sendable {
  struct Line: Equatable, Sendable {
    let key: String
    /// Vocabulary display name when the key is in the catalog vocabulary.
    let displayName: String?
    /// First app ingredient id the hydration bridge resolved for this key, or nil when
    /// the key is "not in your kitchen" (no exact identity evidence).
    let bridgedIngredientId: Int64?
    let quantity: CookQuantity
    let required: Bool
    let assumedStaple: Bool
  }

  let catalogId: String
  let revision: Int
  let title: String
  let minutes: Int
  let servings: Int
  let lines: [Line]
  let steps: [CookStep]
}

extension RecipeRepository {
  /// Structured lines and steps for a catalog recipe, or nil for an unknown catalog id.
  /// For legacy recipes the drawer/cook flow keeps using the legacy instructions path.
  func catalogCookPacket(catalogId: String) throws -> RecipeCatalogCookPacket? {
    try db.read { db in
      guard
        let header = try Row.fetchOne(
          db,
          sql:
            "SELECT catalog_id, revision, title, minutes, servings FROM recipes_catalog WHERE catalog_id = ?",
          arguments: [catalogId])
      else { return nil }

      let lines = try Row.fetchAll(
        db,
        sql: """
          SELECT l.ingredient_key, ci.display_name AS display_name,
              (SELECT b.ingredient_id FROM recipes_catalog_ingredient_bridge b
                WHERE b.ingredient_key = l.ingredient_key
                ORDER BY b.ingredient_id LIMIT 1) AS bridged_id,
              l.quantity_kind, l.quantity_grams, l.quantity_amount, l.quantity_unit,
              l.quantity_note, l.is_required, l.assumed_staple
          FROM recipes_catalog_lines l
          LEFT JOIN recipes_catalog_ingredients ci ON ci.key = l.ingredient_key
          WHERE l.catalog_id = ?
          ORDER BY l.position ASC
          """,
        arguments: [catalogId]
      ).map { lineRow -> RecipeCatalogCookPacket.Line in
        let kind: String = lineRow["quantity_kind"]
        let quantity: CookQuantity
        switch kind {
        case "grams":
          quantity = .grams(lineRow["quantity_grams"] ?? 0)
        case "count":
          quantity = .count(
            amount: lineRow["quantity_amount"] ?? 0,
            unit: lineRow["quantity_unit"] ?? "",
            grams: lineRow["quantity_grams"]
          )
        case "household":
          quantity = .household(
            amount: lineRow["quantity_amount"] ?? 0,
            unit: lineRow["quantity_unit"] ?? "",
            grams: lineRow["quantity_grams"]
          )
        default:
          quantity = .unknown(note: lineRow["quantity_note"])
        }
        return RecipeCatalogCookPacket.Line(
          key: lineRow["ingredient_key"],
          displayName: lineRow["display_name"],
          bridgedIngredientId: lineRow["bridged_id"],
          quantity: quantity,
          required: lineRow["is_required"] ?? true,
          assumedStaple: lineRow["assumed_staple"] ?? false
        )
      }

      let steps = try Row.fetchAll(
        db,
        sql: """
          SELECT text, uses, timer_seconds, thermometer_endpoint_c,
                 thermometer_food, thermometer_source
          FROM recipes_catalog_steps
          WHERE catalog_id = ?
          ORDER BY position ASC
          """,
        arguments: [catalogId]
      ).map { stepRow -> CookStep in
        let usesJSON: String = stepRow["uses"]
        let uses = (try? JSONDecoder().decode([Int].self, from: Data(usesJSON.utf8))) ?? []
        let endpoint: Double? = stepRow["thermometer_endpoint_c"]
        let thermometer: CookThermometer?
        if let endpoint,
          let food: String = stepRow["thermometer_food"],
          let source: String = stepRow["thermometer_source"]
        {
          thermometer = CookThermometer(endpointC: endpoint, food: food, source: source)
        } else {
          thermometer = nil
        }
        return CookStep(
          text: stepRow["text"],
          uses: uses,
          timerSeconds: stepRow["timer_seconds"],
          thermometer: thermometer
        )
      }

      return RecipeCatalogCookPacket(
        catalogId: header["catalog_id"],
        revision: header["revision"],
        title: header["title"],
        minutes: header["minutes"],
        servings: header["servings"],
        lines: lines,
        steps: steps
      )
    }
  }

  /// The catalog cook packet for a recommendation drawn from the catalog pool, or nil
  /// for legacy-only results and unknown refs. This is the single path the cooking guide
  /// and the assistant context use to cook a catalog recommendation; legacy results keep
  /// the legacy instructions path.
  func catalogCookPacket(for scoredRecipe: ScoredRecipe) throws -> RecipeCatalogCookPacket? {
    guard let catalogId = scoredRecipe.catalog?.ref.id else { return nil }
    return try catalogCookPacket(catalogId: catalogId)
  }

  /// The packet's bridged ingredient list in the legacy `(Ingredient, RecipeIngredient)`
  /// shape the cooking guide and assistant context consume. Only lines whose key resolved
  /// to an app ingredient at hydration appear — unresolved "not in your kitchen" keys are
  /// never matched by name. Quantities render as authored: grams weighed, otherwise the
  /// household unit text, otherwise the recipe's own note. No synthesized units.
  func cookPacketIngredients(
    _ packet: RecipeCatalogCookPacket
  ) throws -> [(ingredient: Ingredient, quantity: RecipeIngredient)] {
    let bridgedIDs = Set(packet.lines.compactMap(\.bridgedIngredientId))
    let ingredientsByID: [Int64: Ingredient] =
      bridgedIDs.isEmpty
      ? [:]
      : try ingredients(withIDs: bridgedIDs)
    return packet.lines.compactMap { line in
      guard let id = line.bridgedIngredientId, let ingredient = ingredientsByID[id]
      else { return nil }
      return (
        ingredient,
        RecipeIngredient(
          recipeId: 0,
          ingredientId: id,
          isRequired: line.required,
          quantityGrams: Self.quantityGrams(line.quantity) ?? 0,
          displayQuantity: Self.quantityText(line.quantity)
        )
      )
    }
  }

  /// Mass for a quantity, only when it carries evidence-backed grams.
  private static func quantityGrams(_ quantity: CookQuantity) -> Double? {
    switch quantity {
    case .grams(let grams):
      return grams
    case .household(_, _, let grams), .count(_, _, let grams):
      return grams
    case .unknown:
      return nil
    }
  }

  /// Renders the quantity as authored: grams weighed, otherwise the household unit text,
  /// otherwise the recipe's own note ("to taste"). No synthesized units.
  private static func quantityText(_ quantity: CookQuantity) -> String {
    switch quantity {
    case .grams(let grams):
      let rounded = (grams * 10).rounded() / 10
      return rounded == rounded.rounded()
        ? "\(Int(rounded)) g" : String(format: "%.1f g", rounded)
    case .count(let amount, let unit, _), .household(let amount, let unit, _):
      let amountText =
        amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2g", amount)
      return unit.isEmpty ? amountText : "\(amountText) \(unit)"
    case .unknown(let note):
      return note ?? ""
    }
  }
}
