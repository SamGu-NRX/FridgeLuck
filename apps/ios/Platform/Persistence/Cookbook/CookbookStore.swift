import Foundation
import FLFeatureLogic
import GRDB

/// A recipe row joined with how many times it has been cooked.
///
/// `cookedCount` is read-only display data from the cooking journal — the
/// cookbook never writes `cooking_history`. This is what keeps a library record
/// distinct from a journal correction: the journal owns what was cooked, the
/// cookbook owns what the user keeps.
struct CookbookRecipeSummary: Sendable {
  let recipe: Recipe
  let cookedCount: Int

  init(recipe: Recipe, cookedCount: Int) {
    self.recipe = recipe
    self.cookedCount = cookedCount
  }
}

/// Read-model store for user-authored cookbook recipes.
///
/// Owns its own narrow queries rather than widening `RecipeRepository` — the
/// repository's shared queries are load-bearing for recommendation ranking and
/// must not drift for a feature-local need. All queries here filter
/// `source = 'user'`, which is both the cookbook identity and the structural
/// guarantee the bundled refresh relies on (every refresh query filters
/// `source = 'bundled'`).
final class CookbookStore: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// All user-authored recipes with the newest first.
  func listUserRecipes() throws -> [CookbookRecipeSummary] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT * FROM recipes WHERE source = 'user' ORDER BY created_at DESC, id DESC")
      return try rows.map { row in
        CookbookRecipeSummary(
          recipe: Self.recipe(from: row),
          cookedCount: try Self.cookedCount(for: row["id"], in: db))
      }
    }
  }

  /// One user recipe by id, or nil when the id does not exist or is not
  /// user-authored (a library view never presents catalog rows as editable).
  func fetchUserRecipe(id: Int64) throws -> CookbookRecipeSummary? {
    try db.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM recipes WHERE id = ? AND source = 'user'", arguments: [id])
      else { return nil }
      return CookbookRecipeSummary(
        recipe: Self.recipe(from: row),
        cookedCount: try Self.cookedCount(for: id, in: db))
    }
  }

  /// Ingredient lines of a user recipe, required lines first (the join table's
    /// presentation order elsewhere in the app).
  func ingredientsForUserRecipe(id: Int64) throws -> [RecipeIngredient] {
    try db.read { db in
      try RecipeIngredient.fetchAll(
        db,
        sql: """
          SELECT recipe_id, ingredient_id, is_required, quantity_grams, display_quantity
          FROM recipe_ingredients
          WHERE recipe_id = ?
          ORDER BY is_required DESC, ingredient_id ASC
          """,
        arguments: [id])
    }
  }

  /// Whether cooking history references this recipe. Used by the editor to
  /// decide delete-vs-archive before `UserRecipeTransactionService` enforces it.
  func hasCookingHistory(recipeId: Int64) throws -> Bool {
    try db.read { db in
      let count = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = ?",
        arguments: [recipeId]) ?? 0
      return count > 0
    }
  }

  // MARK: - Row mapping

  private static func recipe(from row: Row) -> Recipe {
    Recipe(
      id: row["id"],
      title: row["title"],
      timeMinutes: row["time_minutes"],
      servings: row["servings"],
      instructions: row["instructions"],
      tags: row["tags"] ?? 0,
      source: .user,
      createdAt: row["created_at"] as? Date
    )
  }

  /// Read-only count from the journal's table; the cookbook never writes here.
  private static func cookedCount(for recipeId: Int64, in db: Database) throws -> Int {
    try Int.fetchOne(
      db, sql: "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = ?", arguments: [recipeId])
      ?? 0
  }
}
