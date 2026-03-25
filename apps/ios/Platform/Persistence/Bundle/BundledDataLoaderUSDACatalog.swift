import Foundation
import GRDB

extension BundledDataLoader {
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
