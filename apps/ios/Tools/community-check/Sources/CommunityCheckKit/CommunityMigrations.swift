import GRDB

/// Community subsystem migrations. Every migration registered here uses the `community_`
/// identifier prefix so the shared `grdb_migrations` table attributes it to this subsystem.
/// These run after all core `vN_` migrations and after every subsystem before this one, so a
/// migration may reference core tables and tables created by earlier subsystem migrations.
///
/// Table shapes follow community SPEC 8.1. User-recipe *content* stays owned by the cookbook
/// (PR #71); these tables hold community state, frozen revision payloads (the publish payload
/// form), the outbox, and last-known caches for offline rendering.
///
/// One deliberate deviation from SPEC 8.1, pending the personal-cookbook store landing:
/// `community_user_recipes.recipe_id` is this table's own autoincremented primary key rather
/// than a foreign key to `recipes.id`. The cookbook store does not exist on this branch yet,
/// so there is no `recipes` row to mirror; when PR #71's store lands, `recipe_id` becomes the
/// cookbook `recipes.id` (the community layer then holds only state the cookbook does not
/// know about, per SPEC 2.4).
enum CommunityMigrations {
  /// Registers this subsystem's migrations in order. Each schema change adds one
  /// `migrator.registerMigration("community_<name>")` call here; identifiers are applied
  /// once and must never be renamed or reordered after they ship.
  static func register(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("community_user_recipes_v1") { db in
      try db.create(table: "community_user_recipes") { t in
        t.autoIncrementedPrimaryKey("recipe_id")
        // Client-minted community identifier ("ur_…") used in the contract's RecipeRef; the
        // server-assigned recipe id lands in server_recipe_id once the server knows it.
        t.column("community_recipe_id", .text).notNull().unique()
        t.column("server_recipe_id", .text)
        t.column("publication_id", .text)
        // snake_case per SPEC 8.1: private / author_only / published / in_review / withdrawn
        t.column("publication_state", .text).notNull().defaults(to: "private")
        t.column("published_revision", .integer)
        // Import/generation provenance; only 'user-created' recipes are publishable in burst5.
        t.column("provenance", .text).notNull().defaults(to: "user-created")
        // Display-name attribution carried when duplicating someone else's published recipe.
        t.column("duplicated_from", .text)
        // The §2.3 step-2 rights declaration, persisted so the outbox drain can rebuild the
        // exact publish payload offline.
        t.column("own_rights", .boolean).notNull().defaults(to: false)
        t.column("no_personal_data", .boolean).notNull().defaults(to: false)
        // Non-blocking screening note pending confirmation (author-visible "flagged").
        t.column("flagged_tag", .text)
        t.column("last_synced_at", .text)
        t.column("updated_at", .text).notNull()
      }
    }

    migrator.registerMigration("community_user_recipe_revisions_v1") { db in
      try db.create(table: "community_user_recipe_revisions") { t in
        t.column("recipe_id", .integer)
          .notNull()
          .references("community_user_recipes", onDelete: .cascade)
        // Numbered from 1, +1 per content change, never reused (SPEC 2.2).
        t.column("revision", .integer).notNull()
        // The exact contract JSON (recipe-content form) frozen at publish-or-edit time.
        t.column("payload_json", .text).notNull()
        t.column("frozen_at", .text).notNull()
        t.primaryKey(["recipe_id", "revision"])
      }
    }

    migrator.registerMigration("community_outbox_v1") { db in
      try db.create(table: "community_outbox") { t in
        t.autoIncrementedPrimaryKey("id")
        // publish / withdraw / share_cook / table_event / report (SPEC 8.3)
        t.column("operation", .text).notNull()
        // Client-generated UUID; identical operationId replays the first server response.
        t.column("operation_id", .text).notNull().unique()
        // Recipe linkage so a withdraw can supersede queued publishes for the same recipe.
        t.column("recipe_id", .integer)
        t.column("payload_json", .text).notNull()
        // queued / sending / succeeded / cancelled / conflict / failed
        t.column("state", .text).notNull().defaults(to: "queued")
        t.column("created_at", .text).notNull()
        t.column("attempts", .integer).notNull().defaults(to: 0)
        // Exponential backoff 1 min → … → 1 h cap (SPEC 8.3); nil means due now.
        t.column("next_retry_at", .text)
        t.column("last_error", .text)
      }
    }

    migrator.registerMigration("community_cache_v1") { db in
      try db.create(table: "community_feed_cache") { t in
        t.column("id", .integer).primaryKey(onConflict: .replace)
        t.column("fetched_at", .text).notNull()
        t.column("payload_json", .text).notNull()
      }
      try db.create(table: "community_table_cache") { t in
        t.column("table_id", .text).primaryKey(onConflict: .replace)
        t.column("fetched_at", .text).notNull()
        t.column("payload_json", .text).notNull()
      }
    }
  }
}
