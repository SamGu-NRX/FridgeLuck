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
          sql: "SELECT nutrition FROM recipes_catalog_nutrition WHERE catalog_id = ? AND revision = ?",
          arguments: [catalogId, revision]
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
    let claims = (try? Self.decodeJSON(RecipeCatalogClaims.self, from: claimsJSON))
      ?? RecipeCatalogClaims(vegetarian: nil, vegan: nil, glutenFree: nil, dairyFree: nil)

    let nutritionJSON: String? = row["nutrition"]
    let nutrition = nutritionJSON.flatMap { try? Self.decodeJSON(RecipeCatalogNutrition.self, from: $0) }

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
