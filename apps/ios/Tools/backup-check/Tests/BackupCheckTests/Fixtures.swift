import Foundation
import GRDB
import XCTest

@testable import BackupCheck

/// Shared fixtures: a file-backed database migrated to the full current
/// schema (v20) and populated with a synthetic but realistic dataset —
/// bundled catalog rows, user records, inventory, nutrition snapshots —
/// plus helpers for building mutated archives.
enum Fixtures {
  static func makeQueue(_ name: String) throws -> DatabaseQueue {
    let path = NSTemporaryDirectory() + "fl-backup-check-\(name)-\(UUID().uuidString).sqlite"
    var config = Configuration()
    config.foreignKeysEnabled = true
    return try DatabaseQueue(path: path, configuration: config)
  }

  /// Migrates to the current schema and seeds a populated dataset.
  @discardableResult
  static func populatedQueue(_ name: String) throws -> DatabaseQueue {
    let queue = try makeQueue(name)
    try DatabaseMigrations.migrate(queue, upTo: nil)
    try queue.write { db in
      try seedCatalog(db)
      try seedHealthAndProgress(db)
      try seedInventory(db)
      try seedMeals(db)
      try seedNotifications(db)
      try seedLearningSignals(db)
    }
    return queue
  }

  static func seedCatalog(_ db: Database) throws {
    // Ingredients carry fractional nutrient values on purpose: the
    // canonical hash must survive exact round trips of every column.
    let ingredients: [[Any?]] = [
      [1, "Eggs", 143.21, 12.56, 0.72, 9.51, 0.0, 0.37, 142.0, "dozen", nil, nil, nil, nil, nil, nil, nil],
      [2, "Milk", 61.44, 3.19, 4.80, 3.27, 0.0, 5.05, 43.0, "liter", nil, "Refrigerate", nil, nil, nil, nil, nil],
      [3, "Cheddar", 402.77, 24.9, 1.28, 33.14, 0.0, 0.48, 621.0, "block", nil, nil, nil, nil, nil, nil, nil],
      [4, "User-grown basil", 23.0, 3.15, 2.65, 0.64, 1.6, 0.99, 1.0, nil, nil, nil, nil, nil, nil, nil, nil],
    ]
    for row in ingredients {
      try db.execute(
        sql: """
          INSERT INTO ingredients
            (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
             typical_unit, storage_tip, pairs_with, notes, description, category_label,
             sprite_group, sprite_key)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: StatementArguments(row.map(Self.sqlValue)))
    }

    try db.execute(
      sql: """
        INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
        VALUES (1, 'Bundled Omelette', 15, 2, 'cook it', 0, 'bundled')
        """)
    try db.execute(
      sql: """
        INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
        VALUES (2, 'My Weekly Cheddar Pasta', 25, 3, 'my own instructions', 0, 'user')
        """)
    try db.execute(
      sql: """
        INSERT INTO recipe_ingredients
          (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
        VALUES (1, 1, 1, 120.5, '2 eggs')
        """)
    try db.execute(
      sql: """
        INSERT INTO recipe_ingredients
          (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
        VALUES (2, 3, 1, 60.0, 'handful')
        """)
    try db.execute(
      sql: "INSERT INTO user_corrections (vision_label, corrected_ingredient_id) VALUES ('egg?', 1)")
    try db.execute(
      sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (1, 'egg')")
    try db.execute(
      sql: "INSERT INTO ingredient_aliases (ingredient_id, alias) VALUES (2, 'whole milk')")
  }

  static func seedHealthAndProgress(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO health_profile (id, goal, daily_calories, display_name, age)
        VALUES (1, 'protein', 2200, 'Sam', 34)
        """)
    try db.execute(sql: "INSERT INTO badges (id) VALUES ('first_meal')")
    try db.execute(
      sql: "INSERT INTO streaks (date, meals_cooked) VALUES ('2026-10-09', 2)")
    try db.execute(
      sql: "INSERT INTO ingredient_favorites (ingredient_id) VALUES (1)")
    try db.execute(
      sql: """
        INSERT INTO pantry_assumptions (ingredient_id, tier) VALUES (2, 'always_on_hand')
        """)
  }

  static func seedInventory(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO ingredient_shelf_life_profiles
          (ingredient_id, fridge_days, pantry_days, freezer_days)
        VALUES (1, 21, 14, 365)
        """)
    try db.execute(
      sql: """
        INSERT INTO inventory_lots
          (id, ingredient_id, quantity_grams, remaining_grams, storage_location,
           confidence_score, source, acquired_at, expires_at, quantity_is_estimate)
        VALUES (1, 1, 600.0, 420.25, 'fridge', 0.92, 'scan', '2026-10-01 08:00:00',
                '2026-10-20 08:00:00', 1)
        """)
    try db.execute(
      sql: """
        INSERT INTO inventory_lots
          (id, ingredient_id, quantity_grams, remaining_grams, storage_location,
           confidence_score, source, acquired_at, expires_at, quantity_is_estimate)
        VALUES (2, 3, 250.0, 130.0, 'fridge', 1.0, 'manual', '2026-10-03 18:00:00', NULL, 0)
        """)
    try db.execute(
      sql: """
        INSERT INTO inventory_events
          (ingredient_id, lot_id, event_type, quantity_delta_grams, confidence_score, reason, source_ref)
        VALUES (1, 1, 'add', 600.0, 0.92, 'Scan-confirmed inventory intake', NULL)
        """)
    try db.execute(
      sql: """
        INSERT INTO inventory_events
          (ingredient_id, lot_id, event_type, quantity_delta_grams, confidence_score, reason, source_ref)
        VALUES (1, 1, 'consume', -179.75, 0.88, 'Meal logging', NULL)
        """)
    try db.execute(
      sql: """
        INSERT INTO inventory_items
          (ingredient_id, total_remaining_grams, average_confidence_score, last_updated_at)
        VALUES (1, 420.25, 0.9, '2026-10-09 12:00:00')
        """)
    try db.execute(
      sql: """
        INSERT INTO inventory_items
          (ingredient_id, total_remaining_grams, average_confidence_score, last_updated_at)
        VALUES (3, 130.0, 1.0, '2026-10-09 12:00:00')
        """)
  }

  /// Two meals. Every history row with a live recipe carries a snapshot
  /// and dense lines — the v20 completeness invariant.
  static func seedMeals(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, image_path, servings_consumed, portion_multiplier)
        VALUES (1, 1, '2026-10-08 08:30:00', 5, 'MealPhotos/8A2C-omelette.jpg', 1, 1.0)
        """)
    try db.execute(
      sql: """
        INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, image_path, servings_consumed, portion_multiplier)
        VALUES (2, 2, '2026-10-09 19:00:00', 4, NULL, 2, 0.75)
        """)
    try db.execute(
      sql: "INSERT INTO cooking_history_swaps (history_id, original_ingredient_id, substitute_ingredient_id, ratio) VALUES (2, 3, 2, 0.5)")

    try db.execute(
      sql: """
        INSERT INTO cooking_history_nutrition_snapshots
          (history_id, recipe_servings, snapshot_version, provenance)
        VALUES (1, 2, 1, 'logged_at_capture')
        """)
    try db.execute(
      sql: """
        INSERT INTO cooking_history_nutrition_snapshots
          (history_id, recipe_servings, snapshot_version, provenance)
        VALUES (2, 3, 1, 'logged_at_capture')
        """)

    // Meal 1, line 0: eggs.
    try db.execute(
      sql: """
        INSERT INTO cooking_history_nutrition_lines
          (history_id, line_index, original_ingredient_id, substitute_ingredient_id,
           swap_ratio, quantity_grams, calories, protein, carbs, fat, fiber, sugar, sodium)
        VALUES (1, 0, 1, NULL, 1.0, 120.5, 143.21, 12.56, 0.72, 9.51, 0.0, 0.37, 142.0)
        """)
    // Meal 2, line 0: cheddar swapped to milk at ratio 0.5.
    try db.execute(
      sql: """
        INSERT INTO cooking_history_nutrition_lines
          (history_id, line_index, original_ingredient_id, substitute_ingredient_id,
           swap_ratio, quantity_grams, calories, protein, carbs, fat, fiber, sugar, sodium)
        VALUES (2, 0, 3, 2, 0.5, 60.0, 61.44, 3.19, 4.80, 3.27, 0.0, 5.05, 43.0)
        """)
  }

  static func seedNotifications(_ db: Database) throws {
    try db.execute(
      sql: "INSERT INTO notification_rules (kind, enabled, hour, minute) VALUES ('use_soon', 1, 8, 30)")
    try db.execute(
      sql: """
        INSERT INTO notification_opportunities
          (id, kind, title, body, scheduled_at, payload_json, source, status)
        VALUES ('local-use-soon-2026-10-11-1', 'use_soon_digest', 'Use soon', 'eggs',
                '2026-10-11 08:30:00', '{}', 'local', 'scheduled')
        """)
  }

  static func seedLearningSignals(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO confidence_signal_events
          (signal_key, context_key, raw_score, outcome_reward, note)
        VALUES ('scan-egg', 'fridge', 0.87, 1.0, NULL)
        """)
    try db.execute(
      sql: "INSERT INTO trust_vector_state (signal_key, alpha, beta) VALUES ('scan-egg', 4.5, 2.5)")
    try db.execute(
      sql: """
        INSERT INTO usda_catalog_state (key, value) VALUES ('usda_hydrated_at', '2026-10-01')
        """)
    try db.execute(
      sql: """
        INSERT INTO bundled_recipe_state (key, value) VALUES ('recipes_hydrated_at', '2026-10-01')
        """)
  }

  // Values arrive as Swift types so tests can express NULL plainly.
  static func sqlValue(_ value: Any?) -> DatabaseValueConvertible? {
    switch value {
    case .some(let v as Int64): return v
    case .some(let v as Int): return Int64(v)
    case .some(let v as Double): return v
    case .some(let v as String): return v
    case .some(let v as Bool): return v
    case nil: return nil
    default: return String(describing: value!)
    }
  }

  // MARK: Archive mutation helpers

  /// Recomputes every manifest hash from the archive's own rows, as an
  /// exporter would after producing the rows. Tests mutate rows and then
  /// re-sign so the structural hash gate passes and the SEMANTIC
  /// validators are what reject the payload.
  static func resign(_ archive: inout BackupArchive) {
    for index in archive.tables.indices {
      let manifest = archive.tables[index]
      let rows = (try? BackupArchiveCodec.parseRows(
        rawRows: archive.rows[manifest.name] ?? [], columns: manifest.columns)) ?? []
      let spec = BackupSchemaCatalog.spec(named: manifest.name)
      archive.tables[index].rowCount = (archive.rows[manifest.name] ?? []).count
      archive.tables[index].rowsSHA256 = BackupArchiveCodec.canonicalHash(
        table: manifest.name, columns: manifest.columns,
        primaryKey: spec?.primaryKey ?? [], rows: rows)
    }
  }

  /// Encodes an archive and returns its bytes.
  static func encode(_ archive: BackupArchive) throws -> Data {
    try BackupArchiveCodec.encode(archive)
  }

  /// An engine wired to a temporary staging root.
  static func engine(
    _ queue: DatabaseQueue, documentsDirectory: URL? = nil,
    stagingRoot: URL? = nil
  ) -> BackupRestoreEngine {
    BackupRestoreEngine(
      writer: queue, databasePath: queue.path, documentsDirectory: documentsDirectory,
      stagingRoot: stagingRoot ?? URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fl-safety-\(UUID().uuidString)"))
  }

  /// A valid archive exported from a populated database.
  static func makeArchive(
    from queue: DatabaseQueue, includesPhotos: Bool = false
  ) async throws -> Data {
    let engine = engine(queue)
    return try await engine.exportArchive(includesPhotos: includesPhotos)
  }

  /// Reads one table's decoded rows from an archive.
  static func rows(_ archive: BackupArchive, _ table: String) -> [[String?]] {
    archive.rows[table] ?? []
  }
}
