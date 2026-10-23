import Foundation
import GRDB

// MARK: - App database
// Engineering plan §Persistence: WAL journal mode, foreign keys enforced, and
// every write ordered (serialized writer). Reads go through the pool; on Linux
// a pooled writer behaves like a serialized queue, which is what the phone
// needs: one writer, many readers.

public struct AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Open (and migrate) the database at `url` in WAL mode with foreign keys
    /// enforced.
    public static func open(at url: URL) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(
            path: url.path,
            configuration: configuration
        )
        return AppDatabase(dbWriter: pool)
    }

    /// The default on-disk database (Application Support contract above).
    public static func openDefault() throws -> AppDatabase {
        try open(at: FLDefaultDatabaseDirectory.databaseURL())
    }

    /// Open an in-memory database with the same settings — for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        return AppDatabase(dbWriter: queue)
    }

    /// Apply pending migrations.
    public func migrate() throws {
        try FLSchemaMigrations.migrator().migrate(dbWriter)
    }

    /// Run a read.
    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    /// Run one serialized write.
    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    // MARK: Schema introspection (GRDB-free API for tests and callers)

    /// Whether a table exists (after migrations, callers can assert their own
    /// tables are present).
    public func tableExists(_ name: String) throws -> Bool {
        try dbWriter.read { db in
            try db.tableExists(name)
        }
    }

    /// Migration IDs already applied to this database.
    public func appliedMigrations() throws -> [String] {
        try dbWriter.read { db in
            try FLSchemaMigrations.migrator().appliedMigrations(db)
        }
    }

    /// The SQLite journal mode. WAL is required for the on-disk pool.
    public func journalMode() throws -> String {
        try dbWriter.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
    }
}
