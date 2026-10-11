import GRDB
import XCTest

@testable import CookbookFlowCheck
@testable import FLFeatureLogic

/// Storage-contract checks for user-authored cookbook recipes, run against the
/// REAL migrations, REAL services, and — for the anti-theft proof — the REAL
/// bundled ownership refresh.
final class UserRecipeTransactionTests: XCTestCase {
  // MARK: - Create

  func testCreateWritesUserProvenanceAndJoinsAtomically() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let service = UserRecipeTransactionService(db: db)
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

    let id = try service.createUserRecipe(
      TestDrafts.validDraft(eggId: egg, riceId: rice), createdAt: createdAt)

    let row = try db.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [id])
    }
    let recipe = try XCTUnwrap(row)
    let actual_source_1: String = recipe["source"]
    XCTAssertEqual(actual_source_1, "user")
    let actual_title_2: String = recipe["title"]
    XCTAssertEqual(actual_title_2, "Sunday Eggs")
    let actual_time_minutes_3: Int = recipe["time_minutes"]
    XCTAssertEqual(actual_time_minutes_3, 12)
    let actual_servings_4: Int = recipe["servings"]
    XCTAssertEqual(actual_servings_4, 2)
    // Ownership columns stay NULL on user rows: nothing for the refresh to claim.
    XCTAssertNil(recipe["ownership_key"])
    XCTAssertNil(recipe["bundle_content_hash"])
    let storedCreatedAt: Date = recipe["created_at"]
    XCTAssertEqual(storedCreatedAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 1)

    let joins = try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM recipe_ingredients WHERE recipe_id = ? ORDER BY ingredient_id",
        arguments: [id])
    }
    XCTAssertEqual(joins.count, 2)
    let eggJoin = try XCTUnwrap(joins.first { $0["ingredient_id"] as? Int64 == egg })
    let eggRequired: Bool = eggJoin["is_required"]
    XCTAssertTrue(eggRequired)
    let actual_quantity_grams_5: Double = eggJoin["quantity_grams"]
    XCTAssertEqual(actual_quantity_grams_5, 120)
    let actual_display_quantity_6: String = eggJoin["display_quantity"]
    XCTAssertEqual(actual_display_quantity_6, "120g")
    let riceJoin = try XCTUnwrap(joins.first { $0["ingredient_id"] as? Int64 == rice })
    let riceRequired: Bool = riceJoin["is_required"]
    XCTAssertFalse(riceRequired)
    let actual_quantity_grams_7: Double = riceJoin["quantity_grams"]
    XCTAssertEqual(actual_quantity_grams_7, 80.5)
  }

  func testCreateRespectsEditorSuppliedDisplayQuantity() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let service = UserRecipeTransactionService(db: db)
    let draft = CookbookRecipeDraft(
      title: "One Egg", timeMinutes: 5, servings: 1, instructions: "Fry it.", tagMask: 0,
      ingredientLines: [
        CookbookIngredientLine(ingredientId: egg, grams: 50, isRequired: true, displayQuantity: "1 large egg")
      ])
    let id = try service.createUserRecipe(draft)
    let display = try db.read { db in
      try String.fetchOne(
        db, sql: "SELECT display_quantity FROM recipe_ingredients WHERE recipe_id = ?",
        arguments: [id])
    }
    XCTAssertEqual(display, "1 large egg")
  }

  func testCreateRejectsInvalidDraftWithoutWriting() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let service = UserRecipeTransactionService(db: db)
    var draft = TestDrafts.validDraft(eggId: egg, riceId: egg)
    draft.servings = 0

    XCTAssertThrowsError(try service.createUserRecipe(draft)) { error in
      guard case CookbookTransactionError.validation(let problems) = error else {
        return XCTFail("expected .validation, got \(error)")
      }
      XCTAssertEqual(problems, [.invalidServings(0), .duplicateIngredient(ingredientId: 1)])
    }
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), 0)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients"), 0)
  }

  func testCreateRejectsUnknownCatalogIngredientsAtomically() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let service = UserRecipeTransactionService(db: db)
    let draft = CookbookRecipeDraft(
      title: "Ghost Pepper dish", timeMinutes: 30, servings: 1, instructions: "Spicy.", tagMask: 0,
      ingredientLines: [
        CookbookIngredientLine(ingredientId: egg, grams: 100, isRequired: true),
        CookbookIngredientLine(ingredientId: 999_999, grams: 5, isRequired: false),
      ])

    XCTAssertThrowsError(try service.createUserRecipe(draft)) { error in
      guard case CookbookTransactionError.unknownIngredients(let missing) = error else {
        return XCTFail("expected .unknownIngredients, got \(error)")
      }
      XCTAssertEqual(missing, [999_999])
    }
    // All-or-nothing: no recipe row, no partial joins.
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), 0)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients"), 0)
  }

  /// Mid-transaction failure proof: a SQLite trigger aborts the SECOND join
  /// insert after the recipe row was already written. The whole transaction
  /// must roll back — the recipe row cannot survive without its joins.
  func testMidTransactionJoinFailureRollsBackEntireWrite() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let cursed = try TestSupport.seedIngredient(db, name: "cursed-ingredient")
    try db.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER test_abort_cursed_join BEFORE INSERT ON recipe_ingredients
          WHEN NEW.ingredient_id = \(cursed)
          BEGIN SELECT RAISE(ABORT, 'test-injected join failure'); END
          """)
    }
    let service = UserRecipeTransactionService(db: db)
    let draft = CookbookRecipeDraft(
      title: "Trigger Trap", timeMinutes: 10, servings: 1, instructions: "Doomed.", tagMask: 0,
      ingredientLines: [
        CookbookIngredientLine(ingredientId: egg, grams: 100, isRequired: true),
        CookbookIngredientLine(ingredientId: cursed, grams: 10, isRequired: false),
      ])

    XCTAssertThrowsError(try service.createUserRecipe(draft))
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), 0)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients"), 0)
  }

  // MARK: - Update

  func testUpdateRewritesInPlaceAndPreservesIdentityAndHistory() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let seaweed = try TestSupport.seedIngredient(db, name: "seaweed")
    let service = UserRecipeTransactionService(db: db)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let id = try service.createUserRecipe(
      TestDrafts.validDraft(eggId: egg, riceId: rice), createdAt: createdAt)
    // The journal records a cook. Cookbook edits must not disturb it.
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, cooked_at) VALUES (?, ?)",
        arguments: [id, Date()])
    }

    let revised = CookbookRecipeDraft(
      title: "Sunday Eggs Deluxe", timeMinutes: 18, servings: 3,
      instructions: "Fry. Add seaweed. Serve.", tagMask: 2,
      ingredientLines: [
        CookbookIngredientLine(ingredientId: egg, grams: 150, isRequired: true),
        CookbookIngredientLine(ingredientId: seaweed, grams: 4, isRequired: false),
      ])
    try service.updateUserRecipe(recipeId: id, revised)

    let row = try db.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [id])
    }
    let recipe = try XCTUnwrap(row)
    let actual_title_8: String = recipe["title"]
    XCTAssertEqual(actual_title_8, "Sunday Eggs Deluxe")
    let actual_source_9: String = recipe["source"]
    XCTAssertEqual(actual_source_9, "user")
    let storedCreatedAt: Date = recipe["created_at"]
    XCTAssertEqual(storedCreatedAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 1)
    XCTAssertNil(recipe["ownership_key"])

    let joins = try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients WHERE recipe_id = ?", [id])
    XCTAssertEqual(joins, 2, "join set is replaced, not appended")
    let history = try TestSupport.count(db, "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = ?", [id])
    XCTAssertEqual(history, 1, "cooking history survives the edit with its anchor intact")
  }

  func testUpdateFailsAtomicallyWhenNewJoinsReferenceUnknownIngredients() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let service = UserRecipeTransactionService(db: db)
    let id = try service.createUserRecipe(TestDrafts.validDraft(eggId: egg, riceId: rice))

    let broken = CookbookRecipeDraft(
      title: "Now Broken", timeMinutes: 10, servings: 1, instructions: "x", tagMask: 0,
      ingredientLines: [CookbookIngredientLine(ingredientId: 42_424_242, grams: 1, isRequired: true)])
    XCTAssertThrowsError(try service.updateUserRecipe(recipeId: id, broken)) { error in
      guard case CookbookTransactionError.unknownIngredients = error else {
        return XCTFail("expected .unknownIngredients, got \(error)")
      }
    }
    // Old content and old joins remain exactly as they were.
    let title = try db.read { db in
      try String.fetchOne(db, sql: "SELECT title FROM recipes WHERE id = ?", arguments: [id])
    }
    XCTAssertEqual(title, "Sunday Eggs")
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients WHERE recipe_id = ?", [id]), 2)
  }

  func testUpdateRefusesBundledAndAIRows() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    for source in ["bundled", "ai"] {
      let id = try TestSupport.seedRecipe(db, title: "Catalog \(source)", source: source)
      let service = UserRecipeTransactionService(db: db)
      XCTAssertThrowsError(
        try service.updateUserRecipe(recipeId: id, TestDrafts.validDraft(eggId: egg, riceId: rice))
      ) { error in
        XCTAssertEqual(error as? CookbookTransactionError, .notUserRecipe(id))
      }
      let title = try db.read { db in
        try String.fetchOne(db, sql: "SELECT title FROM recipes WHERE id = ?", arguments: [id])
      }
      XCTAssertEqual(title, "Catalog \(source)", "catalog row must be byte-identical after refusal")
    }
  }

  // MARK: - Duplicate

  func testDuplicateCopiesUserRecipeIntoNewUserRow() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let service = UserRecipeTransactionService(db: db)
    let originalId = try service.createUserRecipe(TestDrafts.validDraft(eggId: egg, riceId: rice))

    let copyId = try service.duplicateUserRecipe(recipeId: originalId)
    XCTAssertNotEqual(copyId, originalId)

    let copy = try db.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [copyId])
    }
    let actual_title_10: String? = copy?["title"]
    XCTAssertEqual(actual_title_10, "Sunday Eggs (copy)")
    let actual_source_11: String? = copy?["source"]
    XCTAssertEqual(actual_source_11, "user")
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients WHERE recipe_id = ?", [copyId]), 2)

    // Original untouched.
    let original = try db.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = ?", arguments: [originalId])
    }
    let actual_title_12: String? = original?["title"]
    XCTAssertEqual(actual_title_12, "Sunday Eggs")
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients WHERE recipe_id = ?", [originalId]), 2)
  }

  func testDuplicateOfBundledRowCreatesUserCopyWithoutTouchingOriginal() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let bundledId = try TestSupport.seedRecipe(db, title: "Bundle Paella", source: "bundled")
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES (?, ?, 1, 90, '90g')",
        arguments: [bundledId, egg])
    }
    let service = UserRecipeTransactionService(db: db)

    let copyId = try service.duplicateUserRecipe(recipeId: bundledId)
    let copySource = try db.read { db in
      try String.fetchOne(db, sql: "SELECT source FROM recipes WHERE id = ?", arguments: [copyId])
    }
    XCTAssertEqual(copySource, "user")
    let original = try db.read { db in
      try Row.fetchOne(db, sql: "SELECT source, ownership_key, bundle_content_hash FROM recipes WHERE id = ?", arguments: [bundledId])
    }
    let actual_source_13: String? = original?["source"]
    XCTAssertEqual(actual_source_13, "bundled")
    XCTAssertNil(original?["ownership_key"])
    XCTAssertNil(original?["bundle_content_hash"])
  }

  // MARK: - Delete (never-cooked only)

  func testDeleteRemovesUncookedUserRecipeAndJoins() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let service = UserRecipeTransactionService(db: db)
    let id = try service.createUserRecipe(
      CookbookRecipeDraft(
        title: "Disposable", timeMinutes: 5, servings: 1, instructions: "x", tagMask: 0,
        ingredientLines: [CookbookIngredientLine(ingredientId: egg, grams: 10, isRequired: true)]))

    try service.deleteUncookedUserRecipe(recipeId: id)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), 0)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients"), 0)
  }

  func testDeleteRefusesCookedUserRecipe() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let service = UserRecipeTransactionService(db: db)
    let id = try service.createUserRecipe(
      CookbookRecipeDraft(
        title: "Cooked Once", timeMinutes: 5, servings: 1, instructions: "x", tagMask: 0,
        ingredientLines: [CookbookIngredientLine(ingredientId: egg, grams: 10, isRequired: true)]))
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, cooked_at) VALUES (?, ?)",
        arguments: [id, Date()])
    }

    XCTAssertThrowsError(try service.deleteUncookedUserRecipe(recipeId: id)) { error in
      XCTAssertEqual(error as? CookbookTransactionError, .recipeHasCookingHistory(id))
    }
    // Row and joins survive; history keeps its meal.
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), 1)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipe_ingredients"), 1)
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM cooking_history"), 1)
  }

  func testDeleteRefusesNonUserRows() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let bundledId = try TestSupport.seedRecipe(db, title: "Bundled thing", source: "bundled")
    let service = UserRecipeTransactionService(db: db)
    XCTAssertThrowsError(try service.deleteUncookedUserRecipe(recipeId: bundledId)) { error in
      XCTAssertEqual(error as? CookbookTransactionError, .notUserRecipe(bundledId))
    }
    XCTAssertEqual(try TestSupport.count(db, "SELECT COUNT(*) FROM recipes"), 1)
  }

}

/// Read-model checks for `CookbookStore`.
final class CookbookStoreTests: XCTestCase {
  func testStoreListsAndFetchesOnlyUserRecipes() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    _ = try TestSupport.seedRecipe(db, title: "Catalog row", source: "bundled")
    _ = try TestSupport.seedRecipe(db, title: "AI row", source: "ai")

    let service = UserRecipeTransactionService(db: db)
    let first = try service.createUserRecipe(TestDrafts.validDraft(eggId: egg, riceId: rice))
    let second = try service.createUserRecipe(
      CookbookRecipeDraft(
        title: "Second dish", timeMinutes: 7, servings: 1, instructions: "Cook.", tagMask: 0,
        ingredientLines: [CookbookIngredientLine(ingredientId: egg, grams: 60, isRequired: true)]))

    let store = CookbookStore(db: db)
    let listed = try store.listUserRecipes()
    XCTAssertEqual(listed.map(\.recipe.id), [second, first], "newest first")
    XCTAssertEqual(listed.map(\.recipe.title), ["Second dish", "Sunday Eggs"])

    let bundledId = try TestSupport.seedRecipe(db, title: "Another catalog row", source: "bundled")
    XCTAssertNil(try store.fetchUserRecipe(id: bundledId), "catalog rows are not editable library items")
    XCTAssertNotNil(try store.fetchUserRecipe(id: first))
    let fetched = try XCTUnwrap(try store.fetchUserRecipe(id: second))
    XCTAssertEqual(fetched.recipe.title, "Second dish")
    XCTAssertEqual(fetched.cookedCount, 0)
  }

  func testCookedCountIsReadOnlyJournalData() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let service = UserRecipeTransactionService(db: db)
    let id = try service.createUserRecipe(
      CookbookRecipeDraft(
        title: "Twice cooked", timeMinutes: 9, servings: 1, instructions: "Cook.", tagMask: 0,
        ingredientLines: [CookbookIngredientLine(ingredientId: egg, grams: 40, isRequired: true)]))
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, cooked_at) VALUES (?, ?)", arguments: [id, Date()])
      try db.execute(
        sql: "INSERT INTO cooking_history (recipe_id, cooked_at) VALUES (?, ?)", arguments: [id, Date()])
    }

    let store = CookbookStore(db: db)
    let summary = try XCTUnwrap(try store.fetchUserRecipe(id: id))
    XCTAssertEqual(summary.cookedCount, 2)
    XCTAssertTrue(try store.hasCookingHistory(recipeId: id))
  }
}
