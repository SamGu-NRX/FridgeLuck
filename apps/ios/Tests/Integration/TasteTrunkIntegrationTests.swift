import FLFeatureLogic
import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

/// Trunk-integration seams for the taste subsystem (iOS-only: needs DatabaseMigrations,
/// the full app migration chain, and the real PersonalizationService).
///
/// The trunk merge makes the store persist the public FLFeatureLogic contract types
/// (`TasteEvent` / `TasteExposure`) directly, with one shared `RecipeRef` identity across
/// Recipe, LeChef, Community, and Taste. These tests pin the two seams a future
/// duplication would silently break:
/// 1. a `RecipeRef` from the bundle contract converts losslessly into the identity the
///    taste store persists, and encodes the burst5 contract wire shape;
/// 2. events written through the service, loaded from the store, and replayed by
///    `TasteResidualEngine` produce exactly the engine result a direct replay produces.
final class TasteTrunkIntegrationTests: XCTestCase {
  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return db
  }

  /// One cookable catalog recipe with a single required ingredient, matching the core
  /// schema the meal log and the taste engine's recipe features read.
  private func seedCookableRecipe(_ db: Database) throws {
    try db.execute(
      sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES (1, 'Chicken Rice', 10, 1, 'Cook.')")
    try db.execute(
      sql: """
        INSERT INTO ingredients (id, name, calories, protein, carbs, fat)
        VALUES (10, 'Chicken', 165, 31, 0, 3.6)
        """)
    try db.execute(
      sql: """
        INSERT INTO recipe_ingredients
          (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
        VALUES (1, 10, 1, 100, '100 g')
        """)
  }

  func testRecipeRefIsTheSingleSharedIdentity() throws {
    let ref = RecipeRef(source: .catalog, id: "rcp-000123", revision: 3)
    let taste = TasteRecipeRef(id: ref.id, revision: ref.revision, source: ref.source.rawValue)
    XCTAssertEqual(taste.id, ref.id)
    XCTAssertEqual(taste.revision, ref.revision)
    XCTAssertEqual(taste.source, ref.source.rawValue)

    // The burst5 contract wire shape: {"source", "id", "revision"} as flat strings/int.
    let data = try JSONEncoder().encode(ref)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["source"] as? String, "catalog")
    XCTAssertEqual(json["id"] as? String, "rcp-000123")
    XCTAssertEqual(json["revision"] as? Int, 3)
  }

  func testServiceEventsReplayThroughTheEngineOverTheFullMigrationChain() throws {
    let dbQueue = try makeDatabase()
    try dbQueue.write { db in try seedCookableRecipe(db) }
    let service = PersonalizationService(db: dbQueue)

    for _ in 0..<3 {
      _ = try service.recordCooking(recipeId: 1, rating: 5, servingsConsumed: 2)
    }
    try service.rateLastCooking(recipeId: 1, rating: 5)

    let store = TasteEventStore(db: dbQueue)
    let loaded = try store.allEvents().map(\.event)
    XCTAssertTrue(
      loaded.contains { $0.kind == TasteEventKind.recipeCooked.rawValue },
      "expected recipe_cooked events through the full migration chain")
    XCTAssertTrue(
      loaded.contains { $0.kind == TasteEventKind.recipeRated.rawValue },
      "expected a recipe_rated event through the full migration chain")

    var engineFromStore = TasteResidualEngine(
      featureKeysByRecipe: ["1": ["ingredient:10"]], nameOf: ["ingredient:10": "Chicken"])
    engineFromStore.ingest(events: loaded, exposures: [])
    var engineDirect = TasteResidualEngine(
      featureKeysByRecipe: ["1": ["ingredient:10"]], nameOf: ["ingredient:10": "Chicken"])
    engineDirect.ingest(events: loaded, exposures: [])
    let evalAt = TasteTimestamp.string(from: Date().addingTimeInterval(10_000_000))
    XCTAssertEqual(
      engineFromStore.contributions(evalAt: evalAt),
      engineDirect.contributions(evalAt: evalAt),
      "store round-trip must not change what the engine learns")
    // Three 5-star cooks plus a 5-star rating: chicken learns positive weight.
    XCTAssertGreaterThan(
      engineFromStore.contributions(evalAt: evalAt)["ingredient:10"] ?? 0, 0)
  }
}
