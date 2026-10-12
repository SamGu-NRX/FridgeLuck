import XCTest
@testable import FLPersistence

final class AppDatabaseTests: XCTestCase {
    // MARK: In-memory

    func testInMemoryDatabaseMigrates() throws {
        let db = try AppDatabase.inMemory()
        try db.migrate()
        XCTAssertTrue(try db.tableExists("fl_schema_baseline"))
        let applied = try db.appliedMigrations()
        XCTAssertEqual(applied, ["v1-baseline", "v2-cooks-preference-events"])
    }

    // MARK: On-disk

    func testOnDiskDatabaseMigratesAndUsesWAL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FLPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("test.sqlite3")
        let db = try AppDatabase.open(at: url)
        try db.migrate()

        XCTAssertTrue(try db.tableExists("fl_schema_baseline"))
        // WAL is the required journal mode for the on-disk pool.
        XCTAssertEqual(try db.journalMode(), "wal")

        // Reopening applies no new migrations and sees the same schema.
        let reopened = try AppDatabase.open(at: url)
        try reopened.migrate()
        XCTAssertEqual(try reopened.appliedMigrations(), ["v1-baseline", "v2-cooks-preference-events"])
    }

    // MARK: Default directory contract

    func testDefaultDirectoryResolvesUnderInjectedAppSupport() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("FLAppSupport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let url = try FLDefaultDatabaseDirectory.databaseURL(
            fileManager: .default, appSupport: appSupport
        )
        XCTAssertEqual(
            url.path,
            appSupport.appendingPathComponent("FridgeLuck", isDirectory: true)
                .appendingPathComponent("fridgeluck.sqlite3").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupport.path))
    }

    func testMissingAppSupportIsAnExplicitError() {
        XCTAssertThrowsError(
            try FLDefaultDatabaseDirectory.databaseURL(fileManager: .default, appSupport: nil)
        ) { error in
            XCTAssertEqual(
                error as? FLPersistenceError,
                .noApplicationSupportDirectory
            )
        }
    }
}
