import Foundation
import GRDB

// MARK: - Raw JSON Structures (for decoding positional arrays)

/// Top-level structure of data.json
struct BundledData: Decodable {
  let tags: [String]
  let ingredients: [String: IngredientArray]
  let recipes: [RecipeArray]
}

/// Ingredient: [name, cal, protein, carbs, fat, fiber, sugar, sodium, unit, tip]
struct IngredientArray: Decodable {
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
struct RecipeArray: Decodable {
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
  private enum BundledRecipeStateKey {
    static let bundleMarker = "bundle_marker"
    static let recipeCount = "recipe_count"
    static let hydratedAt = "hydrated_at_utc"
  }

  private enum USDAStateKey {
    static let bundleMarker = "bundle_marker"
    static let ingredientCount = "ingredient_count"
    static let aliasCount = "alias_count"
    static let hydratedAt = "hydrated_at_utc"
  }

  private static let minimumExpectedBundledRecipeCount = 100
  private static let minimumExpectedCatalogIngredientCount = 300
  static let requiredDemoRecipeTitles: [String] = [
    "Classic Egg Fried Rice",
    "Banana Oat Pancakes",
    "Mediterranean Chickpea Salad",
    "Black Bean Tacos",
  ]

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

      try loadUSDACatalogIngredientsIfAvailable(into: db)

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

  /// Ensure bundled USDA catalog rows are present for existing installs.
  /// Safe to run at every launch because inserts are idempotent.
  static func ensureUSDACatalogHydrated(into appDB: AppDatabase) async throws {
    try await appDB.dbQueue.write { db in
      guard
        let url = Bundle.main.url(forResource: "usda_ingredient_catalog", withExtension: "sqlite")
      else {
        return
      }

      let marker = catalogMarker(for: url)
      let ingredientCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients") ?? 0
      let aliasCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredient_aliases") ?? 0
      let lastImportedMarker = try String.fetchOne(
        db,
        sql: "SELECT value FROM usda_catalog_state WHERE key = ?",
        arguments: [USDAStateKey.bundleMarker]
      )

      let shouldHydrate =
        lastImportedMarker != marker
        || ingredientCount < minimumExpectedCatalogIngredientCount
        || aliasCount == 0

      guard shouldHydrate else {
        return
      }

      try loadUSDACatalogIngredientsIfAvailable(into: db)

      let hydratedIngredientCount =
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients") ?? 0
      let hydratedAliasCount =
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredient_aliases") ?? 0
      let hydratedAt = ISO8601DateFormatter().string(from: Date())

      try upsertUSDACatalogState(db, key: USDAStateKey.bundleMarker, value: marker)
      try upsertUSDACatalogState(
        db, key: USDAStateKey.ingredientCount, value: String(hydratedIngredientCount))
      try upsertUSDACatalogState(
        db, key: USDAStateKey.aliasCount, value: String(hydratedAliasCount))
      try upsertUSDACatalogState(db, key: USDAStateKey.hydratedAt, value: hydratedAt)
    }
  }

  /// Ensure bundled recipes are present for existing installs.
  /// Safe to run at every launch because inserts are idempotent by normalized title.
  static func ensureBundledRecipesHydrated(into appDB: AppDatabase) async throws {
    guard let url = Bundle.main.url(forResource: "data", withExtension: "json") else {
      return
    }
    let marker = catalogMarker(for: url)
    let jsonData = try Data(contentsOf: url)
    let bundled = try JSONDecoder().decode(BundledData.self, from: jsonData)

    try await appDB.dbQueue.write { db in
      let existingBundledCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM recipes WHERE source = 'bundled'"
        ) ?? 0
      let lastImportedMarker = try String.fetchOne(
        db,
        sql: "SELECT value FROM bundled_recipe_state WHERE key = ?",
        arguments: [BundledRecipeStateKey.bundleMarker]
      )

      let shouldHydrate =
        lastImportedMarker != marker
        || existingBundledCount < minimumExpectedBundledRecipeCount
      var insertedCount = 0
      if shouldHydrate {
        let existingTitleRows = try Row.fetchAll(
          db,
          sql: "SELECT title FROM recipes WHERE source = 'bundled'"
        )
        var existingTitleKeys = Set(
          existingTitleRows.compactMap { row in
            let title: String? = row["title"]
            return normalizedTitleKey(title)
          }
        )

        for raw in bundled.recipes {
          guard let titleKey = normalizedTitleKey(raw.title) else { continue }
          guard !existingTitleKeys.contains(titleKey) else { continue }

          try db.execute(
            sql: """
              INSERT INTO recipes
                  (title, time_minutes, servings, instructions, tags, source)
              VALUES (?, ?, ?, ?, ?, 'bundled')
              """,
            arguments: [
              raw.title, raw.timeMinutes, raw.servings, raw.instructions, raw.tagBitmask,
            ]
          )
          let newRecipeId = db.lastInsertedRowID
          insertedCount += 1

          try insertRecipeIngredients(
            for: newRecipeId,
            raw: raw,
            bundledIngredients: bundled.ingredients,
            into: db
          )

          existingTitleKeys.insert(titleKey)
        }

        let hydratedRecipeCount =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM recipes WHERE source = 'bundled'"
          ) ?? 0
        let hydratedAt = ISO8601DateFormatter().string(from: Date())

        try upsertBundledRecipeState(db, key: BundledRecipeStateKey.bundleMarker, value: marker)
        try upsertBundledRecipeState(
          db, key: BundledRecipeStateKey.recipeCount, value: String(hydratedRecipeCount))
        try upsertBundledRecipeState(db, key: BundledRecipeStateKey.hydratedAt, value: hydratedAt)

        #if DEBUG
          if insertedCount > 0 {
            print("[BundledDataLoader] Hydrated \(insertedCount) bundled recipes.")
          }
        #endif
      }

      try ensureRequiredDemoRecipes(
        bundledRecipes: bundled.recipes,
        bundledIngredients: bundled.ingredients,
        db: db
      )
    }
  }

}
