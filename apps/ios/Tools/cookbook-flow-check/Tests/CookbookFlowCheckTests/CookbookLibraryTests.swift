import GRDB
import XCTest
@testable import CookbookFlowCheck

/// M2: save/unsave, favorites, collections, and versioned sidecar recovery.
final class CookbookLibraryTests: XCTestCase {
  // MARK: - Fixtures

  private func makeSidecarURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("sidecar-\(UUID().uuidString).json")
  }

  @discardableResult
  private func makeService(
    _ db: DatabaseQueue, sidecarURL: URL
  ) -> CookbookLibraryService {
    CookbookLibraryService(db: db, sidecar: CookbookSidecarStore(fileURL: sidecarURL))
  }

  private func rawDocument(at url: URL) throws -> CookbookSidecarDocument {
    let store = CookbookSidecarStore(fileURL: url)
    return try store.load().document
  }

  private func corrupt(_ url: URL) throws {
    try Data("not json at all".utf8).write(to: url)
  }

  // MARK: - Sidecar store

  func testSidecarRoundTripsAndStampsCurrentVersion() throws {
    let url = makeSidecarURL()
    let store = CookbookSidecarStore(fileURL: url)
    var document = CookbookSidecarDocument()
    document.savedRecipes.append(
      CookbookSidecarDocument.SavedEntry(recipeId: 7, savedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    document.favorites = [7]
    document.collections.append(
      CookbookCollectionEntry(id: "c1", name: "Weeknights", createdAt: Date(), recipeIds: [7]))
    document.version = 99  // must be restamped on save

    try store.save(document)
    let loaded = try store.load()

    XCTAssertNil(loaded.recovery)
    XCTAssertEqual(loaded.document.version, CookbookSidecarDocument.currentVersion)
    XCTAssertEqual(loaded.document.savedRecipes, document.savedRecipes)
    XCTAssertEqual(loaded.document.favorites, [7])
    XCTAssertEqual(loaded.document.collections.first?.id, "c1")
    XCTAssertEqual(loaded.document.collections.first?.recipeIds, [7])
  }

  func testFirstLoadIsFreshNotRecovered() throws {
    let store = CookbookSidecarStore(fileURL: makeSidecarURL())
    let loaded = try store.load()
    XCTAssertNil(loaded.recovery)
    XCTAssertTrue(loaded.document.savedRecipes.isEmpty)
  }

  func testSidecarRecoversFromBackupWhenMainCorrupts() throws {
    let url = makeSidecarURL()
    let store = CookbookSidecarStore(fileURL: url)
    var document = CookbookSidecarDocument()
    document.savedRecipes.append(
      CookbookSidecarDocument.SavedEntry(recipeId: 3, savedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    try store.save(document)
    document.savedRecipes.append(
      CookbookSidecarDocument.SavedEntry(recipeId: 4, savedAt: Date(timeIntervalSince1970: 1_700_000_100)))
    try store.save(document)  // backup now holds the state with recipe 3 only

    try corrupt(url)
    let loaded = try store.load()

    XCTAssertEqual(loaded.recovery, .restoredFromBackup)
    XCTAssertEqual(loaded.document.savedRecipes.map { $0.recipeId }, [3])
  }

  func testSidecarResetsWhenMainAndBackupAreBothCorrupt() throws {
    let url = makeSidecarURL()
    let store = CookbookSidecarStore(fileURL: url)
    try store.save(CookbookSidecarDocument())
    try corrupt(url)
    try corrupt(url.appendingPathExtension("bak"))

    let loaded = try store.load()

    XCTAssertEqual(loaded.recovery, .resetAfterCorruption)
    XCTAssertTrue(loaded.document.savedRecipes.isEmpty)
    XCTAssertEqual(loaded.document.version, CookbookSidecarDocument.currentVersion)
  }

  func testSidecarRefusesFutureVersionsWithoutClobbering() throws {
    let url = makeSidecarURL()
    let store = CookbookSidecarStore(fileURL: url)
    let future =
      #"{"collections":[],"favorites":[],"savedRecipes":[],"version":99}"#
    try Data(future.utf8).write(to: url)

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? CookbookSidecarError, .unsupportedVersion(99))
    }
    let rawOnDisk = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(rawOnDisk.contains(#""version":99"#), "a future version must never be overwritten")
  }

  // MARK: - Save / Unsave

  func testSaveReferencesAnySourceIdempotentlyAndLeavesRowsUntouched() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let bundledId = try TestSupport.seedRecipe(db, title: "Bundled One", source: "bundled")
    let service = makeService(db, sidecarURL: makeSidecarURL())

    let joinsBefore = try TestSupport.count(db, "SELECT COUNT(*) FROM recipes")
    XCTAssertTrue(try service.save(recipeId: bundledId, savedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    XCTAssertFalse(try service.save(recipeId: bundledId), "saving twice is idempotent")
    XCTAssertTrue(try service.isSaved(recipeId: bundledId))
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), joinsBefore)

    let saved = try service.savedRecipes()
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.recipeId, bundledId)
    XCTAssertEqual(saved.first?.source, "bundled")
    XCTAssertEqual(
      saved.first?.savedAt.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
    XCTAssertFalse(saved.first?.isFavorite ?? true)
  }

  func testSaveOfMissingRecipeThrowsAndLeavesSidecarUntouched() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let sidecarURL = makeSidecarURL()
    let service = makeService(db, sidecarURL: sidecarURL)

    XCTAssertThrowsError(try service.save(recipeId: 999_999)) { error in
      XCTAssertEqual(error as? CookbookTransactionError, .recipeNotFound(999_999))
    }
    XCTAssertTrue(try rawDocument(at: sidecarURL).savedRecipes.isEmpty)
  }

  func testUnsaveClearsFavoritesAndMembershipsAndIsANoOpWhenUnsaved() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let recipeId = try TestSupport.seedRecipe(db, title: "Keeper", source: "user")
    let sidecarURL = makeSidecarURL()
    let service = makeService(db, sidecarURL: sidecarURL)
    XCTAssertTrue(try service.save(recipeId: recipeId))
    let collectionId = try service.createCollection(name: "Try soon")
    try service.setFavorite(recipeId: recipeId, true)
    try service.addToCollection(collectionId: collectionId, recipeId: recipeId)

    try service.unsave(recipeId: recipeId)
    try service.unsave(recipeId: recipeId)  // no-op the second time

    let document = try rawDocument(at: sidecarURL)
    XCTAssertTrue(document.savedRecipes.isEmpty)
    XCTAssertTrue(document.favorites.isEmpty)
    XCTAssertEqual(document.collections.count, 1, "unsave never deletes collections")
    XCTAssertTrue(document.collections[0].recipeIds.isEmpty)
    XCTAssertEqual(try service.recipeIds(inCollection: collectionId), [])
  }

  // MARK: - Favorites

  func testFavoriteRequiresASavedRecipeAndStaysOffTheJournal() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let recipeId = try TestSupport.seedRecipe(db, title: "Bundled Fav", source: "bundled")
    let sidecarURL = makeSidecarURL()
    let service = makeService(db, sidecarURL: sidecarURL)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO cooking_history (recipe_id, cooked_at, servings_consumed, rating)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [recipeId, Date(timeIntervalSince1970: 1_700_000_000), 1, 5])
    }
    let journalCount = try TestSupport.count(db, "SELECT COUNT(*) FROM cooking_history")

    XCTAssertThrowsError(try service.setFavorite(recipeId: recipeId, true)) { error in
      XCTAssertEqual(error as? CookbookSidecarError, .notSaved(recipeId))
    }
    XCTAssertTrue(try service.save(recipeId: recipeId))
    try service.setFavorite(recipeId: recipeId, true)
    XCTAssertTrue(try service.savedRecipes().first?.isFavorite ?? false)
    try service.setFavorite(recipeId: recipeId, false)
    XCTAssertFalse(try service.savedRecipes().first?.isFavorite ?? true)

    // The journal is untouched: same row count, rating still 5. RecipeBookView's
    // Favorites filter remains rating semantics, not sidecar semantics.
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM cooking_history"), journalCount)
    let rating = try db.read { db in
      try Int.fetchOne(db, sql: "SELECT MAX(rating) FROM cooking_history")
    }
    XCTAssertEqual(rating, 5)
  }

  // MARK: - Collections

  func testCollectionLifecycleMembershipAndRowProtection() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let first = try TestSupport.seedRecipe(db, title: "First", source: "user")
    let second = try TestSupport.seedRecipe(db, title: "Second", source: "bundled")
    let sidecarURL = makeSidecarURL()
    let service = makeService(db, sidecarURL: sidecarURL)
    XCTAssertTrue(try service.save(recipeId: first))
    XCTAssertTrue(try service.save(recipeId: second))
    let recipeCountBefore = try TestSupport.count(db, "SELECT COUNT(*) FROM recipes")

    let collectionId = try service.createCollection(name: "  Weeknights  ")
    try service.renameCollection(id: collectionId, to: "After Work")
    try service.addToCollection(collectionId: collectionId, recipeId: first)
    try service.addToCollection(collectionId: collectionId, recipeId: second)
    XCTAssertThrowsError(
      try service.addToCollection(collectionId: collectionId, recipeId: first)
    ) { error in
      XCTAssertEqual(error as? CookbookSidecarError, .alreadyInCollection)
    }
    XCTAssertEqual(try service.recipeIds(inCollection: collectionId), [first, second])

    try service.removeFromCollection(collectionId: collectionId, recipeId: second)
    let remainingIds: [Int64] = try service.recipeIds(inCollection: collectionId)
    XCTAssertEqual(remainingIds, [first])

    try service.deleteCollection(id: collectionId)
    XCTAssertTrue(try service.collections().isEmpty)
    XCTAssertTrue(try service.isSaved(recipeId: first), "deleting a collection never unsaves")
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), recipeCountBefore)

    XCTAssertThrowsError(try service.recipeIds(inCollection: collectionId)) { error in
      XCTAssertEqual(
        error as? CookbookSidecarError, .collectionNotFound(collectionId))
    }
  }

  func testCollectionNamesAreTrimmedAndBounded() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let service = makeService(db, sidecarURL: makeSidecarURL())

    XCTAssertThrowsError(try service.createCollection(name: "   ")) { error in
      XCTAssertEqual(error as? CookbookSidecarError, .invalidCollectionName)
    }
    XCTAssertThrowsError(
      try service.createCollection(name: String(repeating: "x", count: 81))
    ) { error in
      XCTAssertEqual(error as? CookbookSidecarError, .invalidCollectionName)
    }
    let id = try service.createCollection(name: String(repeating: "x", count: 80))
    XCTAssertEqual(try service.collections().first?.name.count, 80)
    XCTAssertEqual(try service.collections().first?.id, id)
  }

  // MARK: - Relaunch and refresh non-interference

  func testRelaunchRetainsLibraryStateFromFiles() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let recipeId = try TestSupport.seedRecipe(db, title: "Durable", source: "user")
    let sidecarURL = makeSidecarURL()

    let first = makeService(db, sidecarURL: sidecarURL)
    XCTAssertTrue(try first.save(recipeId: recipeId))
    let collectionId = try first.createCollection(name: "Keeper")
    try first.addToCollection(collectionId: collectionId, recipeId: recipeId)

    // A fresh service instance over the same files is a relaunch.
    let second = makeService(db, sidecarURL: sidecarURL)
    XCTAssertTrue(try second.isSaved(recipeId: recipeId))
    XCTAssertEqual(try second.recipeIds(inCollection: collectionId), [recipeId])
    XCTAssertEqual(try second.savedRecipes().first?.title, "Durable")
  }

  func testRefreshStyleRowRewriteDoesNotDisturbSidecarState() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let bundledId = try TestSupport.seedRecipe(db, title: "Before Refresh", source: "bundled")
    let sidecarURL = makeSidecarURL()
    let service = makeService(db, sidecarURL: sidecarURL)
    XCTAssertTrue(try service.save(recipeId: bundledId))
    let collectionId = try service.createCollection(name: "Saved catalog")
    try service.addToCollection(collectionId: collectionId, recipeId: bundledId)

    // Simulate a bundled refresh rewriting the catalog row in place.
    try db.write { db in
      try db.execute(
        sql: "UPDATE recipes SET title = ? WHERE id = ?",
        arguments: ["After Refresh", bundledId])
    }

    let document = try rawDocument(at: sidecarURL)
    XCTAssertEqual(document.savedRecipes.map { $0.recipeId }, [bundledId])
    XCTAssertEqual(document.collections.first?.recipeIds, [bundledId])
    XCTAssertEqual(try service.savedRecipes().first?.title, "After Refresh")
  }

  func testDeadReferenceDropsFromListingsButStaysInSidecar() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let transaction = UserRecipeTransactionService(db: db)
    let recipeId = try transaction.createUserRecipe(
      TestDrafts.validDraft(eggId: egg, riceId: rice))
    let sidecarURL = makeSidecarURL()
    let service = makeService(db, sidecarURL: sidecarURL)
    XCTAssertTrue(try service.save(recipeId: recipeId))

    try transaction.deleteUncookedUserRecipe(recipeId: recipeId)

    XCTAssertTrue(try service.savedRecipes().isEmpty, "a vanished recipe drops from listings")
    XCTAssertEqual(
      try rawDocument(at: sidecarURL).savedRecipes.map { $0.recipeId },
      [recipeId],
      "the sidecar is not pruned behind the user's back")
  }
}
