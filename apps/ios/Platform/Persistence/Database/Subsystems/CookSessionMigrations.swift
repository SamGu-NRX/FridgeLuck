import GRDB

/// Cook session subsystem migrations. Every migration registered here uses the `cook_`
/// identifier prefix so the shared `grdb_migrations` table attributes it to this subsystem.
/// These run after all core `vN_` migrations and after every subsystem before this one, so a
/// migration may reference core tables and tables created by earlier subsystem migrations.
enum CookSessionMigrations {
  /// Registers this subsystem's migrations in order. Each schema change adds one
  /// `migrator.registerMigration("cook_<name>")` call here; identifiers are applied once
  /// and must never be renamed or reordered after they ship.
  static func register(in migrator: inout DatabaseMigrator) {
    // LeChef §11 — one cooking session, exactly one cooking at a time.
    migrator.registerMigration("cook_session_v1") { db in
      try db.create(table: "cook_session") { t in
        t.primaryKey("id", .text)
        t.column("recipe_ref", .text)
        t.column("servings", .integer).notNull().defaults(to: 0)
        t.column("eater_ids", .text).notNull().defaults(to: "[]")
        t.column("state", .text).notNull().defaults(to: "idle")
        t.column("current_step", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
        t.column("completed_steps", .text).notNull().defaults(to: "[]")
        t.column("started_at", .text)
        t.column("ended_at", .text)
        t.column("revision", .integer).notNull().defaults(to: 1).check { $0 >= 1 }
        t.column("rating", .integer).check { $0 >= 1 && $0 <= 5 }
      }

      // Exactly one cooking session at a time (LeChef §2) — enforced at the store, never by
      // hand-edited rows.
      try db.execute(sql: """
        CREATE UNIQUE INDEX idx_cook_session_active ON cook_session(state) WHERE state = 'cooking'
        """)
    }

    // Device timers carry absolute deadlines, so a relaunch needs no re-derivation (LeChef §4.2).
    migrator.registerMigration("cook_timer_v1") { db in
      try db.create(table: "cook_timer") { t in
        t.primaryKey("id", .text)
        t.column("session_id", .text).notNull().references("cook_session", onDelete: .cascade)
        t.column("label", .text).notNull()
        t.column("deadline", .text).notNull()
        t.column("paused_at", .text)
        t.column("remaining_when_paused_seconds", .double)
        t.column("fired_at", .text)
        t.column("acknowledged_at", .text)
        t.column("total_seconds", .double)
      }
      try db.create(index: "idx_cook_timer_session", on: "cook_timer", columns: ["session_id"])
    }

    // Effects and swaps are recorded as they apply — the yolk-ink line for the remember receipt.
    migrator.registerMigration("cook_adaptation_v1") { db in
      try db.create(table: "cook_adaptation") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("session_id", .text).notNull().references("cook_session", onDelete: .cascade)
        t.column("at", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("input", .text).notNull()
        t.column("applied", .text).notNull()
        t.column("caption", .text).notNull()
      }
      try db.create(index: "idx_cook_adaptation_session", on: "cook_adaptation", columns: ["session_id"])
    }

    migrator.registerMigration("cook_substitution_v1") { db in
      try db.create(table: "cook_substitution") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("session_id", .text).references("cook_session", onDelete: .cascade)
        // Plan-level swaps reference the meal-plan subsystem's row; that table belongs to
        // another subsystem's migrations, so this is a plain column, not a foreign key.
        t.column("plan_id", .text)
        t.column("original_id", .integer)
        t.column("substitute_id", .integer)
        t.column("ratio", .double)
        t.column("note", .text).notNull().defaults(to: "")
        t.column("allergen_recheck", .text)
        t.column("source", .text).notNull().defaults(to: "user")
      }
      try db.create(index: "idx_cook_substitution_session", on: "cook_substitution", columns: ["session_id"])
    }

    // Proposal receipts: every proposal resolves at most once, even across a relaunch (LeChef §8).
    migrator.registerMigration("cook_receipt_v1") { db in
      try db.create(table: "cook_receipt") { t in
        t.primaryKey("proposal_id", .text)
        t.column("session_id", .text).notNull().references("cook_session", onDelete: .cascade)
        t.column("status", .text).notNull()
        t.column("decided_at", .text).notNull()
        t.column("decided_by", .text).notNull()
        t.column("applied", .text)
        t.column("failure", .text)
        t.column("session_revision", .integer).notNull()
      }
    }

    // The remember receipt — rating, note, and the skip, one row per session.
    migrator.registerMigration("cook_remember_v1") { db in
      try db.create(table: "cook_remember") { t in
        t.primaryKey("session_id", .text)
        t.column("rating", .integer).check { $0 >= 1 && $0 <= 5 }
        t.column("note", .text)
        t.column("saved_at", .text)
        t.column("skipped", .boolean).notNull().defaults(to: false)
      }
    }
  }
}
