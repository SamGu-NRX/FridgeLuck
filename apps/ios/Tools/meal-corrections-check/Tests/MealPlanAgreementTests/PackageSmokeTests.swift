import GRDB
import XCTest

@testable import FridgeLuck

final class PackageSmokeTests: XCTestCase {
  func testInMemoryMigrationsRun() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let tableCount = try db.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'"
      ) ?? 0
    }
    XCTAssertGreaterThan(tableCount, 5)
  }
}
