import GRDB
import XCTest

#if canImport(FridgeLuck)
@testable import FridgeLuck
#else
@testable import FLInventoryCore
#endif

/// Replays the migration-order contracts against the real migrator on Linux,
/// mirroring the native MigrationUpgradeTests suffix pin and the check
/// packages' registry-bound pin:
///
/// - A fresh install's registry ends at `v21_bundle_ownership`.
/// - An upgrade from the last-shipped (v15) schema applies exactly
///   v16-v20 at setup; v21 is deferred to the ownership refresh stream.
/// - An upgrade from a v16+ schema still ends at v21.
/// - The refresh stream's schema application is idempotent.
final class MigrationOrderReplayTests: XCTestCase {
  private let lastShippedMigration = "v15_notification_rules_and_opportunities"

  func testFreshRegistryEndsAtV21() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)

    let applied = try appliedMigrations(db)
    XCTAssertEqual(applied.last, "v21_bundle_ownership")
  }

  func testUpgradeFromShippedSchemaAppliesV16ThroughV20() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: lastShippedMigration)

    try DatabaseMigrations.migrate(db)

    XCTAssertEqual(
      try appliedMigrations(db).suffix(5),
      [
        "v16_inventory_quantity_estimates",
        "v17_cooking_portion_multiplier",
        "v18_cooking_history_swaps",
        "v19_explicit_allergen_groups",
        "v20_historical_nutrition_snapshots",
      ])
  }

  func testUpgradeFromV18StillEndsAtV21() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: "v18_cooking_history_swaps")

    try DatabaseMigrations.migrate(db)

    XCTAssertEqual(try appliedMigrations(db).last, "v21_bundle_ownership")
  }

  func testRefreshStreamAppliesDeferredBundleOwnershipIdempotently() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db, upTo: lastShippedMigration)
    try DatabaseMigrations.migrate(db)
    XCTAssertFalse(try appliedMigrations(db).contains("v21_bundle_ownership"))

    try DatabaseMigrations.applyBundleOwnershipSchemaIfNeeded(db)
    try DatabaseMigrations.applyBundleOwnershipSchemaIfNeeded(db)

    XCTAssertEqual(try appliedMigrations(db).last, "v21_bundle_ownership")
    let ownershipColumn = try db.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM pragma_table_info('ingredients') WHERE name = 'ownership_key'"
      )
    }
    XCTAssertEqual(ownershipColumn, 1)
  }

  private func appliedMigrations(_ db: DatabaseQueue) throws -> [String] {
    try db.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }
  }
}
