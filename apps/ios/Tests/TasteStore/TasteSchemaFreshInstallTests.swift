import GRDB
import XCTest

@testable import FridgeLuck

/// Fresh-install schema: a full app migrate creates the taste tables. This suite is
/// deliberately separate from TasteEventStoreTests: it exercises DatabaseMigrations, the
/// full app migration chain, which lives in the iOS target — the portable Linux mirror
/// (Tools/taste-store-check) runs the taste subsystem migrations on hand-built core tables
/// instead and cannot run this test.
final class TasteSchemaFreshInstallTests: XCTestCase {
  func testTasteTablesExistAfterAFreshMigrate() throws {
    let db = try DatabaseQueue()

    try DatabaseMigrations.migrate(db)

    try db.read { db in
      for table in ["taste_events", "taste_exposures", "taste_statements"] {
        let exists = try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
          arguments: [table])
        XCTAssertTrue(exists ?? false, "missing taste table: \(table)")
      }
    }
  }
}
