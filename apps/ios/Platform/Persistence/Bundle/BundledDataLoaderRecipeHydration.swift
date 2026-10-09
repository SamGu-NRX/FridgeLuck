import Foundation
import GRDB

extension BundledDataLoader {
  static func upsertBundledRecipeState(_ db: Database, key: String, value: String) throws {
    try db.execute(
      sql: """
        INSERT INTO bundled_recipe_state (key, value, updated_at)
        VALUES (?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = CURRENT_TIMESTAMP
        """,
      arguments: [key, value]
    )
  }

  static func normalizedTitleKey(_ title: String?) -> String? {
    guard let title else { return nil }
    let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return key.isEmpty ? nil : key
  }

  static func insertRecipeIngredients(
    for recipeId: Int64,
    raw: RecipeArray,
    bundledIngredients: [String: IngredientArray],
    into db: Database
  ) throws {
    for (ingId, grams) in raw.requiredIngredients {
      let displayQty = Self.formatDisplayQuantity(
        grams: grams,
        ingredientId: ingId,
        ingredients: bundledIngredients
      )
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (?, ?, 1, ?, ?)
          """,
        arguments: [recipeId, ingId, grams, displayQty]
      )
    }

    for (ingId, grams) in raw.optionalIngredients {
      let displayQty = Self.formatDisplayQuantity(
        grams: grams,
        ingredientId: ingId,
        ingredients: bundledIngredients
      )
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (?, ?, 0, ?, ?)
          """,
        arguments: [recipeId, ingId, grams, displayQty]
      )
    }
  }

  static func ensureRequiredDemoRecipes(
    bundledRecipes: [RecipeArray],
    bundledIngredients: [String: IngredientArray],
    db: Database
  ) throws {
    var bundledByTitle: [String: RecipeArray] = [:]
    for raw in bundledRecipes {
      guard let key = normalizedTitleKey(raw.title), bundledByTitle[key] == nil else { continue }
      bundledByTitle[key] = raw
    }

    for demoTitle in requiredDemoRecipeTitles {
      guard
        let key = normalizedTitleKey(demoTitle),
        let raw = bundledByTitle[key]
      else {
        continue
      }

      // Repair only rows that no bundle entry owns and that hydration wrote
      // (source = 'bundled'): a user-created or user-modified same-title recipe
      // must never be reclassified as bundle content, and a row the refresh
      // already owns is the refresher's to fix.
      let bundleSourcedUnownedRow = try Row.fetchOne(
        db,
        sql: """
          SELECT id, time_minutes, servings, instructions
          FROM recipes
          WHERE LOWER(TRIM(title)) = ? AND ownership_key IS NULL AND source = 'bundled'
          ORDER BY id ASC
          LIMIT 1
          """,
        arguments: [key]
      )

      let sameTitleCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM recipes WHERE LOWER(TRIM(title)) = ?",
          arguments: [key]
        ) ?? 0

      if let existingRow = bundleSourcedUnownedRow {
        let recipeID: Int64 = existingRow["id"]
        let ingredientCount =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM recipe_ingredients WHERE recipe_id = ?",
            arguments: [recipeID]
          ) ?? 0
        let timeMinutes: Int = existingRow["time_minutes"]
        let servings: Int = existingRow["servings"]
        let instructions: String = existingRow["instructions"]

        let bundleKey = BundleOwnership.recipeKey(bundleRecipeId: raw.id)
        let keyTaken: Int = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM recipes WHERE ownership_key = ? AND id <> ?",
          arguments: [bundleKey, recipeID]
        ) ?? 0

        let needsRepair =
          keyTaken == 0
          && (
            ingredientCount == 0
              || timeMinutes <= 0
              || servings <= 0
              || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )

        guard needsRepair else { continue }

        try db.execute(
          sql: """
            UPDATE recipes
            SET time_minutes = ?, servings = ?, instructions = ?, tags = ?, source = 'bundled',
                ownership_key = ?, bundle_content_hash = ?
            WHERE id = ?
            """,
          arguments: [
            raw.timeMinutes, raw.servings, raw.instructions, raw.tagBitmask,
            bundleKey,
            CanonicalHash.hash(fields: BundleRowProjection.recipeFields(raw)),
            recipeID,
          ]
        )
        try db.execute(
          sql: "DELETE FROM recipe_ingredients WHERE recipe_id = ?",
          arguments: [recipeID]
        )
        try insertRecipeIngredients(
          for: recipeID,
          raw: raw,
          bundledIngredients: bundledIngredients,
          into: db
        )
      } else if sameTitleCount == 0 {
        let bundleKey = BundleOwnership.recipeKey(bundleRecipeId: raw.id)
        try db.execute(
          sql: """
            INSERT INTO recipes
                (title, time_minutes, servings, instructions, tags, source,
                 ownership_key, bundle_content_hash)
            VALUES (?, ?, ?, ?, ?, 'bundled', ?, ?)
            """,
          arguments: [
            raw.title, raw.timeMinutes, raw.servings, raw.instructions, raw.tagBitmask,
            bundleKey,
            CanonicalHash.hash(fields: BundleRowProjection.recipeFields(raw)),
          ]
        )
        let recipeID = db.lastInsertedRowID
        try insertRecipeIngredients(
          for: recipeID,
          raw: raw,
          bundledIngredients: bundledIngredients,
          into: db
        )
      }
      // else: the only same-title rows are user-owned, user-modified, or already
      // bundle-owned; leave them alone and let the refresh reconcile the entry.
    }
  }

  /// Build a human-readable quantity string from grams + ingredient info.
  static func formatDisplayQuantity(
    grams: Double,
    ingredientId: Int,
    ingredients: [String: IngredientArray]
  ) -> String {
    guard let raw = ingredients[String(ingredientId)] else {
      return "\(Int(grams))g"
    }

    let name = raw.name.replacingOccurrences(of: "_", with: " ")
    return "\(Int(grams))g \(name)"
  }
}
