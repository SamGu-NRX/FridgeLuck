import GRDB

/// Taste subsystem migrations. Every migration registered here uses the `taste_` identifier
/// prefix so the shared `grdb_migrations` table attributes it to this subsystem. These run
/// after all core `vN_` migrations and after every subsystem before this one, so a migration
/// may reference core tables and tables created by earlier subsystem migrations.
///
/// Tables (docs/spec/taste/SPEC.md §5 — everything stays on-device):
/// - `taste_events` — one row per observed taste-relevant action, idempotent by stable
///   event id (docs/spec/taste/contracts/taste-event.schema.json).
/// - `taste_exposures` — one row per recommendation-surface render: the shown slate in
///   order plus the full feasible choice set (docs/spec/taste/contracts/exposure.schema.json).
/// - `taste_statements` — profile-statement state across restriction/stated/pinned/inferred
///   layers (docs/spec/taste/contracts/profile-statement.schema.json).
///
/// burst5-fridgeluck-taste-profile reads exposures and statements from here and must not
/// need to add tables of its own.
enum TasteMigrations {
  /// Registers this subsystem's migrations in order. Each schema change adds one
  /// `migrator.registerMigration("taste_<name>")` call here; identifiers are applied once
  /// and must never be renamed or reordered after they ship.
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("taste_events") { db in
      try db.create(table: "taste_events") { t in
        // Stable event id (UUID v4, lowercase). Primary key: replaying an id is a no-op.
        t.column("id", .text).notNull().primaryKey()
        t.column("at", .datetime).notNull()
        t.column("kind", .text).notNull()
        t.column("eater", .text)
        t.column("recipe_source", .text)
        t.column("recipe_id", .text)
        t.column("recipe_revision", .integer)
        t.column("ingredient_id", .integer)
        t.column("surface", .text).notNull()
        // Internal cook-transaction linkage, kept outside the contract payload: the cook
        // event stores the id of the cook it belongs to; rated/substituted/servings events
        // store the cook id they merge into (SPEC §2.3 transaction window).
        t.column("cook_event_id", .text)
        // Kind-specific payload, canonically serialized per docs/spec/taste/contracts/.
        t.column("payload", .text).notNull()
      }

      try db.create(index: "idx_taste_events_at", on: "taste_events", columns: ["at"])
      try db.create(index: "idx_taste_events_kind", on: "taste_events", columns: ["kind"])
      try db.create(
        index: "idx_taste_events_recipe",
        on: "taste_events",
        columns: ["recipe_source", "recipe_id"]
      )
      try db.create(
        index: "idx_taste_events_ingredient",
        on: "taste_events",
        columns: ["ingredient_id"]
      )
      try db.create(
        index: "idx_taste_events_cook_event",
        on: "taste_events",
        columns: ["cook_event_id"]
      )
    }

    migrator.registerMigration("taste_exposures") { db in
      try db.create(table: "taste_exposures") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("at", .datetime).notNull()
        t.column("surface", .text).notNull()
        t.column("eater", .text)
        t.column("session_id", .text)
        // Ordered [{recipe, position}] JSON — what was actually rendered.
        t.column("slate", .text).notNull()
        // [recipe ref] JSON — the full feasible choice set the slate was drawn from.
        t.column("feasible", .text).notNull()
        // {kitchenIngredientCount, householdSize, mealContext} JSON.
        t.column("context", .text).notNull()
      }

      try db.create(index: "idx_taste_exposures_at", on: "taste_exposures", columns: ["at"])
    }

    migrator.registerMigration("taste_statements") { db in
      try db.create(table: "taste_statements") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("layer", .text).notNull()
        t.column("feature_kind", .text)
        t.column("feature_key", .text)
        t.column("template_id", .text).notNull()
        t.column("numerator", .integer)
        t.column("denominator", .integer)
        t.column("state", .text).notNull()
        t.column("muted_until", .datetime)
        t.column("pinned_value", .double)
        t.column("last_evidence_at", .datetime)
        t.column("created_at", .datetime).notNull()
        t.column("updated_at", .datetime).notNull()
        t.column("text", .text).notNull()
      }

      try db.create(
        index: "idx_taste_statements_feature",
        on: "taste_statements",
        columns: ["feature_key"]
      )
      try db.create(
        index: "idx_taste_statements_layer",
        on: "taste_statements",
        columns: ["layer"]
      )
    }
  }
}
