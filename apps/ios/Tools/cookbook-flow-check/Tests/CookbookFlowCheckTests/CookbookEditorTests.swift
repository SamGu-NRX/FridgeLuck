import GRDB
import XCTest
@testable import CookbookFlowCheck
@testable import FLFeatureLogic

/// M3: the user-recipe editor — validation-first saves that never consume a
/// draft, identity-stable edits, soft archive in the sidecar, and
/// never-cooked-only discard.
final class CookbookEditorTests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  // MARK: - Fixtures

  private func makeEditor(
    _ db: DatabaseQueue, sidecarURL: URL
  ) -> CookbookRecipeEditor {
    CookbookRecipeEditor(
      db: db, sidecar: CookbookSidecarStore(fileURL: sidecarURL))
  }

  private func rawDocument(at url: URL) throws -> CookbookSidecarDocument {
    try CookbookSidecarStore(fileURL: url).load().document
  }

  private func makeSidecarURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("editor-sidecar-\(UUID().uuidString).json")
  }

  private func cookedDraft(eggId: Int64, riceId: Int64) -> CookbookRecipeDraft {
    CookbookRecipeDraft(
      title: "Egg Fried Rice",
      timeMinutes: 20,
      servings: 2,
      instructions: "Fry the rice. Add the egg. Season and serve hot.",
      tagMask: 0b11,
      ingredientLines: [
        CookbookIngredientLine(ingredientId: eggId, grams: 2, isRequired: true, displayQuantity: "2"),
        CookbookIngredientLine(ingredientId: riceId, grams: 300, isRequired: true),
      ])
  }

  /// What persistence turns a draft into: the M1 join writes materialize a
  /// grams-derived display quantity when the user left it unset. The editor
  /// neither adds to nor undoes that behavior; expectations name it here.
  private func expectedPersistedDraft(eggId: Int64, riceId: Int64) -> CookbookRecipeDraft {
    var draft = cookedDraft(eggId: eggId, riceId: riceId)
    draft.ingredientLines[1].displayQuantity = "300g"
    return draft
  }

  private func logCookingHistory(_ db: DatabaseQueue, recipeId: Int64) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO cooking_history (recipe_id, cooked_at, servings_consumed, rating)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [recipeId, Date(), 2, 5])
    }
  }

  // MARK: - Create: exactly what was entered, nothing else

  func testCreatePersistsExactlyWhatWasEntered() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)

    let draft = cookedDraft(eggId: egg, riceId: rice)
    let recipeId = try editor.save(draft)
    XCTAssertNotNil(editor.editingRecipeId)

    // A fresh load round-trips what persistence records — no enrichment
    // beyond the grams-derived display quantity the join writes always add.
    XCTAssertEqual(try editor.loadForEditing(recipeId: recipeId), expectedPersistedDraft(eggId: egg, riceId: rice))
    XCTAssertEqual(try editor.isArchived(recipeId: recipeId), false)

    // The save also left the sidecar alone: no implicit favorite, save, or
    // collection membership is invented by creating a recipe.
    XCTAssertTrue(try rawDocument(at: sidecarURL).savedRecipes.isEmpty)
  }

  // MARK: - Edit: identity and provenance stable, fields rewritten

  func testEditKeepsIdentityProvenanceAndRewritesFields() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)
    let recipeId = try editor.save(cookedDraft(eggId: egg, riceId: rice))
    try logCookingHistory(db, recipeId: recipeId)
    let cookedCountBefore = try TestSupport.count(
      db, "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = \(recipeId)")

    var edited = cookedDraft(eggId: egg, riceId: rice)
    edited.title = "Better Fried Rice"
    edited.timeMinutes = 25
    edited.servings = 3
    edited.tagMask = 0b100001
    edited.ingredientLines = [
      CookbookIngredientLine(ingredientId: rice, grams: 400, isRequired: true)
    ]
    XCTAssertEqual(try editor.save(edited), recipeId, "an edit keeps identity")

    let reloaded = try editor.loadForEditing(recipeId: recipeId)
    edited.ingredientLines[0].displayQuantity = "400g"
    XCTAssertEqual(reloaded, edited)
    XCTAssertEqual(
      try TestSupport.count(
        db, "SELECT COUNT(*) FROM recipes WHERE id = \(recipeId) AND source = 'user'"),
      1, "provenance survives the edit")
    XCTAssertEqual(
      try TestSupport.count(
        db, "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = \(recipeId)"),
      cookedCountBefore, "an edit never rewrites logged history")
  }

  // MARK: - Validation-first: all problems, draft survives

  func testFailedValidationReportsAllProblemsAndKeepsEditorState() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)

    var bad = editor.newDraft()
    bad.title = ""
    bad.timeMinutes = -5
    bad.instructions = "  "
    bad.ingredientLines = [
      CookbookIngredientLine(ingredientId: egg, grams: 100, isRequired: true),
      CookbookIngredientLine(ingredientId: egg, grams: 50, isRequired: true),
    ]

    XCTAssertThrowsError(try editor.save(bad)) { error in
      guard case CookbookTransactionError.validation(let problems) = error else {
        return XCTFail("expected .validation, got \(error)")
      }
      // Every problem surfaces at once — the user fixes one pass, not four.
      XCTAssertTrue(problems.contains(.emptyTitle))
      XCTAssertTrue(problems.contains(.invalidTimeMinutes(-5)))
      XCTAssertTrue(problems.contains(.emptyInstructions))
      XCTAssertTrue(problems.contains(.duplicateIngredient(ingredientId: egg)))
      XCTAssertEqual(problems.count, 4)
    }
    XCTAssertNil(
      editor.editingRecipeId,
      "a failed create does not point the editor at anything")

    // Retry with corrections — the failed save cost nothing.
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let recipeId = try editor.save(cookedDraft(eggId: egg, riceId: rice))
    _ = recipeId
    XCTAssertNotNil(editor.editingRecipeId)

    // The same protection on an edit: a bad draft leaves the row untouched.
    let original = try editor.loadForEditing(recipeId: recipeId)
    var worse = original
    worse.title = ""
    worse.ingredientLines = []
    XCTAssertThrowsError(try editor.save(worse))
    XCTAssertEqual(try editor.loadForEditing(recipeId: recipeId), original)
  }

  // MARK: - Provenance guardrails

  func testEditAndArchiveRefuseBundledRows() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let bundledId = try TestSupport.seedRecipe(db, title: "Bundled", source: "bundled")
    let aiId = try TestSupport.seedRecipe(db, title: "AI", source: "ai")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)

    XCTAssertThrowsError(try editor.loadForEditing(recipeId: bundledId)) { error in
      XCTAssertEqual(error as? CookbookTransactionError, .notUserRecipe(bundledId))
    }
    XCTAssertThrowsError(try editor.archive(recipeId: aiId)) { error in
      XCTAssertEqual(error as? CookbookTransactionError, .notUserRecipe(aiId))
    }
    XCTAssertNil(editor.editingRecipeId, "a refused load does not aim the editor")

    // A missing row is distinguished from a protected one.
    XCTAssertThrowsError(try editor.loadForEditing(recipeId: 999_999)) { error in
      XCTAssertEqual(error as? CookbookTransactionError, .recipeNotFound(999_999))
    }
  }

  // MARK: - Archive: soft, relaunch-durable, history-safe

  func testArchiveIsSoftSurvivesRelaunchAndNeverTouchesHistory() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)
    let recipeId = try editor.save(cookedDraft(eggId: egg, riceId: rice))
    try logCookingHistory(db, recipeId: recipeId)

    try editor.archive(recipeId: recipeId)
    try editor.archive(recipeId: recipeId)  // idempotent

    // The row, its joins, and the logged meal all survive.
    XCTAssertEqual(try editor.isArchived(recipeId: recipeId), true)
    XCTAssertEqual(try rawDocument(at: sidecarURL).archivedRecipeIds, [recipeId])
    XCTAssertNotNil(try CookbookStore(db: db).fetchUserRecipe(id: recipeId))
    XCTAssertEqual(
      try TestSupport.count(
        db, "SELECT COUNT(*) FROM cooking_history WHERE recipe_id = \(recipeId)"),
      1)

    // A fresh editor over the same files is a relaunch: still archived.
    let relaunched = makeEditor(db, sidecarURL: sidecarURL)
    XCTAssertEqual(try relaunched.isArchived(recipeId: recipeId), true)

    try relaunched.unarchive(recipeId: recipeId)
    XCTAssertEqual(try relaunched.isArchived(recipeId: recipeId), false)
    XCTAssertEqual(try rawDocument(at: sidecarURL).archivedRecipeIds, [])
  }

  // MARK: - Discard: never-cooked only, archive is the cooked path

  func testDiscardDeletesOnlyNeverCookedAndRefusesCooked() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)

    let uncooked = try editor.save(cookedDraft(eggId: egg, riceId: rice))
    editor.startCreating()  // second save must create, not edit the first
    let cooked = try editor.save(cookedDraft(eggId: egg, riceId: rice))
    try logCookingHistory(db, recipeId: cooked)

    try editor.discard(recipeId: uncooked)
    XCTAssertNil(try CookbookStore(db: db).fetchUserRecipe(id: uncooked))

    XCTAssertThrowsError(try editor.discard(recipeId: cooked)) { error in
      XCTAssertEqual(
        error as? CookbookTransactionError, .recipeHasCookingHistory(cooked))
    }
    // The cooked recipe is intact — archive is its path out of the library.
    XCTAssertNotNil(try CookbookStore(db: db).fetchUserRecipe(id: cooked))
    try editor.archive(recipeId: cooked)
    XCTAssertEqual(try editor.isArchived(recipeId: cooked), true)
  }

  // MARK: - Duplicate: independent copy

  func testDuplicateCreatesIndependentEditableCopy() throws {
    let db = try TestSupport.makeDatabaseQueue()
    let egg = try TestSupport.seedIngredient(db, name: "egg")
    let rice = try TestSupport.seedIngredient(db, name: "rice")
    let sidecarURL = makeSidecarURL()
    let editor = makeEditor(db, sidecarURL: sidecarURL)
    let originalId = try editor.save(cookedDraft(eggId: egg, riceId: rice))

    let copyId = try editor.duplicate(recipeId: originalId)
    XCTAssertNotEqual(copyId, originalId)
    XCTAssertEqual(
      editor.editingRecipeId, copyId, "the editor follows the duplicate")

    var editedCopy = cookedDraft(eggId: egg, riceId: rice)
    editedCopy.title = "My Version"
    XCTAssertEqual(try editor.save(editedCopy), copyId)

    // The original keeps its exact content; the copy carries the edit.
    XCTAssertEqual(try editor.loadForEditing(recipeId: originalId), expectedPersistedDraft(eggId: egg, riceId: rice))
    editedCopy.ingredientLines[1].displayQuantity = "300g"
    XCTAssertEqual(try editor.loadForEditing(recipeId: copyId), editedCopy)
  }
}
