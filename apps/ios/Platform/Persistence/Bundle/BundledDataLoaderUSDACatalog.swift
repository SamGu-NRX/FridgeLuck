import Foundation
import GRDB

extension BundledDataLoader {
  /// Reads the shipped catalog as the refresh's current-catalog input, using
  /// the same column contract as the import above (display metadata COALESCEd
  /// to ''). Deliberately distinct from the pinned catalog exports: pins are
  /// adoption evidence for what past releases wrote and never substitute for
  /// what this build ships, so a corrected catalog cannot be replaced by the
  /// pinned old export.
  static func currentCatalogIngredients(from url: URL) throws -> [LegacyCatalogIngredient] {
    var readConfig = Configuration()
    readConfig.readonly = true
    let sourceDB = try DatabaseQueue(path: url.path, configuration: readConfig)
    return try sourceDB.read { src in
      try Row.fetchAll(
        src,
        sql: """
          SELECT
            id,
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
      ).map { row -> LegacyCatalogIngredient in
        let fdcId: Int64 = row["id"]
        let name: String = row["name"]
        let calories: Double = row["calories"]
        let protein: Double = row["protein"]
        let carbs: Double = row["carbs"]
        let fat: Double = row["fat"]
        let fiber: Double = row["fiber"]
        let sugar: Double = row["sugar"]
        let sodium: Double = row["sodium"]
        let notes: String? = row["notes"]
        let description: String = row["description"]
        let categoryLabel: String = row["category_label"]
        let spriteGroup: String = row["sprite_group"]
        let spriteKey: String = row["sprite_key"]
        return LegacyCatalogIngredient(
          fdcId: fdcId, name: name, calories: calories, protein: protein, carbs: carbs,
          fat: fat, fiber: fiber, sugar: sugar, sodium: sodium, notes: notes,
          description: description, categoryLabel: categoryLabel, spriteGroup: spriteGroup,
          spriteKey: spriteKey)
      }
    }
  }

  /// Import curated USDA ingredient rows from bundled SQLite resource if present.
  /// Uses INSERT OR IGNORE to avoid clobbering the base curated ingredient set.
  static func loadUSDACatalogIngredientsIfAvailable(into db: Database) throws {
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
              id,
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
        return try Row.fetchAll(
          src,
          sql: """
            SELECT
              id,
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
      // Stamp provenance only on rows this call actually inserted: an ignored
      // insert means an existing row (data.json content or user-created) that
      // must keep its own provenance. The source catalog's ingredient id is the
      // USDA FDC id, so the key restores the identity the import used to drop.
      if db.changesCount == 1, let fdcId: Int64 = row["id"] {
        let insertedId = db.lastInsertedRowID
        if let written = try Row.fetchOne(
          db, sql: "SELECT * FROM ingredients WHERE id = ?", arguments: [insertedId])
        {
          try db.execute(
            sql: "UPDATE ingredients SET ownership_key = ?, bundle_content_hash = ? WHERE id = ?",
            arguments: [
              BundleOwnership.usdaIngredientKey(fdcId: fdcId),
              CanonicalHash.hash(
                fields: BundleRowProjection.rowFields(written, projection: .catalogIngredient)),
              insertedId,
            ])
        }
      }
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

  static func catalogMarker(for url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let fileSize = values?.fileSize ?? 0
    let modifiedAt = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    return "size=\(fileSize);mtime=\(modifiedAt)"
  }

  static func upsertUSDACatalogState(_ db: Database, key: String, value: String) throws {
    try db.execute(
      sql: """
        INSERT INTO usda_catalog_state (key, value, updated_at)
        VALUES (?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = CURRENT_TIMESTAMP
        """,
      arguments: [key, value]
    )
  }
}
