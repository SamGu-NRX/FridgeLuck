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

  /// Create or open the database and run migrations.
  static func setup() async throws -> AppDatabase {
    let path = try databasePath()
    var config = Configuration()
    config.foreignKeysEnabled = true

    let dbQueue = try DatabaseQueue(path: path, configuration: config)

    try DatabaseMigrations.migrate(dbQueue)

    let appDB = AppDatabase(dbQueue: dbQueue)

    return appDB
  }

  /// Loads bundled recipes and USDA catalog data if needed.
  ///
  /// `readiness` is the historical-snapshot readiness contract consumed by the
  /// ownership refresh; the default `.pending` fails closed until the
  /// fl-next-historical-nutrition-r1 readiness provider lands. Tests simulate
  /// the snapshot stream having landed by passing an established readiness.
  func warmBundledContentIfNeeded(
    readiness: BundledDataRefresher.HistoricalSnapshotReadiness = .pending
  ) async throws {
    let dbQueue = self.dbQueue

    let recipeCount = try await dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") ?? 0
    }

    if recipeCount == 0 {
      try await BundledDataLoader.loadInto(self)
    }

    try await BundledDataLoader.ensureBundledRecipesHydrated(into: self)
    try await BundledDataLoader.ensureUSDACatalogHydrated(into: self)

    await runBundledOwnershipRefresh(readiness: readiness)

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
  }

  /// Runs the ownership refresh after hydration. Non-fatal by design: the pass is
  /// atomic (any failure rolls the database back untouched), and the next launch
  /// retries. Missing or tampered pins refuse the refresh for this launch —
  /// adoption stays pending rather than guessing ownership from incomplete history.
  /// Historical-snapshot readiness is consulted before any write; the default
  /// `.pending` stays fail-closed until the fl-next-historical-nutrition-r1
  /// readiness provider lands and establishes the snapshot migration and
  /// completion markers — every default pass is refused here and retried on a
  /// later launch.
  private func runBundledOwnershipRefresh(
    readiness: BundledDataRefresher.HistoricalSnapshotReadiness = .pending
  ) async {
    do {
      guard let dataUrl = Bundle.main.url(forResource: "data", withExtension: "json") else {
        return
      }
      let jsonData = try Data(contentsOf: dataUrl)
      let bundled = try JSONDecoder().decode(BundledData.self, from: jsonData)
      guard
        let pinsDirectory = Bundle.main.url(forResource: "LegacyBundles", withExtension: nil)
      else {
        throw LegacyBundlePinError.manifestMissing
      }
      let pins = try LegacyBundlePins.load(from: pinsDirectory)
      let currentCatalog: [LegacyCatalogIngredient]
      if let catalogUrl = Bundle.main.url(
        forResource: "usda_ingredient_catalog", withExtension: "sqlite")
      {
        currentCatalog = try BundledDataLoader.currentCatalogIngredients(from: catalogUrl)
      } else {
        currentCatalog = []
      }
      let pass = BundledDataRefresher.loadCurrentPass(
        current: bundled,
        currentDataSha256: LegacyBundlePins.sha256Hex(jsonData),
        currentCatalog: currentCatalog,
        pins: pins)
      let outcome = try await BundledDataRefresher.refresh(
        appDB: self, pass: pass, readiness: readiness)
      #if DEBUG
        print(
          "[AppDatabase] Bundle refresh: adopted \(outcome.ingredientsAdopted) ingredients / "
            + "\(outcome.recipesAdopted) recipes, updated \(outcome.ingredientsUpdated) / "
            + "\(outcome.recipesUpdated), inserted \(outcome.ingredientsInserted) / "
            + "\(outcome.recipesInserted)")
      #endif
    } catch {
      #if DEBUG
        print("[AppDatabase] Bundle refresh skipped: \(error)")
      #endif
    }
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
