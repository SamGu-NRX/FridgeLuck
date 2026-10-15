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
  }
}
