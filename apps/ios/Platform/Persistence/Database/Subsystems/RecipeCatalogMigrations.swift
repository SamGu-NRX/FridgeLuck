import GRDB

/// Recipe catalog subsystem migrations. Every migration registered here uses the `recipes_`
/// identifier prefix so the shared `grdb_migrations` table attributes it to this subsystem.
/// These run after all core `vN_` migrations and after every subsystem before this one, so a
/// migration may reference core tables and tables created by earlier subsystem migrations.
enum RecipeCatalogMigrations {
  /// Registers this subsystem's migrations in order. Each schema change adds one
  /// `migrator.registerMigration("recipes_<name>")` call here; identifiers are applied once
  /// and must never be renamed or reordered after they ship.
  static func register(in migrator: inout DatabaseMigrator) {

    migrator.registerMigration("recipes_catalog_v1") { db in
      // The canonical ingredient vocabulary: one row per key, with fdc_id and legacy_id as
      // nullable evidence links. Nothing joins on integer ids.
      try db.create(table: "recipes_catalog_ingredients") { t in
        t.primaryKey("key", .text)
        t.column("fdc_id", .integer)
        t.column("legacy_id", .integer)
        t.column("display_name", .text).notNull()
        t.column("category", .text).notNull()
        // Per-100 g reference values as JSON, or NULL when quantity evidence is absent and
        // nutrition must not be synthesized.
        t.column("per_100g", .text)
        t.column("aliases", .text).notNull().defaults(to: "[]")
      }

      // The catalog itself: one row per stable catalog_id (rcp-NNNNNN), carrying the
      // currently installed revision's summary. Structured content lives in the child
      // tables below; legacy recipes.id and cooking_history are never rewritten.
      try db.create(table: "recipes_catalog") { t in
        t.primaryKey("catalog_id", .text)
        t.column("revision", .integer).notNull()
        t.column("title", .text).notNull()
        t.column("cuisine", .text).notNull()
        t.column("meal_slots", .text).notNull().defaults(to: "[]")
        t.column("collections", .text).notNull().defaults(to: "[]")
        t.column("minutes", .integer).notNull()
        t.column("servings", .integer).notNull()
        t.column("equipment", .text).notNull().defaults(to: "[]")
        t.column("claims", .text).notNull()
        t.column("nutrition", .text)
        t.column("rights_status", .text).notNull()
        t.column("rights_evidence", .text).notNull()
        t.column("keywords", .text).notNull().defaults(to: "[]")
        // Set when this row succeeds a legacy data.json recipe, so cooking history that
        // points at the legacy integer id can resolve to structured content.
        t.column("legacy_recipe_id", .integer).references("recipes", onDelete: .setNull)
        // User-edited rows are never overwritten by a bundle re-apply.
        t.column("is_user_edited", .boolean).notNull().defaults(to: false)
        t.column("source_bundle", .text).notNull().defaults(to: "")
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }

      // Per-serving nutrition snapshots keyed by revision. Rows are inserted once and never
      // updated, so meals logged against an older revision keep the values they were
      // logged with.
      try db.create(table: "recipes_catalog_nutrition") { t in
        t.column("catalog_id", .text).notNull().references("recipes_catalog", onDelete: .cascade)
        t.column("revision", .integer).notNull()
        t.column("nutrition", .text).notNull()
        t.primaryKey(["catalog_id", "revision"])
      }

      // Structured ingredient lines with quantity evidence, ordered by position.
      try db.create(table: "recipes_catalog_lines") { t in
        t.column("catalog_id", .text).notNull().references("recipes_catalog", onDelete: .cascade)
        t.column("position", .integer).notNull()
        t.column("ingredient_key", .text)
          .notNull()
          .references("recipes_catalog_ingredients", onDelete: .restrict)
        // grams | count | household | unknown
        t.column("quantity_kind", .text).notNull()
        t.column("quantity_grams", .double)
        t.column("quantity_amount", .double)
        t.column("quantity_unit", .text)
        t.column("quantity_note", .text)
        t.column("is_required", .boolean).notNull().defaults(to: true)
        t.column("assumed_staple", .boolean).notNull().defaults(to: false)
        t.column("note", .text)
        t.primaryKey(["catalog_id", "position"])
      }

      // Structured steps with timers and thermometer checks, ordered by position. A
      // thermometer check carries all three columns or none (fail-closed integrity).
      try db.create(table: "recipes_catalog_steps") { t in
        t.column("catalog_id", .text).notNull().references("recipes_catalog", onDelete: .cascade)
        t.column("position", .integer).notNull()
        t.column("text", .text).notNull()
        t.column("uses", .text).notNull().defaults(to: "[]")
        t.column("timer_seconds", .integer)
        t.column("thermometer_endpoint_c", .double)
        t.column("thermometer_food", .text)
        t.column("thermometer_source", .text)
        t.primaryKey(["catalog_id", "position"])
        t.check(
          sql: """
            (thermometer_endpoint_c IS NULL AND thermometer_food IS NULL
               AND thermometer_source IS NULL)
            OR (thermometer_endpoint_c IS NOT NULL AND thermometer_food IS NOT NULL
               AND thermometer_source IS NOT NULL)
            """
        )
      }

      try db.create(
        index: "idx_recipes_catalog_lines_key",
        on: "recipes_catalog_lines",
        columns: ["ingredient_key"]
      )
      try db.create(
        index: "idx_recipes_catalog_legacy",
        on: "recipes_catalog",
        columns: ["legacy_recipe_id"]
      )
    }

    migrator.registerMigration("recipes_catalog_ingredient_bridge_v1") { db in
      // Identity bridge: which app ingredients each canonical key stands for, resolved
      // exactly during hydration — legacy_id first, then fdc_id against the bundled USDA
      // source row's name and aliases. A key with no rows here is "not in your kitchen"
      // for matching and is never resolved by name guessing at query time. Registered
      // after recipes_catalog_v1 so the referenced vocabulary table exists first.
      try db.create(table: "recipes_catalog_ingredient_bridge") { t in
        t.column("ingredient_key", .text)
          .notNull()
          .references("recipes_catalog_ingredients", onDelete: .cascade)
        t.column("ingredient_id", .integer)
          .notNull()
          .references("ingredients", onDelete: .cascade)
        // Which evidence link resolved the key: "legacy_id" or "fdc_id".
        t.column("resolved_by", .text).notNull()
        t.primaryKey(["ingredient_key", "ingredient_id"])
      }
      try db.create(
        index: "idx_recipes_catalog_bridge_ingredient",
        on: "recipes_catalog_ingredient_bridge",
        columns: ["ingredient_id"]
      )
    }

    migrator.registerMigration("recipes_catalog_ingredient_classes_v1") { db in
      // Per-ingredient composition classes (bundle v2 safety contract): the
      // screen behind every recipe-offering surface reads these instead of the
      // hydration-time identity bridge, so a line whose key never resolved to
      // app ingredient ids still carries its allergen and diet classes.
      try db.alter(table: "recipes_catalog_ingredients") { t in
        t.add(column: "classes", .text).notNull().defaults(to: "[]")
      }

      // Hydrate the classes of rows the previous bundle applies already wrote:
      // read the shipped bundle's per-ingredient classes and backfill in place.
      // Fresh installs hydrate through the bundle apply right after launch; this
      // migration covers installs whose vocabulary predates the classes column.
      // Best-effort: a missing or unreadable bundle leaves '[]', and the next
      // apply fills every row — unknown classes fail closed either way.
      guard
        let url = Bundle.main.url(
          forResource: "recipes-v2", withExtension: "json", subdirectory: "RecipeCatalog")
          ?? Bundle.main.url(forResource: "recipes-v2", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let bundle = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let ingredients = bundle["ingredients"] as? [[String: Any]]
      else { return }
      for entry in ingredients {
        guard let key = entry["key"] as? String,
          let classes = entry["classes"] as? [String],
          let payload = try? JSONSerialization.data(withJSONObject: classes, options: [.sortedKeys])
        else { continue }
        try db.execute(
          sql: "UPDATE recipes_catalog_ingredients SET classes = ? WHERE key = ?",
          arguments: [String(decoding: payload, as: UTF8.self), key])
      }
    }

    migrator.registerMigration("recipes_cooking_catalog_refs_v1") { db in
      // Which catalog recipe and revision a cooked meal was logged against: one row per
      // cooking_history entry, written in the same transaction as the history row itself.
      // The meal's nutrition reports through this link — recipes_catalog_nutrition at
      // THIS revision, whose rows are inserted once and never rewritten — so a later
      // revision bump can never silently rewrite what an older log says the meal was.
      try db.create(table: "recipes_cooking_catalog_refs") { t in
        t.column("history_id", .integer)
          .notNull()
          .references("cooking_history", onDelete: .cascade)
        t.column("catalog_id", .text)
          .notNull()
          .references("recipes_catalog", onDelete: .restrict)
        t.column("revision", .integer).notNull()
        t.primaryKey(["history_id"])
        t.check(sql: "revision >= 1")
      }

      try db.create(
        index: "idx_recipes_cooking_catalog_refs_catalog",
        on: "recipes_cooking_catalog_refs",
        columns: ["catalog_id", "revision"]
      )
    }
  }
}
