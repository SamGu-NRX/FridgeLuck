import XCTest
import GRDB
@testable import SearchCheck

/// Tap-path resolution through `SearchIndexService.resolve(_:)`: a valid hit
/// resolves the canonical live record, deleted records are refused (and
/// repaired out of the index), and stale hits are refused without guessing.
///
/// Uses the production resolver through the service — no stubs — with a
/// constant source epoch so direct database writes do NOT trigger a rebuild.
/// The index therefore intentionally keeps stale and deleted documents, and
/// `resolve` itself is what must refuse them.
final class SearchResolveTests: XCTestCase {
  private func makeService(
    world: SearchFixtures.World,
    store: SearchIndexStore
  ) -> SearchIndexService {
    SearchIndexService(
      store: store,
      sources: world.sources,
      sourceEpochProvider: { "epoch-1" })
  }

  // MARK: - Valid hits

  func testTapOnRecipeHitResolvesTheCanonicalLiveRecord() throws {
    let world = try SearchFixtures.makeWorld()
    let service = makeService(world: world, store: try SearchIndexStore())
    try service.bootstrap()

    let hits = try service.search("garlic chicken")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .recipe }) else {
      return XCTFail("expected a recipe hit for 'garlic chicken'")
    }

    let resolved = try service.resolve(hit)

    guard case .recipe(let recipe)? = resolved else {
      return XCTFail("expected a resolved recipe, got \(String(describing: resolved))")
    }
    XCTAssertEqual(recipe.title, "Garlic Chicken")
    XCTAssertEqual(recipe.id, Int64(hit.canonicalID.rawID))
  }

  func testTapOnJournalHitResolvesTheCanonicalLiveRecord() throws {
    let world = try SearchFixtures.makeWorld()
    let service = makeService(world: world, store: try SearchIndexStore())
    try service.bootstrap()

    let hits = try service.search("garlic chicken")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .journal }) else {
      return XCTFail("expected a journal hit for 'garlic chicken'")
    }

    let resolved = try service.resolve(hit)

    guard case .journal(let detail)? = resolved else {
      return XCTFail("expected a resolved journal entry, got \(String(describing: resolved))")
    }
    XCTAssertEqual(detail.historyId, Int64(hit.canonicalID.rawID))
    XCTAssertEqual(detail.recipeTitle, "Garlic Chicken")
    XCTAssertEqual(detail.rating, 4)
  }

  func testTapOnInventoryHitResolvesTheCanonicalLiveRecord() throws {
    let world = try SearchFixtures.makeWorld()
    let service = makeService(world: world, store: try SearchIndexStore())
    try service.bootstrap()

    let hits = try service.search("in stock")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .kitchenInventory }) else {
      return XCTFail("expected an inventory hit for 'in stock'")
    }

    let resolved = try service.resolve(hit)

    guard case .kitchenInventory(let detail)? = resolved else {
      return XCTFail("expected a resolved inventory item, got \(String(describing: resolved))")
    }
    XCTAssertEqual(detail.ingredientName, "Chicken Breast")
    XCTAssertEqual(detail.totalRemainingGrams, 350)
    XCTAssertEqual(detail.storageLocation, .fridge)
  }

  func testTapOnIngredientHitResolvesTheCanonicalLiveRecord() throws {
    let world = try SearchFixtures.makeWorld()
    let service = makeService(world: world, store: try SearchIndexStore())
    try service.bootstrap()

    let hits = try service.search("soy")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .kitchenIngredient }) else {
      return XCTFail("expected an ingredient hit for 'soy'")
    }

    let resolved = try service.resolve(hit)

    guard case .kitchenIngredient(let ingredient)? = resolved else {
      return XCTFail("expected a resolved ingredient, got \(String(describing: resolved))")
    }
    XCTAssertEqual(ingredient.name, "Soy Sauce")
    XCTAssertEqual(ingredient.id, Int64(hit.canonicalID.rawID))
  }

  // MARK: - Deleted records

  func testTapOnDeletedRecordIsRefusedAndRepairedOutOfTheIndex() throws {
    let world = try SearchFixtures.makeWorld()
    let store = try SearchIndexStore()
    let service = makeService(world: world, store: store)
    try service.bootstrap()
    XCTAssertEqual(try service.documentCount(), 6)

    let hits = try service.search("soy")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .kitchenIngredient }) else {
      return XCTFail("expected an ingredient hit for 'soy'")
    }

    // Delete the record behind the hit directly in the source database. The
    // constant test epoch keeps the index stale on purpose.
    try world.db.write { db in
      try db.execute(sql: "DELETE FROM ingredients WHERE name = ?", arguments: ["Soy Sauce"])
    }

    // The tap path refuses to resolve a deleted record and repairs the dead
    // document out of the index.
    XCTAssertNil(try service.resolve(hit))
    XCTAssertEqual(try service.documentCount(), 5)

    // A repeat tap of the same dead hit still refuses (no crash, no guess).
    XCTAssertNil(try service.resolve(hit))
  }

  // MARK: - Stale hits

  func testTapOnStaleJournalHitIsRefusedWithoutMutatingTheIndex() throws {
    let world = try SearchFixtures.makeWorld()
    let service = makeService(world: world, store: try SearchIndexStore())
    try service.bootstrap()

    let hits = try service.search("garlic chicken")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .journal }) else {
      return XCTFail("expected a journal hit for 'garlic chicken'")
    }
    // Fresh at search time: the hit resolves.
    XCTAssertNotNil(try service.resolve(hit))

    // The record changes after the hit was indexed (the journal revision is
    // derived from cookedAt and rating, so the change is deterministic).
    try world.db.write { db in
      try db.execute(
        sql: "UPDATE cooking_history SET rating = ? WHERE id = ?",
        arguments: [2, Int64(hit.canonicalID.rawID)])
    }

    // The tap path refuses the stale hit instead of serving outdated state.
    XCTAssertNil(try service.resolve(hit))

    // Refusal does not destroy the document: it stays indexed and is healed
    // by the next epoch-triggered rebuild.
    XCTAssertEqual(try service.documentCount(), 6)
  }

  func testTapOnStaleInventoryHitIsRefused() throws {
    let world = try SearchFixtures.makeWorld()
    let service = makeService(world: world, store: try SearchIndexStore())
    try service.bootstrap()

    let hits = try service.search("in stock")
    guard let hit = hits.first(where: { $0.canonicalID.kind == .kitchenInventory }) else {
      return XCTFail("expected an inventory hit for 'in stock'")
    }
    // Fresh at search time: the hit resolves.
    XCTAssertNotNil(try service.resolve(hit))

    // Stock state changes after the hit was indexed. Fixed timestamps on
    // both sides keep the revision change deterministic.
    let chickenId = try world.db.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT id FROM ingredients WHERE name = ?",
        arguments: ["Chicken Breast"])
    }
    try world.db.write { db in
      try db.execute(
        sql: "UPDATE inventory_items SET last_updated_at = ? WHERE ingredient_id = ?",
        arguments: [Date(timeIntervalSince1970: 1_781_000_000), chickenId])
    }

    // The tap path refuses the stale hit instead of serving outdated stock.
    XCTAssertNil(try service.resolve(hit))
  }
}
