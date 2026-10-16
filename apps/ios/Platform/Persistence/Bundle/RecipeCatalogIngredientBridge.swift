import Foundation
import GRDB

/// Read-only view of the bundled USDA catalog (`usda_ingredient_catalog.sqlite`) as an
/// identity-evidence source: the FDC id a canonical key carries resolves to the source
/// row's exact name and aliases. Nothing here guesses — a source miss leaves the key
/// unresolved, and the key stays "not in your kitchen" for matching.
struct USDAIdentitySource: Sendable {
  /// FDC id -> exact source name (the same string the loader copies into `ingredients.name`).
  let nameByFDC: [Int64: String]
  /// FDC id -> lowercased source aliases.
  let aliasesByFDC: [Int64: [String]]

  /// Loads the bundled catalog from the app bundle. Returns nil when the resource is
  /// absent (some test and tooling environments), so hydration still resolves legacy ids.
  static func bundled() -> USDAIdentitySource? {
    guard
      let url = Bundle.main.url(
        forResource: "usda_ingredient_catalog", withExtension: "sqlite")
    else { return nil }
    return try? USDAIdentitySource(sqlitePath: url.path)
  }

  /// An explicit source with no evidence rows; useful when a caller wants hydration to
  /// resolve only through legacy ids.
  static func empty() -> USDAIdentitySource {
    USDAIdentitySource(nameByFDC: [:], aliasesByFDC: [:])
  }

  init(nameByFDC: [Int64: String], aliasesByFDC: [Int64: [String]]) {
    self.nameByFDC = nameByFDC
    self.aliasesByFDC = aliasesByFDC
  }

  /// Opens the bundled catalog read-only and reads it fully into memory. The catalog is
  /// small (hundreds of rows), and hydration is a one-time transaction, so eager loading
  /// keeps the write transaction free of long-lived second connections.
  init(sqlitePath: String) throws {
    var config = Configuration()
    config.readonly = true
    let source = try DatabaseQueue(path: sqlitePath, configuration: config)

    var names: [Int64: String] = [:]
    var aliases: [Int64: [String]] = [:]
    try source.read { db in
      let nameRows = try Row.fetchAll(
        db,
        sql: """
          SELECT c.fdc_id AS fdc_id, i.name AS name
          FROM ingredient_catalog c
          JOIN ingredients i ON i.id = c.fdc_id
          """)
      for row in nameRows {
        guard let fdcId: Int64 = row["fdc_id"], let name: String = row["name"] else { continue }
        names[fdcId] = name
      }

      let aliasRows = try Row.fetchAll(
        db,
        sql: "SELECT ingredient_id, alias FROM ingredient_aliases WHERE alias <> ''")
      for row in aliasRows {
        guard let fdcId: Int64 = row["ingredient_id"], let alias: String = row["alias"]
        else { continue }
        aliases[fdcId, default: []].append(alias.lowercased())
      }
    }

    self.init(nameByFDC: names, aliasesByFDC: aliases)
  }
}

/// Builds the `recipes_catalog_ingredient_bridge` table during catalog hydration.
///
/// Each canonical key maps to the app ingredient ids it stands for, resolved exactly:
/// 1. `legacy_id`, when the vocabulary row carries one and the app ingredient exists.
/// 2. Otherwise `fdc_id` against the bundled USDA source row's exact name and aliases.
///
/// A key with no rows is "not in your kitchen" — the recommendation engine treats its
/// lines as unmatched and never resolves them by name similarity at query time.
///
/// The rebuild runs inside the hydration transaction immediately after the vocabulary is
/// upserted, so the bridge can never drift from the vocabulary it indexes.
enum RecipeCatalogIngredientBridge {
  struct Coverage: Equatable, Sendable {
    let totalKeys: Int
    let resolvedKeys: Int
    let resolvedByLegacyID: Int
    let resolvedByFDCID: Int
  }

  /// Rebuilds the bridge from the current catalog vocabulary, the app ingredient space,
  /// and the bundled USDA source. Call inside the hydration write transaction.
  @discardableResult
  static func rebuild(db: Database) throws -> Coverage {
    try rebuild(db: db, usda: USDAIdentitySource.bundled())
  }

  /// Rebuild with an explicit evidence source (tests, tooling).
  static func rebuild(db: Database, usda: USDAIdentitySource?) throws -> Coverage {
    try db.execute(sql: "DELETE FROM recipes_catalog_ingredient_bridge")

    let keyRows = try Row.fetchAll(
      db,
      sql: "SELECT key, fdc_id, legacy_id FROM recipes_catalog_ingredients")

    var appIngredientIDs = Set<Int64>()
    var appIDByName: [String: Int64] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT id, name FROM ingredients") {
      guard let id: Int64 = row["id"], let name: String = row["name"] else { continue }
      appIngredientIDs.insert(id)
      appIDByName[name] = id
    }

    var appIDsByAlias: [String: Set<Int64>] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT ingredient_id, alias FROM ingredient_aliases") {
      guard let id: Int64 = row["ingredient_id"], let alias: String = row["alias"] else {
        continue
      }
      let key = alias.lowercased()
      guard !key.isEmpty else { continue }
      appIDsByAlias[key, default: []].insert(id)
    }

    var resolvedByLegacyID = 0
    var resolvedByFDCID = 0
    for row in keyRows {
      guard let key: String = row["key"] else { continue }
      let legacyID: Int64? = row["legacy_id"]
      let fdcID: Int64? = row["fdc_id"]

      var ids = Set<Int64>()
      var resolvedBy = ""
      // Strict precedence: legacy_id first; fdc_id only when the legacy link yields no
      // app ingredient (the shipped bundle carries no legacy links at all).
      if let legacyID, appIngredientIDs.contains(legacyID) {
        ids.insert(legacyID)
        resolvedBy = "legacy_id"
        resolvedByLegacyID += 1
      } else if let fdcID, let usda {
        if let sourceName = usda.nameByFDC[fdcID], let appID = appIDByName[sourceName] {
          ids.insert(appID)
        }
        for alias in usda.aliasesByFDC[fdcID] ?? [] {
          ids.formUnion(appIDsByAlias[alias] ?? [])
        }
        if !ids.isEmpty {
          resolvedBy = "fdc_id"
          resolvedByFDCID += 1
        }
      }

      guard !ids.isEmpty else { continue }
      for id in ids.sorted() {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO recipes_catalog_ingredient_bridge
              (ingredient_key, ingredient_id, resolved_by)
            VALUES (?, ?, ?)
            """,
          arguments: [key, id, resolvedBy])
      }
    }

    return Coverage(
      totalKeys: keyRows.count,
      resolvedKeys: resolvedByLegacyID + resolvedByFDCID,
      resolvedByLegacyID: resolvedByLegacyID,
      resolvedByFDCID: resolvedByFDCID)
  }
}
