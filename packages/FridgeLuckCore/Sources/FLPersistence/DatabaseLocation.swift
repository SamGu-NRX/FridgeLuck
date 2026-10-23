import Foundation

// MARK: - Default database location
// Engineering plan §Persistence: the default database lives in the app's
// Application Support directory; tests use in-memory or temporary locations.
// The contract lives here so every caller resolves the same place, and the
// error is explicit rather than a silent fallback.

public enum FLPersistenceError: Error, Equatable, Sendable {
    /// No usable home/Application Support directory could be resolved.
    case noApplicationSupportDirectory
    /// A stored value this build cannot interpret — the store was modified
    /// outside the domain (or written by an incompatible schema). Reads fail
    /// closed: the row is refused, never reinterpreted.
    case corruptRecord(table: String, column: String, value: String, reason: String)
}

public enum FLDefaultDatabaseDirectory {
    /// The default database file URL:
    /// `Application Support/FridgeLuck/fridgeluck.sqlite3`.
    /// The directory is created if missing.
    public static func databaseURL() throws -> URL {
        try databaseURL(
            fileManager: .default,
            appSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
    }

    /// Testable core: inject the resolved Application Support URL.
    public static func databaseURL(fileManager: FileManager, appSupport: URL?) throws -> URL {
        guard let appSupport else {
            throw FLPersistenceError.noApplicationSupportDirectory
        }
        let directory = appSupport.appendingPathComponent("FridgeLuck", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fridgeluck.sqlite3")
    }
}
