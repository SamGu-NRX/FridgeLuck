import GRDB
import XCTest

@testable import FridgeLuck

/// The migration seam: `DatabaseMigrations.migrate` registers the four subsystem migration
/// files after the core `vN_` migrations. Four branches add migrations to those files in
/// parallel, so these tests pin the contract they rely on — structural rules that stay true
/// as subsystem migrations are filled in, not a snapshot of today's identifier list.
final class MigrationSeamTests: XCTestCase {
  private let subsystemPrefixes = ["recipes_", "taste_", "cook_", "community_"]

  func testFreshDatabaseMigratesFully() throws {
    let db = try DatabaseQueue()

    try DatabaseMigrations.migrate(db)

    let applied = try appliedIdentifiers(db)
    XCTAssertEqual(applied.first, "v1_initial")
    XCTAssertEqual(applied.count, Set(applied).count, "duplicate migration identifiers")
  }

  func testMigratingUpToV18StillWorksAndAFullMigrateFinishesAfterIt() throws {
    let db = try DatabaseQueue()

    try DatabaseMigrations.migrate(db, upTo: "v18_cooking_history_swaps")
    let throughV18 = try appliedIdentifiers(db)
    XCTAssertEqual(throughV18.last, "v18_cooking_history_swaps")
    XCTAssertFalse(throughV18.contains(where: isSubsystem), "v18 target applied subsystem migrations")

    try DatabaseMigrations.migrate(db)
    let after = try appliedIdentifiers(db)
    // The completing migrate only appends; nothing registered earlier re-runs or reorders.
    XCTAssertEqual(Array(after.prefix(throughV18.count)), throughV18)
  }

  func testEveryAppliedIdentifierIsCoreOrSubsystem() throws {
    let db = try DatabaseQueue()

    try DatabaseMigrations.migrate(db)

    for identifier in try appliedIdentifiers(db) {
      XCTAssertTrue(
        isCore(identifier) || isSubsystem(identifier),
        "unexpected migration identifier: \(identifier)")
    }
  }

  func testCoreMigrationsRunBeforeSubsystemMigrationsInFixedOrder() throws {
    let db = try DatabaseQueue()

    try DatabaseMigrations.migrate(db)

    let applied = try appliedIdentifiers(db)
    let firstSubsystem = applied.firstIndex(where: isSubsystem) ?? applied.count
    for identifier in applied.prefix(firstSubsystem) {
      XCTAssertTrue(isCore(identifier), "core block contains non-core identifier: \(identifier)")
    }
    // Subsystem identifiers appear in the fixed registration order
    // (RecipeCatalog, Taste, CookSession, Community).
    var lastBlock = -1
    for identifier in applied.suffix(from: firstSubsystem) {
      let block = try XCTUnwrap(
        subsystemPrefixes.firstIndex(where: identifier.hasPrefix),
        "unexpected subsystem identifier: \(identifier)")
      XCTAssertGreaterThanOrEqual(block, lastBlock, "subsystem registration order changed")
      lastBlock = block
    }
  }

  // MARK: - Helpers

  private func appliedIdentifiers(_ db: DatabaseQueue) throws -> [String] {
    try db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
  }

  /// Core migrations are named `vN_...` with at least one digit after the `v`.
  private func isCore(_ identifier: String) -> Bool {
    guard identifier.first == "v" else { return false }
    let afterV = identifier.dropFirst()
    let digitCount = afterV.prefix { $0.isNumber }.count
    return digitCount > 0 && afterV.dropFirst(digitCount).first == "_"
  }

  private func isSubsystem(_ identifier: String) -> Bool {
    subsystemPrefixes.contains { identifier.hasPrefix($0) }
  }
}
