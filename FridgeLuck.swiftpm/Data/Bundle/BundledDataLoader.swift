import Foundation
import GRDB

// MARK: - Raw JSON Structures (for decoding positional arrays)

/// Top-level structure of data.json
private struct BundledData: Decodable {
  let tags: [String]
  let ingredients: [String: IngredientArray]
  let recipes: [RecipeArray]
}

/// Ingredient: [name, cal, protein, carbs, fat, fiber, sugar, sodium, unit, tip]
private struct IngredientArray: Decodable {
  let name: String
  let calories: Double
  let protein: Double
  let carbs: Double
  let fat: Double
  let fiber: Double
  let sugar: Double
  let sodium: Double
  let typicalUnit: String
  let storageTip: String
  let pairsWith: String?
  let notes: String?

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    name = try container.decode(String.self)
    calories = try container.decode(Double.self)
    protein = try container.decode(Double.self)
    carbs = try container.decode(Double.self)
    fat = try container.decode(Double.self)
    fiber = try container.decode(Double.self)
    sugar = try container.decode(Double.self)
    sodium = try container.decode(Double.self)
    typicalUnit = try container.decode(String.self)
    storageTip = try container.decode(String.self)
    pairsWith = try? container.decode(String.self)
    notes = try? container.decode(String.self)
  }
}

/// Recipe: [id, title, time, servings, required, optional, instructions, tags]
/// required/optional: [[ingredientId, grams], ...]
private struct RecipeArray: Decodable {
  let id: Int
  let title: String
  let timeMinutes: Int
  let servings: Int
  let requiredIngredients: [(id: Int, grams: Double)]
  let optionalIngredients: [(id: Int, grams: Double)]
  let instructions: String
  let tagBitmask: Int

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    id = try container.decode(Int.self)
    title = try container.decode(String.self)
    timeMinutes = try container.decode(Int.self)
    servings = try container.decode(Int.self)

    // Decode ingredient pairs: [[id, grams], ...]
    requiredIngredients = try Self.decodeIngredientPairs(from: &container)
    optionalIngredients = try Self.decodeIngredientPairs(from: &container)

    instructions = try container.decode(String.self)
    tagBitmask = try container.decode(Int.self)
  }

  private static func decodeIngredientPairs(
    from container: inout UnkeyedDecodingContainer
  ) throws -> [(id: Int, grams: Double)] {
    var nested = try container.nestedUnkeyedContainer()
    var pairs: [(id: Int, grams: Double)] = []
    while !nested.isAtEnd {
      var pair = try nested.nestedUnkeyedContainer()
      let ingredientId = try pair.decode(Int.self)
      let grams = try pair.decode(Double.self)
      pairs.append((id: ingredientId, grams: grams))
    }
    return pairs
  }
}

// MARK: - Loader

enum BundledDataLoader {
  /// Load bundled data.json into the SQLite database.
  /// Called once on first launch.
  static func loadInto(_ appDB: AppDatabase) async throws {
    guard let url = Bundle.main.url(forResource: "data", withExtension: "json") else {
      assertionFailure("data.json not found in bundle")
      return
    }

    let jsonData = try Data(contentsOf: url)
    let bundled = try JSONDecoder().decode(BundledData.self, from: jsonData)

    try await appDB.dbQueue.write { db in
      // Insert ingredients
      for (idString, raw) in bundled.ingredients {
        guard let id = Int64(idString) else { continue }
        try db.execute(
          sql: """
            INSERT INTO ingredients
                (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                 typical_unit, storage_tip, description, category_label, sprite_group, sprite_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)
            """,
          arguments: [
            id, raw.name, raw.calories, raw.protein, raw.carbs, raw.fat,
            raw.fiber, raw.sugar, raw.sodium, raw.typicalUnit, raw.storageTip,
          ]
        )
      }

      // Optionally augment bundled base ingredients with curated USDA catalog rows.
      // This keeps the hand-authored core IDs stable while expanding searchable coverage.
      try loadUSDACatalogIngredientsIfAvailable(into: db)

      // Insert recipes + ingredient relationships
      for raw in bundled.recipes {
        try db.execute(
          sql: """
            INSERT INTO recipes
                (id, title, time_minutes, servings, instructions, tags, source)
            VALUES (?, ?, ?, ?, ?, ?, 'bundled')
            """,
          arguments: [
            raw.id, raw.title, raw.timeMinutes, raw.servings,
            raw.instructions, raw.tagBitmask,
          ]
        )

        // Required ingredients
        for (ingId, grams) in raw.requiredIngredients {
          let displayQty = Self.formatDisplayQuantity(
            grams: grams, ingredientId: ingId, ingredients: bundled.ingredients)
          try db.execute(
            sql: """
              INSERT INTO recipe_ingredients
                  (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
              VALUES (?, ?, 1, ?, ?)
              """,
            arguments: [raw.id, ingId, grams, displayQty]
          )
        }

        // Optional ingredients
        for (ingId, grams) in raw.optionalIngredients {
          let displayQty = Self.formatDisplayQuantity(
            grams: grams, ingredientId: ingId, ingredients: bundled.ingredients)
          try db.execute(
            sql: """
              INSERT INTO recipe_ingredients
                  (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
              VALUES (?, ?, 0, ?, ?)
              """,
            arguments: [raw.id, ingId, grams, displayQty]
          )
        }
      }
    }
  }

  /// Import curated USDA ingredient rows from bundled SQLite resource if present.
  /// Uses INSERT OR IGNORE to avoid clobbering the base curated ingredient set.
  private static func loadUSDACatalogIngredientsIfAvailable(into db: Database) throws {
    guard let url = Bundle.main.url(forResource: "usda_ingredient_catalog", withExtension: "sqlite")
    else {
      return
    }

    var readConfig = Configuration()
    readConfig.readonly = true
    let sourceDB = try DatabaseQueue(path: url.path, configuration: readConfig)
    let sourceRows: [Row] = try sourceDB.read { src in
      do {
        return try Row.fetchAll(
          src,
          sql: """
            SELECT
              name,
              calories,
              protein,
              carbs,
              fat,
              fiber,
              sugar,
              sodium,
              notes,
              COALESCE(description, '') AS description,
              COALESCE(category_label, '') AS category_label,
              COALESCE(sprite_group, '') AS sprite_group,
              COALESCE(sprite_key, '') AS sprite_key
            FROM ingredients
            """
        )
      } catch {
        // Backward compatibility for older USDA SQLite resources without display metadata columns.
        return try Row.fetchAll(
          src,
          sql: """
            SELECT
              name,
              calories,
              protein,
              carbs,
              fat,
              fiber,
              sugar,
              sodium,
              notes,
              '' AS description,
              '' AS category_label,
              '' AS sprite_group,
              '' AS sprite_key
            FROM ingredients
            """
        )
      }
    }
    let aliasRows: [Row] = try sourceDB.read { src in
      do {
        return try Row.fetchAll(
          src,
          sql: """
            SELECT i.name AS ingredient_name, a.alias AS alias
            FROM ingredient_aliases a
            JOIN ingredients i ON i.id = a.ingredient_id
            """
        )
      } catch {
        return []
      }
    }

    var ingredientIdByName: [String: Int64] = [:]
    for row in sourceRows {
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO ingredients
              (name, calories, protein, carbs, fat, fiber, sugar, sodium,
               typical_unit, storage_tip, pairs_with, notes, description, category_label, sprite_group, sprite_key)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, ?)
          """,
        arguments: [
          row["name"],
          row["calories"],
          row["protein"],
          row["carbs"],
          row["fat"],
          row["fiber"],
          row["sugar"],
          row["sodium"],
          row["notes"],
          row["description"],
          row["category_label"],
          row["sprite_group"],
          row["sprite_key"],
        ]
      )
      if let name: String = row["name"],
        let id = try Int64.fetchOne(
          db, sql: "SELECT id FROM ingredients WHERE name = ?", arguments: [name])
      {
        ingredientIdByName[name] = id
      }
    }

    for row in aliasRows {
      guard let ingredientName: String = row["ingredient_name"],
        let alias: String = row["alias"],
        !alias.isEmpty,
        let ingredientId = ingredientIdByName[ingredientName]
      else {
        continue
      }
      try? db.execute(
        sql: """
          INSERT OR IGNORE INTO ingredient_aliases (ingredient_id, alias)
          VALUES (?, ?)
          """,
        arguments: [ingredientId, alias.lowercased()]
      )
    }
  }

  /// Build a human-readable quantity string from grams + ingredient info.
  private static func formatDisplayQuantity(
    grams: Double,
    ingredientId: Int,
    ingredients: [String: IngredientArray]
  ) -> String {
    guard let raw = ingredients[String(ingredientId)] else {
      return "\(Int(grams))g"
    }

    // Use the typical_unit info to build a readable quantity
    // For now, just show grams — a future pass can map to cups/tbsp/etc.
    let name = raw.name.replacingOccurrences(of: "_", with: " ")
    return "\(Int(grams))g \(name)"
  }
}
