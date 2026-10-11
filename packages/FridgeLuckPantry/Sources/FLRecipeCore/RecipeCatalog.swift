import Foundation
import FLDomain
import FLInventoryCore
import FLPersistence
import GRDB

// MARK: - The recipe catalog
// Structured RecipeRevisions in GRDB, household-scoped, with versioned
// namespaced migrations ("fl-recipe-v1") in the engineering-plan style.
// Revisions are addressed by their stable RecipeKey (source, sourceRecipeID,
// revision) — row IDs are never part of the contract. All revisions are
// kept: "latest revision" is a query, not an update, so history is never
// erased. Quarantined revisions (unknown rights, SPEC 3.5) store fine —
// rights discipline filters them at candidate selection, not at storage.

public struct FLRecipeCatalog: Sendable {
    private let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrations().migrate(dbWriter)
    }

    public init(db: AppDatabase) throws {
        try self.init(dbWriter: db.dbWriter)
    }

    /// This target's own migrations, namespaced `fl-recipe-` like the ledger's.
    public static func migrations() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("fl-recipe-v1") { db in
            try db.execute(sql: """
                CREATE TABLE fl_recipe_revision (
                    household_id TEXT NOT NULL,
                    source TEXT NOT NULL,
                    source_recipe_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    recipe_json TEXT NOT NULL,
                    title TEXT NOT NULL,
                    saved_at TEXT NOT NULL,
                    PRIMARY KEY (household_id, source, source_recipe_id, revision)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX fl_recipe_revision_title
                    ON fl_recipe_revision (household_id, title)
                """)
        }
        return migrator
    }

    // MARK: Writing

    /// Store one revision for a household. Re-saving the same key replaces
    /// the stored payload (the key identifies the revision; the newest save
    /// of a key is the household's copy). One row per (household, key).
    public func save(_ revision: RecipeRevision, householdID: FLHouseholdID) throws {
        let json = String(decoding: try FLJSON.canonicalData(revision), as: UTF8.self)
        try dbWriter.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO fl_recipe_revision
                    (household_id, source, source_recipe_id, revision, recipe_json, title, saved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    householdID.rawValue,
                    revision.key.source.rawValue,
                    revision.key.sourceRecipeID,
                    revision.key.revision,
                    json,
                    revision.title,
                    FLTimestamp.encode(Date()),
                ])
        }
    }

    // MARK: Reading

    /// One stored revision by its stable key, if present.
    public func revision(_ key: RecipeKey, householdID: FLHouseholdID) throws -> RecipeRevision? {
        try dbWriter.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT recipe_json FROM fl_recipe_revision WHERE household_id = ? AND source = ? AND source_recipe_id = ? AND revision = ?",
                arguments: [householdID.rawValue, key.source.rawValue, key.sourceRecipeID, key.revision]
            )
            guard let json: String = row?["recipe_json"] else { return nil }
            return try FLJSON.canonicalDecoder().decode(RecipeRevision.self, from: Data(json.utf8))
        }
    }

    /// The newest stored revision of every recipe in the household, ordered
    /// by title then key — the catalog view candidates come from.
    public func latestRevisions(householdID: FLHouseholdID) throws -> [RecipeRevision] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.recipe_json FROM fl_recipe_revision r
                JOIN (
                    SELECT source, source_recipe_id, MAX(revision) AS rev
                    FROM fl_recipe_revision WHERE household_id = ?
                    GROUP BY source, source_recipe_id
                ) m ON r.source = m.source AND r.source_recipe_id = m.source_recipe_id AND r.revision = m.rev
                WHERE r.household_id = ?
                ORDER BY r.title ASC, r.source ASC, r.source_recipe_id ASC
                """, arguments: [householdID.rawValue, householdID.rawValue])
            return try rows.map { row in
                let json: String = row["recipe_json"]
                return try FLJSON.canonicalDecoder().decode(RecipeRevision.self, from: Data(json.utf8))
            }
        }
    }

    /// The newest revision of every recipe whose title contains `text`
    /// (case-insensitive). Empty text returns everything, like `latestRevisions`.
    public func search(householdID: FLHouseholdID, text: String) throws -> [RecipeRevision] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbWriter.read { db in
            let rows: [Row]
            if query.isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT r.recipe_json FROM fl_recipe_revision r
                    JOIN (
                        SELECT source, source_recipe_id, MAX(revision) AS rev
                        FROM fl_recipe_revision WHERE household_id = ?
                        GROUP BY source, source_recipe_id
                    ) m ON r.source = m.source AND r.source_recipe_id = m.source_recipe_id AND r.revision = m.rev
                    WHERE r.household_id = ?
                    ORDER BY r.title ASC, r.source ASC, r.source_recipe_id ASC
                    """, arguments: [householdID.rawValue, householdID.rawValue])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT r.recipe_json FROM fl_recipe_revision r
                    JOIN (
                        SELECT source, source_recipe_id, MAX(revision) AS rev
                        FROM fl_recipe_revision WHERE household_id = ?
                        GROUP BY source, source_recipe_id
                    ) m ON r.source = m.source AND r.source_recipe_id = m.source_recipe_id AND r.revision = m.rev
                    WHERE r.household_id = ? AND instr(lower(r.title), lower(?)) > 0
                    ORDER BY r.title ASC, r.source ASC, r.source_recipe_id ASC
                    """, arguments: [householdID.rawValue, householdID.rawValue, query.lowercased()])
            }
            return try rows.map { row in
                let json: String = row["recipe_json"]
                return try FLJSON.canonicalDecoder().decode(RecipeRevision.self, from: Data(json.utf8))
            }
        }
    }

    /// How many revisions the household stores (for smoke checks and stats).
    public func count(householdID: FLHouseholdID) throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM fl_recipe_revision WHERE household_id = ?",
                arguments: [householdID.rawValue]
            ) ?? 0
        }
    }
}
