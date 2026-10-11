import Foundation

/// Versioned document backing the personal cookbook sidecar file.
///
/// Recipe content never lives here: the sidecar stores references by recipe
/// id plus the save/favorite/collection metadata, so a bundled refresh that
/// rewrites catalog rows cannot collide with library state, and deleting a
/// recipe row leaves the sidecar free to keep or drop the reference.
struct CookbookSidecarDocument: Codable, Equatable, Sendable {
  /// Current document version. Bump when the schema changes; older versions
  /// are migrated on load, newer ones are refused rather than clobbered.
  static let currentVersion = 1

  var version: Int = CookbookSidecarDocument.currentVersion

  /// Saved recipes, most recently added last. References only — ids plus
  /// when the save happened and an optional user note.
  var savedRecipes: [SavedEntry] = []

  /// Sidecar favorites. Deliberately separate from cooking-history ratings:
  /// RecipeBookView's Favorites filter (rating >= 4) stays journal semantics.
  var favorites: [Int64] = []

  /// Ordered collections with ordered membership.
  var collections: [CookbookCollectionEntry] = []

  /// Soft-archived user recipe ids. Archive hides a recipe from the library
  /// without touching its row, joins, or cooking history; the flag rides the
  /// sidecar because the shared schema is out of this feature's scope.
  var archivedRecipeIds: [Int64] = []

  private enum CodingKeys: String, CodingKey {
    case version, savedRecipes, favorites, collections, archivedRecipeIds
  }

  init() {}

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version)
      ?? CookbookSidecarDocument.currentVersion
    savedRecipes = try container.decode([SavedEntry].self, forKey: .savedRecipes)
    favorites = try container.decode([Int64].self, forKey: .favorites)
    collections = try container.decode([CookbookCollectionEntry].self, forKey: .collections)
    // Written by later builds within v1; older v1 documents decode to empty.
    archivedRecipeIds = try container.decodeIfPresent([Int64].self, forKey: .archivedRecipeIds) ?? []
  }

  /// Marks a recipe archived. Idempotent.
  mutating func archiveRecipe(_ recipeId: Int64) {
    if !archivedRecipeIds.contains(recipeId) {
      archivedRecipeIds.append(recipeId)
    }
  }

  /// Clears a recipe's archive flag. Safe to call when it was never set.
  mutating func unarchiveRecipe(_ recipeId: Int64) {
    archivedRecipeIds.removeAll { $0 == recipeId }
  }

  func isArchived(_ recipeId: Int64) -> Bool {
    archivedRecipeIds.contains(recipeId)
  }

  struct SavedEntry: Codable, Equatable, Sendable {
    var recipeId: Int64
    var savedAt: Date
    var note: String?

    init(recipeId: Int64, savedAt: Date, note: String? = nil) {
      self.recipeId = recipeId
      self.savedAt = savedAt
      self.note = note
    }

    private enum CodingKeys: String, CodingKey {
      case recipeId = "recipe_id", savedAt = "saved_at", note
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      recipeId = try container.decode(Int64.self, forKey: .recipeId)
      savedAt = try container.decode(Date.self, forKey: .savedAt)
      note = try container.decodeIfPresent(String.self, forKey: .note)
    }
  }
}

/// Ordered collection of saved-recipe references.
struct CookbookCollectionEntry: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var createdAt: Date
  var recipeIds: [Int64] = []

  init(id: String, name: String, createdAt: Date, recipeIds: [Int64] = []) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.recipeIds = recipeIds
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, createdAt = "created_at", recipeIds = "recipe_ids"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    recipeIds = try container.decode([Int64].self, forKey: .recipeIds)
  }
}

/// Sidecar failure modes the library and UI can act on.
enum CookbookSidecarError: Error, Equatable, Sendable {
  /// The file on disk was written by a newer app version. Never overwrite it.
  case unsupportedVersion(Int)
  /// Blank or oversized collection name.
  case invalidCollectionName
  /// No saved entry for the referenced recipe.
  case notSaved(Int64)
  /// The referenced collection does not exist (may have been deleted).
  case collectionNotFound(String)
  /// The recipe is already a member of the collection.
  case alreadyInCollection
}
