import GRDB

// MARK: - Schema migrations
// Engineering plan §Persistence: versioned, additive migrations registered in
// one place. Part 1 establishes the registry and the baseline; each later part
// appends its own migrations here (new migrations only — never edits history).

public enum FLSchemaMigrations {
    /// The current schema version. Bump by appending a migration; never edit
    /// an applied one.
    public static let currentVersion: Int64 = 2

    /// The full migrator. Call once per database open.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1 — baseline: establish versioned schema ownership. Part-specific
        // tables (pantry truth, recipes, assistant receipts) are appended by
        // their owning parts as later migrations.
        migrator.registerMigration("v1-baseline") { db in
            try db.execute(sql: """
                CREATE TABLE fl_schema_baseline (
                    id INTEGER PRIMARY KEY,
                    establishedAt TEXT NOT NULL
                )
                """)
        }

        // v2 — the finished-cook pair (review round 2, item 1). A completed
        // cook and its preference event persist together or not at all; the
        // atomicity lives in the single-transaction write, and these tables
        // are its two halves. Additive only. CHECK constraints mirror the
        // domain's scalar range rules as storage-level backstops; the enum
        // and timestamp columns stay unconstrained here — the domain owns
        // those grammars, and this migration must never need editing when a
        // domain enum gains a case.
        migrator.registerMigration("v2-cooks-preference-events") { db in
            try db.execute(sql: """
                CREATE TABLE fl_cooks (
                    id TEXT PRIMARY KEY NOT NULL,
                    recipe_source TEXT NOT NULL,
                    recipe_source_id TEXT NOT NULL,
                    recipe_revision INTEGER NOT NULL CHECK (recipe_revision >= 1),
                    servings INTEGER NOT NULL CHECK (servings >= 1),
                    substitutions TEXT NOT NULL,
                    rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
                    note TEXT,
                    started_at TEXT,
                    completed_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE fl_preference_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    timestamp TEXT NOT NULL,
                    recipe_source TEXT NOT NULL,
                    recipe_source_id TEXT NOT NULL,
                    recipe_revision INTEGER NOT NULL CHECK (recipe_revision >= 1),
                    exposure_id TEXT,
                    source TEXT NOT NULL,
                    supersedes_event_id TEXT,
                    supersedes_mode TEXT,
                    rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
                    would_repeat INTEGER CHECK (would_repeat IS NULL OR would_repeat IN (0, 1)),
                    note TEXT,
                    ingredient_name TEXT,
                    from_ingredient TEXT,
                    to_ingredient TEXT,
                    sentence_id TEXT,
                    verdict TEXT,
                    CHECK ((supersedes_event_id IS NULL) = (supersedes_mode IS NULL))
                )
                """)
            // The taste engine and feasibility read records by recipe.
            try db.execute(sql: "CREATE INDEX fl_cooks_recipe_revision ON fl_cooks (recipe_source, recipe_source_id, recipe_revision)")
            try db.execute(sql: "CREATE INDEX fl_preference_events_recipe_revision ON fl_preference_events (recipe_source, recipe_source_id, recipe_revision)")
        }

        return migrator
    }
}
