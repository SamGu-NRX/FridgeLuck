import GRDB

// MARK: - Schema migrations
// Engineering plan §Persistence: versioned, additive migrations registered in
// one place. Part 1 establishes the registry and the baseline; each later part
// appends its own migrations here (new migrations only — never edits history).

public enum FLSchemaMigrations {
    /// The current schema version. Bump by appending a migration; never edit
    /// an applied one.
    public static let currentVersion: Int64 = 1

    /// The full migrator. Call once per database open.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1 — baseline: establish versioned schema ownership. Part-specific
        // tables (pantry truth, recipes, cooks, preference events, assistant
        // receipts) are appended by their owning parts as later migrations.
        migrator.registerMigration("v1-baseline") { db in
            try db.execute(sql: """
                CREATE TABLE fl_schema_baseline (
                    id INTEGER PRIMARY KEY,
                    establishedAt TEXT NOT NULL
                )
                """)
        }

        return migrator
    }
}
