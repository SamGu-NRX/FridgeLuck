import Foundation
import FLFeatureLogic
import GRDB

/// Errors the user-recipe transaction service raises instead of guessing.
/// Every case is actionable: the editor maps them onto validation messages or
/// a retry, and none of them loses the user's draft.
enum CookbookTransactionError: Error, Sendable, Equatable {
  /// The draft failed `CookbookRecipePolicy`. The draft stays intact for retry.
  case validation([CookbookValidationProblem])
  /// The draft's ingredient lines reference ids missing from the catalog
  /// (`ingredients` table). Recipes are catalog-bound; free-text ingredients
  /// would break macros, inventory deduction, and the recommendation joins.
  case unknownIngredients([Int64])
  case recipeNotFound(Int64)
  /// The targeted row is not user-authored. The cookbook never rewrites
  /// bundled or AI-generated catalog rows through the editor.
  case notUserRecipe(Int64)
  /// The user recipe already has cooking history. History rows point at the
  /// recipe id, so it may be archived (kept) but not deleted.
  case recipeHasCookingHistory(Int64)
}

/// Dedicated transaction service for user-authored cookbook recipes.
///
/// Mirrors the composition discipline of `MealLogService`: every operation that
/// touches more than one table runs inside a single `db.write` transaction, so a
/// recipe row and its `recipe_ingredients` joins are saved together or not at all.
///
/// Writes go to the EXISTING `recipes` / `recipe_ingredients` tables — no new
/// tables, no migration. Two invariants make this safe next to the bundled
/// ownership refresh:
///
/// 1. Every row this service creates or edits carries `source = 'user'`. The
///    refresher's adoption, update, and same-title-block queries all filter
///    `source = 'bundled'`, so a user recipe is invisible to the refresh engine:
///    never adopted, never updated, never deleted.
/// 2. Edits update the row in place (the id is preserved). Cooking history rows
///    and journal observations keep pointing at the same meal; the per-log
///    snapshot fields history stores (servings, portion, swaps, rating, photo)
///    are never touched here.
final class UserRecipeTransactionService: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  // MARK: - Create

  /// Inserts the draft as a new user-authored recipe with its ingredient joins,
  /// atomically. Returns the new recipe id.
  @discardableResult
  func createUserRecipe(_ draft: CookbookRecipeDraft, createdAt: Date = Date()) throws
    -> Int64
  {
    let problems = CookbookRecipePolicy.validate(draft)
    guard problems.isEmpty else { throw CookbookTransactionError.validation(problems) }

    return try db.write { db in
      try Self.assertIngredientsExist(in: db, lines: draft.ingredientLines)
      let recipeId = try Self.insertRecipeRow(in: db, draft: draft, createdAt: createdAt)
      try Self.insertJoins(in: db, recipeId: recipeId, lines: draft.ingredientLines)
      return recipeId
    }
  }

  // MARK: - Update

  /// Rewrites an existing user recipe in place: the recipe id is preserved so
  /// cooking history and any sidecar metadata keep their anchor. The join set
  /// is replaced in the same transaction as the row update.
  func updateUserRecipe(recipeId: Int64, _ draft: CookbookRecipeDraft) throws {
    let problems = CookbookRecipePolicy.validate(draft)
    guard problems.isEmpty else { throw CookbookTransactionError.validation(problems) }

    try db.write { db in
      guard let source: String = try String.fetchOne(
        db, sql: "SELECT source FROM recipes WHERE id = ?", arguments: [recipeId])
      else {
        throw CookbookTransactionError.recipeNotFound(recipeId)
      }
      guard source == CookbookIdentity.userSourceRawValue else {
        throw CookbookTransactionError.notUserRecipe(recipeId)
      }
      try Self.assertIngredientsExist(in: db, lines: draft.ingredientLines)

      try db.execute(
        sql: """
          UPDATE recipes
          SET title = :title, time_minutes = :time, servings = :servings,
              instructions = :instructions, tags = :tags
          WHERE id = :id
          """,
        arguments: [
          "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
          "time": draft.timeMinutes,
          "servings": draft.servings,
          "instructions": draft.instructions,
          "tags": draft.tagMask,
          "id": recipeId,
        ])
      try db.execute(
        sql: "DELETE FROM recipe_ingredients WHERE recipe_id = ?", arguments: [recipeId])
      try Self.insertJoins(in: db, recipeId: recipeId, lines: draft.ingredientLines)
    }
  }

  // MARK: - Duplicate

  /// Copies any recipe (user or catalog) into a NEW user-authored row with the
  /// same joins. This is how a bundled recipe becomes editable as the user's
  /// own without mutating shared catalog content.
  @discardableResult
  func duplicateUserRecipe(recipeId: Int64, createdAt: Date = Date()) throws -> Int64 {
    try db.write { db in
      guard let row: Row = try Row.fetchOne(
        db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [recipeId])
      else {
        throw CookbookTransactionError.recipeNotFound(recipeId)
      }

      let title: String = row["title"]
      let copyTitle =
        "\(title) (copy)".trimmingCharacters(in: .whitespacesAndNewlines)
      let draft = CookbookRecipeDraft(
        title: copyTitle,
        timeMinutes: row["time_minutes"] ?? CookbookRecipePolicy.minTimeMinutes,
        servings: row["servings"] ?? CookbookRecipePolicy.minServings,
        instructions: row["instructions"] ?? "",
        tagMask: row["tags"] ?? 0,
        ingredientLines: []
      )

      let newId = try Self.insertRecipeRow(in: db, draft: draft, createdAt: createdAt)
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          SELECT :newId, ingredient_id, is_required, quantity_grams, display_quantity
          FROM recipe_ingredients
          WHERE recipe_id = :oldId
          """,
        arguments: ["newId": newId, "oldId": recipeId])
      return newId
    }
  }

  // MARK: - Delete (never-cooked only)

  /// Deletes a user recipe that has never been cooked. If cooking history
  /// references it, the row is protected — history entries would lose their
  /// meal — and the caller archives instead.
  func deleteUncookedUserRecipe(recipeId: Int64) throws {
    try db.write { db in
      guard let source: String = try String.fetchOne(
        db, sql: "SELECT source FROM recipes WHERE id = ?", arguments: [recipeId])
      else {
        throw CookbookTransactionError.recipeNotFound(recipeId)
      }
      guard source == CookbookIdentity.userSourceRawValue else {
        throw CookbookTransactionError.notUserRecipe(recipeId)
      }
      let historyCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = ?",
        arguments: [recipeId]) ?? 0
      guard historyCount == 0 else {
        throw CookbookTransactionError.recipeHasCookingHistory(recipeId)
      }
      // Joins cascade by foreign key; the explicit delete keeps intent legible.
      try db.execute(
        sql: "DELETE FROM recipe_ingredients WHERE recipe_id = ?", arguments: [recipeId])
      try db.execute(sql: "DELETE FROM recipes WHERE id = ?", arguments: [recipeId])
    }
  }

  // MARK: - Transaction helpers

  /// Catalog binding: every referenced ingredient must exist. Checked inside the
  /// transaction so the check and the write see the same catalog state.
  static func assertIngredientsExist(in db: Database, lines: [CookbookIngredientLine]) throws {
    let ids = lines.map(\.ingredientId)
    guard !ids.isEmpty else { return }
    let placeholders = ids.map { _ in "?" }.joined(separator: ",")
    let found = try Int64.fetchAll(
      db, sql: "SELECT id FROM ingredients WHERE id IN (\(placeholders))",
      arguments: StatementArguments(ids))
    let foundSet = Set(found)
    let missing = ids.filter { !foundSet.contains($0) }
    if !missing.isEmpty {
      throw CookbookTransactionError.unknownIngredients(missing.sorted())
    }
  }

  private static func insertRecipeRow(in db: Database, draft: CookbookRecipeDraft, createdAt: Date)
    throws -> Int64
  {
    try db.execute(
      sql: """
        INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source, created_at)
        VALUES (:title, :time, :servings, :instructions, :tags, :source, :createdAt)
        """,
      arguments: [
        "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
        "time": draft.timeMinutes,
        "servings": draft.servings,
        "instructions": draft.instructions,
        "tags": draft.tagMask,
        "source": CookbookIdentity.userSourceRawValue,
        "createdAt": createdAt,
      ])
    return db.lastInsertedRowID
  }

  private static func insertJoins(in db: Database, recipeId: Int64, lines: [CookbookIngredientLine])
    throws
  {
    for line in lines {
      let display = line.displayQuantity ?? "\(Int(line.grams))g"
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [recipeId, line.ingredientId, line.isRequired, line.grams, display])
    }
  }
}
