import XCTest
@testable import CommunityCheckKit

/// The community subsystem migrations register and upgrade, standalone and as part of
/// `DatabaseMigrations.migrate` (community SPEC 8.1; pattern follows MigrationUpgradeTests).
final class CommunityMigrationTests: XCTestCase {
  func testCommunityMigrationsRegisterStandaloneIntoOwnMigrator() throws {
    var migrator = DatabaseMigrator()
    CommunityMigrations.register(in: &migrator)

    let db = try DatabaseQueue()
    try migrator.migrate(db)

    let applied = try db.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
    }
    XCTAssertTrue(applied.allSatisfy { $0.hasPrefix("community_") }, "identifiers: \(applied)")
    XCTAssertEqual(
      applied, ["community_user_recipes_v1", "community_user_recipe_revisions_v1",
                "community_outbox_v1", "community_cache_v1"])
  }

  func testFullDatabaseMigrationsCreateCommunityTables() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)

    let tables = try db.read { db in
      try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
    }
    for expected in [
      "community_user_recipes", "community_user_recipe_revisions", "community_outbox",
      "community_feed_cache", "community_table_cache",
    ] {
      XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
    }
  }

  func testCommunityDefaultsArePrivateByDefault() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)

    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO community_user_recipes (community_recipe_id, updated_at)
          VALUES ('ur_defaulttest', '2026-10-15T00:00:00Z')
          """)
    }

    let (state, provenance, ownRights, noPersonalData) = try db.read { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM community_user_recipes WHERE community_recipe_id = 'ur_defaulttest'")!
      return (row["publication_state"] as String, row["provenance"] as String,
              row["own_rights"] as Bool, row["no_personal_data"] as Bool)
    }
    XCTAssertEqual(state, "private")
    XCTAssertEqual(provenance, "user-created")
    XCTAssertFalse(ownRights)
    XCTAssertFalse(noPersonalData)
  }

  func testMigrationsAreIdempotent() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try DatabaseMigrations.migrate(db)
    let count = try db.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM community_user_recipes")
    }
    XCTAssertEqual(count, 0)
  }
}

import GRDB
