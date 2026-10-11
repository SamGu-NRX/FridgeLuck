import GRDB

/// VENDORED FIXTURE — NOT PRODUCTION CODE.
///
/// The `v21_bundle_ownership` migration body, extracted VERBATIM from
/// `apps/ios/Platform/Persistence/Database/Migrations.swift` on branch
/// obv/fl-next-bundled-refresh at head 7dc2b219204c (PR #44). On that branch the
/// app's migrator registers this after v20_historical_nutrition_snapshots; the
/// two streams' migrations apply cleanly in sequence against one database.
///
/// This check package's `DatabaseMigrations` (copied from THIS branch) stops at
/// v20 — the refresh owner's stream is not merged here yet. The Flow E fixture
/// applies this body by hand after the standard migrations so the real refresher
/// runs against the ownership schema it expects. It is deliberately not
/// registered in the package migrator: when PR #44 merges, the app migrator
/// owns this migration and this fixture should be replaced by the merge.
enum VendoredBundleOwnershipMigration {
  static func apply(_ db: Database) throws {
    // The bundle refresh needs two things hydration history never recorded: which
    // installed rows came from the bundled data at all, and what the bundle last
    // wrote to them. Ownership keys name the bundle entry a row came from (stable
    // across bundle content versions); canonical hashes capture the bundle-written
    // columns so a later refresh can tell untouched rows from user-modified ones.
    // Diagnostics record anything the refresh could not silently resolve.
    try db.alter(table: "recipes") { t in
      t.add(column: "ownership_key", .text)
      t.add(column: "bundle_content_hash", .text)
    }
    try db.alter(table: "ingredients") { t in
      t.add(column: "ownership_key", .text)
      t.add(column: "bundle_content_hash", .text)
    }

    // One bundle entry can adopt at most one installed row per kind; partial
    // indexes keep NULL (not-yet-adopted) rows free to coexist.
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX idx_recipes_ownership_key ON recipes(ownership_key)
        WHERE ownership_key IS NOT NULL
        """)
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX idx_ingredients_ownership_key ON ingredients(ownership_key)
        WHERE ownership_key IS NOT NULL
        """)

    try db.create(table: "bundle_refresh_diagnostics") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("entity_type", .text).notNull()
      t.column("entity_ref", .text).notNull()
      t.column("code", .text).notNull()
      t.column("detail", .text).notNull().defaults(to: "{}")
      t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
    }
    // Unique on (entity_type, entity_ref, code): the refresher upserts diagnostics
    // with ON CONFLICT so repeated passes refresh one row per problem.
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX idx_bundle_refresh_diagnostics_entity
        ON bundle_refresh_diagnostics(entity_type, entity_ref, code)
        """)
    try db.create(
      index: "idx_bundle_refresh_diagnostics_code",
      on: "bundle_refresh_diagnostics",
      columns: ["code"])
  }
}
