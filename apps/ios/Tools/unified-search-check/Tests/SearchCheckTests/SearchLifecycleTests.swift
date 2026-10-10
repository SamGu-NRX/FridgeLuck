import XCTest
import GRDB
@testable import SearchCheck

final class SearchLifecycleTests: XCTestCase {
  private func makeService(
    world: SearchFixtures.World,
    store: SearchIndexStore,
    epoch: @escaping @Sendable () -> String?
  ) -> SearchIndexService {
    SearchIndexService(
      store: store,
      sources: world.sources,
      sourceEpochProvider: epoch)
  }

  // MARK: - Bootstrap

  func testBootstrapBuildsTheIndexFromAllSources() throws {
    let world = try SearchFixtures.makeWorld()
    let store = try SearchIndexStore()
    let service = makeService(world: world, store: store, epoch: { "epoch-1" })

    try service.bootstrap()

    XCTAssertEqual(try service.documentCount(), 6)
    XCTAssertEqual(try service.documentCount(kind: .kitchenIngredient), 3)
    XCTAssertEqual(try service.documentCount(kind: .kitchenInventory), 1)
    XCTAssertEqual(try service.documentCount(kind: .recipe), 1)
    XCTAssertEqual(try service.documentCount(kind: .journal), 1)
    XCTAssertEqual(try store.storedSourceEpoch(), "epoch-1")
    XCTAssertEqual(try store.storedSchemaVersion(), SearchIndexStore.indexSchemaVersion)
  }

  func testBootstrapIsIdempotentWhenCurrent() throws {
    let world = try SearchFixtures.makeWorld()
    let store = try SearchIndexStore()
    let service = makeService(world: world, store: store, epoch: { "epoch-1" })

    try service.bootstrap()
    try service.bootstrap()
    try service.bootstrap()

    XCTAssertEqual(try service.documentCount(), 6)
    XCTAssertEqual(try store.storedSourceEpoch(), "epoch-1")
  }

  func testEpochChangeTriggersRebuild() throws {
    let world = try SearchFixtures.makeWorld()
    let store = try SearchIndexStore()
    let epoch = TestEpochBox("epoch-1")
    let service = makeService(world: world, store: store, epoch: { epoch.get() })

    try service.bootstrap()
    XCTAssertEqual(try store.count(), 6)

    // Simulate a restore/replaced source database: bump the epoch and change
    // the source world.
    let newRecipe = Recipe(
      id: nil,
      title: "Lemon Chicken",
      timeMinutes: 25,
      servings: 2,
      instructions: "Cook it.",
      tags: 0,
      source: .user,
      createdAt: Date(timeIntervalSince1970: 1_780_100_000))
    _ = try world.recipeRepository.saveRecipe(newRecipe, ingredients: [])
    epoch.set("epoch-2")

    // A fresh service/store pair over the same sources sees the new epoch.
    let reopenedStore = try SearchIndexStore()
    let reopenedService = makeService(world: world, store: reopenedStore, epoch: { epoch.get() })
    try reopenedService.bootstrap()
    XCTAssertEqual(try reopenedStore.count(), 7)
    XCTAssertEqual(try reopenedStore.storedSourceEpoch(), "epoch-2")
  }

  // MARK: - Query entry

  func testSearchThroughServiceRevalidatesAndDropsDeletedRecords() throws {
    let world = try SearchFixtures.makeWorld()
    let store = try SearchIndexStore()
    let service = makeService(world: world, store: store, epoch: { "epoch-1" })
    try service.bootstrap()

    // Delete the ingredient behind one of the indexed documents directly in
    // the source database.
    try world.db.write { db in
      try db.execute(sql: "DELETE FROM ingredients WHERE name = ?", arguments: ["Soy Sauce"])
    }

    let results = try service.search("soy")
    XCTAssertTrue(results.isEmpty)
    // Repaired out of the index, not just filtered from this response.
    XCTAssertEqual(try service.documentCount(), 5)

    // Live records still resolve.
    let chicken = try service.search("chicken")
    XCTAssertFalse(chicken.isEmpty)
  }

  func testServiceSearchResolvesJournalEntriesAgainstLiveRows() throws {
    let world = try SearchFixtures.makeWorld()
    let store = try SearchIndexStore()
    let service = makeService(world: world, store: store, epoch: { "epoch-1" })
    try service.bootstrap()

    let results = try service.search("garlic")
    // The journal entry surfaces the cooked recipe's title, so both kinds
    // match; kind order puts the recipe first.
    XCTAssertEqual(results.map { $0.canonicalID.kind }, [.recipe, .journal])
    XCTAssertEqual(results.first?.title, "Garlic Chicken")

    let journal = try service.search("2026-06")
    XCTAssertEqual(journal.count, 1)
    XCTAssertEqual(journal.first?.canonicalID.kind, .journal)
  }

  // MARK: - Restore notification

  func testRestoreNotificationTriggersRebuild() throws {
    let world = try SearchFixtures.makeWorld()
    let dir = SearchFixtures.makeTempDirectory("restore")
    let epochValue = TestEpochBox("epoch-restore")
    let service = SearchIndexService(
      indexPath: dir + "/index.db",
      sources: world.sources,
      sourceEpochProvider: { epochValue.get() })
    // Keep the token alive in scope for the observer's lifetime.
    let restoreToken = service.observeRestoreNotifications()
    defer { _ = restoreToken }

    try service.bootstrap()
    XCTAssertEqual(try service.documentCount(), 6)

    // A restore replaces the source world (extra recipe); the notification
    // must trigger a rebuild that picks it up.
    let newRecipe = Recipe(
      id: nil,
      title: "Chickpea Salad",
      timeMinutes: 15,
      servings: 2,
      instructions: "Mix.",
      tags: 0,
      source: .user,
      createdAt: Date(timeIntervalSince1970: 1_780_200_000))
    _ = try world.recipeRepository.saveRecipe(newRecipe, ingredients: [])
    epochValue.set("epoch-restored")

    NotificationCenter.default.post(
      name: SearchIndexService.userDataDidRestoreNotificationName, object: nil)

    // The observer rebuilds off-thread; poll briefly for the new epoch.
    let deadline = Date().addingTimeInterval(10)
    var rebuilt = false
    while Date() < deadline {
      if (try? service.documentCount()) == 7,
        (try? SearchIndexStore(path: dir + "/index.db").storedSourceEpoch()) == "epoch-restored"
      {
        rebuilt = true
        break
      }
      usleep(100_000)
    }
    XCTAssertTrue(rebuilt, "restore notification did not trigger a rebuild in time")
  }

  // MARK: - Corruption recovery

  func testCorruptIndexFileIsDeletedAndRecreated() throws {
    let world = try SearchFixtures.makeWorld()
    let dir = SearchFixtures.makeTempDirectory("corrupt")
    let path = dir + "/index.db"

    // A foreign file that is not a SQLite database.
    try "not a database at all".write(toFile: path, atomically: true, encoding: .utf8)

    let service = SearchIndexService(
      indexPath: path,
      sources: world.sources,
      sourceEpochProvider: { "epoch-1" })
    try service.bootstrap()

    XCTAssertEqual(try service.documentCount(), 6)
    XCTAssertGreaterThan(service.indexFileSizeBytes(), 0)
  }

  func testSchemaVersionMismatchForcesRebuild() throws {
    let world = try SearchFixtures.makeWorld()
    let dir = SearchFixtures.makeTempDirectory("schema")
    let path = dir + "/index.db"

    let service = SearchIndexService(
      indexPath: path,
      sources: world.sources,
      sourceEpochProvider: { "epoch-1" })
    try service.bootstrap()
    XCTAssertEqual(try service.documentCount(), 6)

    // Age the index: pretend an older app version wrote it.
    let raw = try DatabaseQueue(path: path)
    try raw.write { db in
      try db.execute(
        sql: "UPDATE search_meta SET value = '0' WHERE key = 'schema_version'")
    }

    // Same epoch, but the stale schema version must force a full rebuild.
    try service.bootstrap()
    XCTAssertEqual(try service.documentCount(), 6)
    let reread = try DatabaseQueue(path: path)
    let version = try reread.read { db -> Int? in
      try Int.fetchOne(
        db, sql: "SELECT value FROM search_meta WHERE key = 'schema_version'")
    }
    XCTAssertEqual(version, SearchIndexStore.indexSchemaVersion)
  }
}
