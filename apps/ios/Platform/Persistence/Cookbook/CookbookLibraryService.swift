import Foundation
import GRDB

/// Display-facing read model for a saved recipe. `source` carries provenance
/// so the library can show where each entry came from; saving never rewrites
/// the underlying recipe row.
struct CookbookSavedSummary: Sendable, Equatable {
  var recipeId: Int64
  var title: String
  var timeMinutes: Int
  var servings: Int
  var source: String
  var savedAt: Date
  var isFavorite: Bool
  var collectionIds: [String]
}

/// Display-facing read model for a collection with its live membership count.
struct CookbookCollectionSummary: Sendable, Equatable {
  var id: String
  var name: String
  var createdAt: Date
  var recipeCount: Int
}

/// Domain operations for the personal cookbook library: save/unsave,
/// favorites, and collections.
///
/// Two hard boundaries:
/// - Recipe content lives only in the database. The sidecar references
///   recipes by id and is the ONLY place save/favorite/collection metadata
///   exists; saving never copies or rewrites a recipe row.
/// - Cooking-history ratings are untouched. RecipeBookView's Favorites filter
///   (rating >= 4) stays journal semantics; the sidecar favorite is separate.
///
/// Reads join sidecar references against live recipe rows, so entries whose
/// recipe vanished (e.g. a deleted user recipe) drop out of listings without
/// the sidecar being rewritten behind the user's back.
final class CookbookLibraryService: Sendable {
  /// Collection names are trimmed; beyond this they are rejected.
  static let maxCollectionNameLength = 80

  private let db: any DatabaseReader
  private let sidecar: CookbookSidecarStore

  init(db: any DatabaseReader, sidecar: CookbookSidecarStore) {
    self.db = db
    self.sidecar = sidecar
  }

  // MARK: - Save / Unsave

  /// Saves any existing recipe (bundled, user, or AI) into the cookbook.
  /// Saving a catalog recipe takes a reference, never a copy: if the catalog
  /// row is later refreshed or adopted, the save still points at the same id.
  @discardableResult
  func save(recipeId: Int64, savedAt: Date = Date(), note: String? = nil) throws -> Bool {
    try assertRecipeExists(recipeId)
    var document = try current()
    guard !document.savedRecipes.contains(where: { $0.recipeId == recipeId }) else {
      return false  // already saved; saving is idempotent
    }
    document.savedRecipes.append(
      CookbookSidecarDocument.SavedEntry(recipeId: recipeId, savedAt: savedAt, note: note))
    try sidecar.save(document)
    return true
  }

  /// Removes a save and its collection memberships. Unsaving never deletes a
  /// recipe; unsaving an unsaved recipe is a no-op.
  func unsave(recipeId: Int64) throws {
    var document = try current()
    document.savedRecipes.removeAll { $0.recipeId == recipeId }
    document.favorites.removeAll { $0 == recipeId }
    for index in document.collections.indices {
      document.collections[index].recipeIds.removeAll { $0 == recipeId }
    }
    try sidecar.save(document)
  }

  func isSaved(recipeId: Int64) throws -> Bool {
    try current().savedRecipes.contains { $0.recipeId == recipeId }
  }

  // MARK: - Favorites (sidecar-scoped, separate from journal ratings)

  func setFavorite(recipeId: Int64, _ isFavorite: Bool) throws {
    var document = try current()
    guard document.savedRecipes.contains(where: { $0.recipeId == recipeId }) else {
      throw CookbookSidecarError.notSaved(recipeId)
    }
    if isFavorite {
      if !document.favorites.contains(recipeId) {
        document.favorites.append(recipeId)
      }
    } else {
      document.favorites.removeAll { $0 == recipeId }
    }
    try sidecar.save(document)
  }

  // MARK: - Collections

  @discardableResult
  func createCollection(name: String, createdAt: Date = Date()) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= Self.maxCollectionNameLength else {
      throw CookbookSidecarError.invalidCollectionName
    }
    var document = try current()
    let id = UUID().uuidString
    document.collections.append(
      CookbookCollectionEntry(id: id, name: trimmed, createdAt: createdAt))
    try sidecar.save(document)
    return id
  }

  func renameCollection(id: String, to name: String) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= Self.maxCollectionNameLength else {
      throw CookbookSidecarError.invalidCollectionName
    }
    var document = try current()
    guard let index = document.collections.firstIndex(where: { $0.id == id }) else {
      throw CookbookSidecarError.collectionNotFound(id)
    }
    document.collections[index].name = trimmed
    try sidecar.save(document)
  }

  /// Deletes a collection only. Membership disappears; the saved recipes stay
  /// saved.
  func deleteCollection(id: String) throws {
    var document = try current()
    guard document.collections.contains(where: { $0.id == id }) else {
      throw CookbookSidecarError.collectionNotFound(id)
    }
    document.collections.removeAll { $0.id == id }
    try sidecar.save(document)
  }

  func addToCollection(collectionId: String, recipeId: Int64) throws {
    var document = try current()
    guard document.savedRecipes.contains(where: { $0.recipeId == recipeId }) else {
      throw CookbookSidecarError.notSaved(recipeId)
    }
    guard let index = document.collections.firstIndex(where: { $0.id == collectionId }) else {
      throw CookbookSidecarError.collectionNotFound(collectionId)
    }
    guard !document.collections[index].recipeIds.contains(recipeId) else {
      throw CookbookSidecarError.alreadyInCollection
    }
    document.collections[index].recipeIds.append(recipeId)
    try sidecar.save(document)
  }

  func removeFromCollection(collectionId: String, recipeId: Int64) throws {
    var document = try current()
    guard let index = document.collections.firstIndex(where: { $0.id == collectionId }) else {
      throw CookbookSidecarError.collectionNotFound(collectionId)
    }
    document.collections[index].recipeIds.removeAll { $0 == recipeId }
    try sidecar.save(document)
  }

  // MARK: - Read models

  /// Saved recipes, most recently saved first, joined against live recipe
  /// rows. References whose recipe row no longer exists are omitted (the
  /// sidecar is not pruned: a restore or re-import can make them visible
  /// again).
  func savedRecipes() throws -> [CookbookSavedSummary] {
    let document = try current()
    var summaries: [CookbookSavedSummary] = []
    for entry in document.savedRecipes.sorted(by: { $0.savedAt > $1.savedAt }) {
      let row = try db.read { db in
        try Row.fetchOne(
          db, sql: "SELECT title, time_minutes, servings, source FROM recipes WHERE id = ?",
          arguments: [entry.recipeId])
      }
      guard let row else { continue }
      summaries.append(
        CookbookSavedSummary(
          recipeId: entry.recipeId,
          title: row["title"],
          timeMinutes: row["time_minutes"],
          servings: row["servings"],
          source: row["source"],
          savedAt: entry.savedAt,
          isFavorite: document.favorites.contains(entry.recipeId),
          collectionIds: document.collections
            .filter { $0.recipeIds.contains(entry.recipeId) }
            .map { $0.id }))
    }
    return summaries
  }

  func collections() throws -> [CookbookCollectionSummary] {
    try current().collections.map {
      CookbookCollectionSummary(
        id: $0.id, name: $0.name, createdAt: $0.createdAt, recipeCount: $0.recipeIds.count)
    }
  }

  /// Ordered recipe ids of a collection, dropping ids whose recipe row no
  /// longer exists.
  func recipeIds(inCollection collectionId: String) throws -> [Int64] {
    let document = try current()
    guard let collection = document.collections.first(where: { $0.id == collectionId }) else {
      throw CookbookSidecarError.collectionNotFound(collectionId)
    }
    return try collection.recipeIds.filter { id in
      try db.read { db in
        try Row.fetchOne(
          db, sql: "SELECT 1 FROM recipes WHERE id = ?", arguments: [id]) != nil
      }
    }
  }

  // MARK: - Internals

  private func current() throws -> CookbookSidecarDocument {
    try sidecar.load().document
  }

  private func assertRecipeExists(_ recipeId: Int64) throws {
    let exists = try db.read { db in
      try Row.fetchOne(db, sql: "SELECT 1 FROM recipes WHERE id = ?", arguments: [recipeId]) != nil
    }
    guard exists else {
      throw CookbookTransactionError.recipeNotFound(recipeId)
    }
  }
}
