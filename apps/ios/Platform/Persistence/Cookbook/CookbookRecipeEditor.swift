import Foundation
import FLFeatureLogic
import GRDB

/// Editor session for authoring or editing one user recipe.
///
/// Sits in front of `UserRecipeTransactionService` and the library sidecar:
///
/// - Validation-first saves. `CookbookRecipePolicy.validate` runs before any
///   write, so every problem is reported in one pass. A failed save mutates
///   nothing — the caller keeps their draft and can retry with corrections.
/// - Edits write atomically, keep recipe identity, and preserve
///   `source = 'user'`; already-logged cooking history is never rewritten.
/// - Archive is soft. The flag lives in the versioned sidecar, so the row,
///   its joins, and any logged meals stay untouched. Discard is the hard
///   path and is refused for cooked recipes — archive instead.
/// - Nutrition is never guessed. The editor persists exactly the fields the
///   user entered; per-ingredient macros remain read-time math.
final class CookbookRecipeEditor {
  private let db: DatabaseQueue
  private let transactions: UserRecipeTransactionService
  private let store: CookbookStore
  private let sidecar: CookbookSidecarStore

  /// The recipe being edited, if any. `nil` means the next save creates one.
  private(set) var editingRecipeId: Int64?

  init(db: DatabaseQueue, sidecar: CookbookSidecarStore) {
    self.db = db
    self.transactions = UserRecipeTransactionService(db: db)
    self.store = CookbookStore(db: db)
    self.sidecar = sidecar
  }

  /// A blank draft for authoring a new recipe. Deliberately invalid until
  /// filled in — nothing is pre-filled on the user's behalf.
  func newDraft() -> CookbookRecipeDraft {
    CookbookRecipeDraft(title: "", timeMinutes: 0, servings: 1, instructions: "")
  }

  /// Loads a user recipe's current values into an editable draft and aims the
  /// editor at it. Bundled and AI rows are refused: only the user's own
  /// recipes are editable.
  func loadForEditing(recipeId: Int64) throws -> CookbookRecipeDraft {
    guard let summary = try store.fetchUserRecipe(id: recipeId) else {
      // Distinguish a missing row from a row the editor may not touch.
      guard try rowExists(recipeId) else {
        throw CookbookTransactionError.recipeNotFound(recipeId)
      }
      throw CookbookTransactionError.notUserRecipe(recipeId)
    }
    let recipe = summary.recipe
    let lines = try store.ingredientsForUserRecipe(id: recipeId).map { join in
      CookbookIngredientLine(
        ingredientId: join.ingredientId,
        grams: join.quantityGrams,
        isRequired: join.isRequired,
        displayQuantity: join.displayQuantity.isEmpty ? nil : join.displayQuantity
      )
    }
    editingRecipeId = recipeId
    return CookbookRecipeDraft(
      title: recipe.title,
      timeMinutes: recipe.timeMinutes,
      servings: recipe.servings,
      instructions: recipe.instructions,
      tagMask: recipe.tags,
      ingredientLines: lines
    )
  }

  /// Clears the editing target so the next save creates a new recipe.
  func startCreating() {
    editingRecipeId = nil
  }

  /// Validates first (reporting every problem at once), then writes
  /// atomically: create when not editing, in-place update otherwise. On
  /// failure the editor's state is unchanged — retrying with a corrected
  /// draft is always safe.
  @discardableResult
  func save(_ draft: CookbookRecipeDraft) throws -> Int64 {
    let problems = CookbookRecipePolicy.validate(draft)
    guard problems.isEmpty else {
      throw CookbookTransactionError.validation(problems)
    }
    if let recipeId = editingRecipeId {
      try transactions.updateUserRecipe(recipeId: recipeId, draft)
      return recipeId
    }
    let newId = try transactions.createUserRecipe(draft)
    editingRecipeId = newId
    return newId
  }

  /// Duplicates a user recipe into a fresh editable copy and aims the editor
  /// at it. The original is untouched.
  @discardableResult
  func duplicate(recipeId: Int64) throws -> Int64 {
    let newId = try transactions.duplicateUserRecipe(recipeId: recipeId)
    editingRecipeId = newId
    return newId
  }

  /// Soft-archives a user recipe: sidecar flag only. The row, its ingredient
  /// joins, and any cooking history are untouched, so a logged meal never
  /// loses its recipe. Bundled and AI rows are refused. Idempotent.
  func archive(recipeId: Int64) throws {
    try assertUserRow(recipeId)
    try mutateSidecar { $0.archiveRecipe(recipeId) }
  }

  /// Clears a recipe's archive flag. Safe to call when it was never set.
  func unarchive(recipeId: Int64) throws {
    try assertUserRow(recipeId)
    try mutateSidecar { $0.unarchiveRecipe(recipeId) }
  }

  /// Whether the recipe is currently soft-archived.
  func isArchived(recipeId: Int64) throws -> Bool {
    try sidecar.load().document.isArchived(recipeId)
  }

  /// Hard-deletes a user recipe that has never been cooked. Recipes with
  /// cooking history are refused — archive keeps those out of the library
  /// without orphaning a logged meal.
  func discard(recipeId: Int64) throws {
    try transactions.deleteUncookedUserRecipe(recipeId: recipeId)
    if editingRecipeId == recipeId {
      editingRecipeId = nil
    }
  }

  // MARK: - Helpers

  private func rowExists(_ recipeId: Int64) throws -> Bool {
    try db.read { db in
      try Row.fetchOne(
        db, sql: "SELECT 1 FROM recipes WHERE id = ?", arguments: [recipeId]
      ) != nil
    }
  }

  private func assertUserRow(_ recipeId: Int64) throws {
    guard let summary = try store.fetchUserRecipe(id: recipeId) else {
      guard try rowExists(recipeId) else {
        throw CookbookTransactionError.recipeNotFound(recipeId)
      }
      throw CookbookTransactionError.notUserRecipe(recipeId)
    }
    _ = summary
  }

  private func mutateSidecar(
    _ change: (inout CookbookSidecarDocument) -> Void
  ) throws {
    var document = try sidecar.load().document
    change(&document)
    try sidecar.save(document)
  }
}
