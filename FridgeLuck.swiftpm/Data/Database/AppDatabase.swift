import Foundation
import GRDB

/// The single entry point for all database access in the app.
/// Created once at launch, shared via AppDependencies.
final class AppDatabase: Sendable {
  let dbQueue: DatabaseQueue

  init(dbQueue: DatabaseQueue) {
    self.dbQueue = dbQueue
  }

  // MARK: - Setup

  /// Create or open the database, run migrations, and bootstrap bundled data if needed.
  static func setup() async throws -> AppDatabase {
    let path = try databasePath()
    var config = Configuration()
    config.foreignKeysEnabled = true

    let dbQueue = try DatabaseQueue(path: path, configuration: config)

    // Run migrations
    try DatabaseMigrations.migrate(dbQueue)

    let appDB = AppDatabase(dbQueue: dbQueue)

    // Bootstrap bundled data on first launch
    let recipeCount = try await dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") ?? 0
    }

    if recipeCount == 0 {
      try await BundledDataLoader.loadInto(appDB)
    }

    // Keep USDA catalog hydration independent from first-launch recipe bootstrap.
    try await BundledDataLoader.ensureUSDACatalogHydrated(into: appDB)

    #if DEBUG
      let diagnostics = try await dbQueue.read { db in
        let ingredientCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients") ?? 0
        let aliasCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredient_aliases") ?? 0
        return (ingredientCount, aliasCount)
      }
      print(
        "[AppDatabase] Catalog counts: ingredients=\(diagnostics.0), ingredient_aliases=\(diagnostics.1)"
      )
    #endif

    return appDB
  }

  // MARK: - Database Path

  private static func databasePath() throws -> String {
    let dir = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return dir.appendingPathComponent("fridgeluck.sqlite").path
  }
}
