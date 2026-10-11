import GRDB
import XCTest

@testable import FridgeLuck

/// The bundled-data ownership refresh: V20 migration, adoption of legacy rows
/// against pinned payloads, payload application decisions, and the guarantees
/// that make the pass safe to run at every launch (id preservation, user-content
/// protection, atomic rollback, postconditions).
///
/// Payload fixtures are decoded through the real positional-array decoders so
/// payload-side and row-side hashes are exercised against identical bytes.
final class BundledDataRefreshTests: XCTestCase {
  // MARK: - Fixtures

  /// A small data.json-shaped universe: three ingredients, one recipe using all
  /// of them (two required, one optional).
  private static let fixtureDataJSON = """
    {
      "tags": ["breakfast", "dinner", "snack"],
      "ingredients": {
        "1": ["egg", 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, "piece", "keep cold", "salt", null],
        "2": ["rice", 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 0.001, "cup", "dry pantry", null, null],
        "3": ["seaweed", 20.0, 0.6, 3.0, 0.2, 0.5, 0.1, 8.7, "sheet", "dry pantry", null, "toasty"]
      },
      "recipes": [[7, "Egg Bowl", 15, 1, [[1, 100.0], [2, 200.0]], [[3, 5.0]], "Cook it.", 3]]
    }
    """

  /// The same universe with recipe 7 re-timed (a bundle content change) and the
  /// recipe plus the seaweed ingredient dropped (an entry removal).
  private static let changedDataJSON = """
    {
      "tags": ["breakfast", "dinner", "snack"],
      "ingredients": {
        "1": ["egg", 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, "piece", "keep cold", "salt", null],
        "2": ["rice", 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 0.001, "cup", "dry pantry", null, null],
        "3": ["seaweed", 20.0, 0.6, 3.0, 0.2, 0.5, 0.1, 8.7, "sheet", "dry pantry", null, "toasty"]
      },
      "recipes": [[7, "Egg Bowl", 20, 2, [[1, 100.0], [2, 200.0]], [[3, 5.0]], "Cook it.", 3]]
    }
    """

  private static let smallerDataJSON = """
    {
      "tags": ["breakfast", "dinner", "snack"],
      "ingredients": {
        "1": ["egg", 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, "piece", "keep cold", "salt", null],
        "2": ["rice", 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 0.001, "cup", "dry pantry", null, null]
      },
      "recipes": []
    }
    """

  private static let fixtureCatalogJSON = """
    [
      {"fdcId": 167606, "name": "tofu", "calories": 76.0, "protein": 8.0, "carbs": 1.9,
       "fat": 4.8, "fiber": 0.3, "sugar": 0.6, "sodium": 0.007, "notes": "SR Legacy",
       "description": "firm block", "categoryLabel": "Protein", "spriteGroup": "protein",
       "spriteKey": "tofu"}
    ]
    """

  private func decodeData(_ json: String) -> BundledData {
    try! JSONDecoder().decode(BundledData.self, from: Data(json.utf8))
  }

  private func decodeFixtureCatalog() -> [LegacyCatalogIngredient] {
    try! JSONDecoder().decode(
      [LegacyCatalogIngredient].self, from: Data(Self.fixtureCatalogJSON.utf8))
  }

  private func makePin(
    slug: String = "v1",
    data: BundledData,
    catalog: [LegacyCatalogIngredient] = []
  ) -> PinnedBundlePayload {
    PinnedBundlePayload(
      slug: slug,
      bundleId: "bundle-\(slug)",
      data: data,
      dataSha256: "sha-\(slug)",
      catalog: catalog)
  }

  private func makePass(
    current: BundledData,
    pins: [PinnedBundlePayload],
    catalog: [LegacyCatalogIngredient] = []
  ) -> BundledDataRefresher.Pass {
    BundledDataRefresher.Pass(
      current: current,
      currentDataSha256: "current-sha",
      catalog: catalog,
      pins: pins)
  }

  /// A database with all migrations applied and legacy-shaped content: the
  /// ingredients were hydrated by an old release with row ids that no longer
  /// match bundle ids, and the recipe row has an unrelated autoincrement id.
  private func makeLegacyDatabase(matchingRealBundle: Bool = false) throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    // `matchingRealBundle` swaps the legacy ingredient rows to the REAL v1
    // bundle content (egg/rice/soy_sauce) under foreign row ids, so the launch
    // path's content-based adoption can match them.
    let ingredientRows = matchingRealBundle
      ? """
            (500, 'egg', 155.0, 13.0, 1.1, 11.0, 0.0, 1.1, 0.124, '1 large (50g)', 'Refrigerate, use within 3 weeks'),
            (501, 'rice', 130.0, 2.7, 28.0, 0.3, 0.4, 0.0, 0.001, '1 cup cooked (158g)', 'Store in airtight container'),
            (502, 'soy_sauce', 53.0, 8.1, 4.9, 0.0, 0.0, 0.4, 5.493, '1 tbsp (15ml)', 'Refrigerate after opening')
          """
      : """
            (500, 'egg', 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, 'piece', 'keep cold'),
            (501, 'rice', 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 0.001, 'cup', 'dry pantry'),
            (502, 'seaweed', 20.0, 0.6, 3.0, 0.2, 0.5, 0.1, 8.7, 'sheet', 'dry pantry')
          """
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                                   typical_unit, storage_tip)
          VALUES
          \(ingredientRows);
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
          VALUES (900, 'Egg Bowl', 15, 1, 'Cook it.', 3, 'bundled');
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
            (900, 500, 1, 100.0, '100g egg'),
            (900, 501, 1, 200.0, '200g rice'),
            (900, 502, 0, 5.0, '5g seaweed');
          """)
    }
    return db
  }

  private func refresh(
    _ db: DatabaseQueue, pass: BundledDataRefresher.Pass,
    readiness: BundledDataRefresher.HistoricalSnapshotReadiness = .ready,
    injections: BundledDataRefresher.InjectionPoints = .init()
  ) async throws -> BundledDataRefreshOutcome {
    try await BundledDataRefresher.refresh(
      appDB: AppDatabase(dbQueue: db), pass: pass, readiness: readiness, injections: injections)
  }

  private struct Diagnostic: Equatable {
    let ref: String
    let code: String
  }

  private func diagnostics(_ db: DatabaseQueue) throws -> [Diagnostic] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT entity_ref, code FROM bundle_refresh_diagnostics ORDER BY entity_ref, code"
      )
      .map { row -> Diagnostic in
        let ref: String = row["entity_ref"]
        let code: String = row["code"]
        return Diagnostic(ref: ref, code: code)
      }
    }
  }

  private func ownershipState(_ db: DatabaseQueue, key: String) throws -> String? {
    try db.read {
      try String.fetchOne(
        $0, sql: "SELECT value FROM bundled_recipe_state WHERE key = ?", arguments: [key])
    }
  }

  private func ownedIngredientCount(_ db: DatabaseQueue) throws -> Int {
    try db.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ingredients WHERE ownership_key IS NOT NULL")
        ?? 0
    }
  }

  // MARK: - V20 migration

  func testMigrationAddsOwnershipColumnsAndDiagnosticsTable() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)

    let recipeColumns = try db.read { try Set($0.columns(in: "recipes").map(\.name)) }
    let ingredientColumns = try db.read { try Set($0.columns(in: "ingredients").map(\.name)) }
    for column in ["ownership_key", "bundle_content_hash"] {
      XCTAssertTrue(recipeColumns.contains(column), "recipes missing \(column)")
      XCTAssertTrue(ingredientColumns.contains(column), "ingredients missing \(column)")
    }
    let hasDiagnostics = try db.read { try $0.tableExists("bundle_refresh_diagnostics") }
    XCTAssertTrue(hasDiagnostics)

    // The diagnostics table upserts on (entity_type, entity_ref, code).
    try db.write { db in
      for _ in 0..<2 {
        try db.execute(
          sql: """
            INSERT INTO bundle_refresh_diagnostics (entity_type, entity_ref, code, detail, created_at)
            VALUES ('recipe', 'r', 'code', 'd', CURRENT_TIMESTAMP)
            ON CONFLICT(entity_type, entity_ref, code) DO UPDATE SET detail = excluded.detail
            """)
      }
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundle_refresh_diagnostics")
      XCTAssertEqual(count, 1)
    }
  }

  func testOwnershipKeyIsUniqueOnlyAmongOwnedRows() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)

    // Unowned rows never collide; a second row claiming an owned key is refused.
    try db.write { db in
      try db.execute(sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (1, 'a', 0, 0, 0, 0), (2, 'b', 0, 0, 0, 0)")
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source,
                               ownership_key)
          VALUES (10, 't', 1, 1, 'i', 0, 'bundled', 'fridgeluck.bundle.recipe/1'),
                 (11, 'u', 1, 1, 'i', 0, 'bundled', NULL)
          """)
    }
    do {
      try db.write { db in
        try db.execute(
          sql: "UPDATE recipes SET ownership_key = 'fridgeluck.bundle.recipe/1' WHERE id = 11")
      }
      XCTFail("two rows claimed one ownership key")
    } catch {
      // expected: the partial unique index refused the second claim
    }
  }

  // MARK: - Hash round trip

  func testRowSideHashesMatchPayloadSideProjections() throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    let egg = payload.ingredients["1"]!
    let recipe = payload.recipes[0]
    let catalogEntry = decodeFixtureCatalog()[0]

    try db.write { db in
      // Written exactly the way the loaders write them (BundledDataLoader.loadInto
      // and the catalog importer), then read back through the row-side projection.
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                                   typical_unit, storage_tip, description, category_label,
                                   sprite_group, sprite_key)
          VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)
          """,
        arguments: [
          egg.name, egg.calories, egg.protein, egg.carbs, egg.fat, egg.fiber, egg.sugar,
          egg.sodium, egg.typicalUnit, egg.storageTip,
        ])
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                                   typical_unit, storage_tip, pairs_with, notes, description,
                                   category_label, sprite_group, sprite_key)
          VALUES (2, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, ?)
          """,
        arguments: [
          catalogEntry.name, catalogEntry.calories, catalogEntry.protein, catalogEntry.carbs,
          catalogEntry.fat, catalogEntry.fiber, catalogEntry.sugar, catalogEntry.sodium,
          catalogEntry.notes, catalogEntry.description, catalogEntry.categoryLabel,
          catalogEntry.spriteGroup, catalogEntry.spriteKey,
        ])
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
          VALUES (7, ?, ?, ?, ?, ?, 'bundled')
          """,
        arguments: [
          recipe.title, recipe.timeMinutes, recipe.servings, recipe.instructions,
          recipe.tagBitmask,
        ])
    }

    try db.read { db in
      let eggRow = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 1")!
      let eggKey: String? = eggRow["ownership_key"]
      XCTAssertNil(eggKey)
      XCTAssertEqual(
        CanonicalHash.hash(
          fields: BundleRowProjection.rowFields(eggRow, projection: .dataJsonIngredient)),
        CanonicalHash.hash(fields: BundleRowProjection.dataJsonIngredientFields(egg)))
      let catalogRow = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 2")!
      XCTAssertEqual(
        CanonicalHash.hash(
          fields: BundleRowProjection.rowFields(catalogRow, projection: .catalogIngredient)),
        CanonicalHash.hash(fields: BundleRowProjection.catalogIngredientFields(catalogEntry)))
      let recipeRow = try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = 7")!
      XCTAssertEqual(
        CanonicalHash.hash(fields: BundleRowProjection.rowFields(recipeRow, projection: .recipe)),
        CanonicalHash.hash(fields: BundleRowProjection.recipeFields(recipe)))
    }
  }

  // MARK: - Adoption

  func testAdoptionStampsLegacyRowsAndKeepsTheirIds() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pin = makePin(data: payload)

    let outcome = try await refresh(db, pass: makePass(current: payload, pins: [pin]))

    XCTAssertEqual(outcome.ingredientsAdopted, 3)
    XCTAssertEqual(outcome.recipesAdopted, 1)
    XCTAssertEqual(try diagnostics(db), [])

    try await db.read { db in
      // Ids referenced by inventory/history survive adoption untouched.
      let egg = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 500")!
      let eggKey: String? = egg["ownership_key"]
      XCTAssertEqual(eggKey, "fridgeluck.bundle.ingredient/1")
      let eggHash: String? = egg["bundle_content_hash"]
      XCTAssertEqual(
        eggHash,
        CanonicalHash.hash(
          fields: BundleRowProjection.dataJsonIngredientFields(payload.ingredients["1"]!)))
      let recipe = try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = 900")!
      let recipeKey: String? = recipe["ownership_key"]
      XCTAssertEqual(recipeKey, "fridgeluck.bundle.recipe/7")
      let recipeHash: String? = recipe["bundle_content_hash"]
      XCTAssertEqual(
        recipeHash,
        CanonicalHash.hash(fields: BundleRowProjection.recipeFields(payload.recipes[0])))
      let adopted = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM ingredients WHERE ownership_key IS NOT NULL")
      XCTAssertEqual(adopted, 3)
    }
    XCTAssertEqual(try ownershipState(db, key: "ownership_ready"), "1")
  }

  /// Two identical bundled recipe rows reproduce one bundle entry: adoption
  /// gives the key to exactly one row (first by id) and explains the runner-up.
  /// Ingredient duplicates cannot exist — the v1 schema keeps names UNIQUE —
  /// so the ambiguous-adoption case is only representable for recipes.
  func testDuplicateLegacyRecipeRowsAdoptOneWinner() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source)
          SELECT title, time_minutes, servings, instructions, tags, source
          FROM recipes WHERE id = 900;
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          SELECT 901, ingredient_id, is_required, quantity_grams, display_quantity
          FROM recipe_ingredients WHERE recipe_id = 900;
          """)
    }

    _ = try await refresh(db, pass: makePass(current: payload, pins: [makePin(data: payload)]))

    try await db.read { db in
      let winners = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
      XCTAssertEqual(winners, 1, "exactly one row wins")
      let unowned = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM recipes WHERE ownership_key IS NULL")
      XCTAssertEqual(unowned, 1, "the runner-up stays unowned")
    }
    XCTAssertEqual(try diagnostics(db).map(\.code), ["duplicate_adoption_target"])
  }

  func testUnmatchedLegacyRowGetsADIagnosticAndStaysUnowned() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    try await db.write { db in
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (700, 'egg', 999.0, 1.0, 0, 0)"
      )
    }

    _ = try await refresh(db, pass: makePass(current: payload, pins: [makePin(data: payload)]))

    // Three explanations cascade from one unmatchable row: the row itself is
    // unmatched, the bundle entry it would own is blocked by it, and the recipe
    // depending on that bundle entry reports the unresolved dependency.
    XCTAssertEqual(
      try diagnostics(db).map(\.code),
      ["blocked_by_unadopted_row", "unresolved_ingredient_dependency", "unmatched_row"])
    try await db.read { db in
      let calories = try Double.fetchOne(
        db, sql: "SELECT calories FROM ingredients WHERE id = 700")
      XCTAssertEqual(calories, 999.0, "the modified legacy row keeps its content")
    }
  }

  // MARK: - Payload application

  func testNewEntriesAreInsertedOwnedWithResolvedRelationships() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)

    let outcome = try await refresh(
      db, pass: makePass(current: payload, pins: [makePin(data: payload)]))

    XCTAssertEqual(outcome.ingredientsInserted, 3)
    XCTAssertEqual(outcome.recipesInserted, 1)
    XCTAssertEqual(try diagnostics(db), [])
    try await db.read { db in
      let relationshipRows = try Row.fetchAll(
        db,
        sql: """
          SELECT i.name AS name, ri.is_required AS required, ri.quantity_grams AS grams
          FROM recipe_ingredients ri JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ri.recipe_id = (
            SELECT id FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7')
          """)
      XCTAssertEqual(relationshipRows.count, 3)
      let required = try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM recipe_ingredients
          WHERE recipe_id = (
            SELECT id FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7')
            AND is_required = 1
          """)
      XCTAssertEqual(required, 2)
    }
  }

  func testOwnedRowTracksPayloadChangesButUserEditsWin() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pin = makePin(data: payload)

    _ = try await refresh(db, pass: makePass(current: payload, pins: [pin]))
    XCTAssertEqual(try diagnostics(db), [])

    // A bundle content change (new payload, same pin history) updates the owned row.
    let changedPayload = decodeData(Self.changedDataJSON)
    let secondOutcome = try await refresh(
      db, pass: makePass(current: changedPayload, pins: [pin]))
    XCTAssertEqual(secondOutcome.recipesUpdated, 1)
    try await db.read { db in
      let time = try Int.fetchOne(
        db,
        sql: "SELECT time_minutes FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
      XCTAssertEqual(time, 20)
      let servings = try Int.fetchOne(
        db,
        sql: "SELECT servings FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
      XCTAssertEqual(servings, 2)
    }

    // Then the user edits the row: the refresh declines to touch it, explains,
    // and the pass still succeeds (the postcondition accepts the explanation).
    try await db.write { db in
      try db.execute(
        sql:
          "UPDATE recipes SET instructions = 'my own version' WHERE ownership_key = 'fridgeluck.bundle.recipe/7'"
      )
    }
    let thirdOutcome = try await refresh(
      db, pass: makePass(current: changedPayload, pins: [pin]))
    XCTAssertEqual(thirdOutcome.recipesUpdated, 0)
    try await db.read { db in
      let instructions = try String.fetchOne(
        db,
        sql: "SELECT instructions FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
      XCTAssertEqual(instructions, "my own version")
    }
    XCTAssertEqual(try diagnostics(db).map(\.code), ["modified_row"])
  }

  func testUnadoptedNameTwinBlocksTheInsertAndIsExplained() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    let catalog = decodeFixtureCatalog()
    try await db.write { db in
      // A legacy row the adoption could not match (different content) blocks the
      // catalog entry of the same name rather than stealing or duplicating it.
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (800, 'tofu', 1.0, 0, 0, 0)")
    }

    _ = try await refresh(
      db, pass: makePass(current: payload, pins: [makePin(data: payload, catalog: catalog)], catalog: catalog))

    // The legacy row misses every pinned tofu fingerprint (unmatched_row) and
    // the current catalog entry is blocked by the same-name row.
    XCTAssertEqual(try diagnostics(db).map(\.code), ["unmatched_row", "blocked_by_unadopted_row"])
    try await db.read { db in
      let calories = try Double.fetchOne(
        db, sql: "SELECT calories FROM ingredients WHERE id = 800")
      XCTAssertEqual(calories, 1.0)
      let key: String? = try String.fetchOne(
        db, sql: "SELECT ownership_key FROM ingredients WHERE id = 800")
      XCTAssertNil(key, "the legacy row keeps no bundle ownership it never earned")
    }
  }

  func testNameHeldByDifferentlyOwnedRowIsSkippedNotDuplicated() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    let catalog = decodeFixtureCatalog()
    try await db.write { db in
      // A row owned by a different bundle entry already holds the name.
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, ownership_key, bundle_content_hash)
          VALUES (900, 'tofu', 1.0, 0, 0, 0, 'fridgeluck.bundle.ingredient/404', 'deadbeef')
          """)
    }

    _ = try await refresh(
      db,
      pass: makePass(
        current: payload,
        pins: [makePin(data: payload, catalog: catalog)],
        catalog: catalog))

    XCTAssertTrue(
      try diagnostics(db)
        .contains { $0.ref == "usda.fdc/167606" && $0.code == "name_conflict" })
    try await db.read { db in
      let tofuCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM ingredients WHERE name = 'tofu'")
      XCTAssertEqual(tofuCount, 1, "no duplicate row was created")
    }
  }

  // MARK: - Removals and idempotence

  func testEntriesRemovedFromTheBundleAreRecordedAndKept() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pin = makePin(data: payload)
    _ = try await refresh(db, pass: makePass(current: payload, pins: [pin]))

    // A future payload that no longer ships the recipe or the seaweed ingredient.
    let smaller = decodeData(Self.smallerDataJSON)
    _ = try await refresh(db, pass: makePass(current: smaller, pins: [pin]))

    let removed = try diagnostics(db).filter { $0.code == "removed_from_bundle" }
    XCTAssertEqual(
      Set(removed.map(\.ref)),
      Set(["fridgeluck.bundle.recipe/7", "fridgeluck.bundle.ingredient/3"]))
    try await db.read { db in
      let kept = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients WHERE id = 502")
      XCTAssertEqual(kept, 1, "rows are never deleted")
    }
  }

  /// User data that references a removed recipe keeps working. The refresh
  /// never deletes rows: the removed entry is diagnosed (`removed_from_bundle`)
  /// and its row stays, so the journal's join still finds the meal and the
  /// frozen snapshot still supplies its macros. This is the contract a bundle
  /// author relies on when dropping a recipe: removing it from the payload
  /// retires it from updates, not from the user's history.
  func testMealReferencingARemovedRecipeStaysInTheJournalAfterTheRefresh() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pin = makePin(data: payload)
    _ = try await refresh(db, pass: makePass(current: payload, pins: [pin]))

    // Log a meal against the adopted Egg Bowl and freeze its snapshot.
    let eggBowlRowId = try await db.read { db in
      try Int64.fetchOne(
        db, sql: "SELECT id FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
    }!
    let snapshotService = NutritionSnapshotService(db: db)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO cooking_history
            (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier)
          VALUES (?, ?, datetime('now'), NULL, 2, 1.0)
          """,
        arguments: [Int64(1), eggBowlRowId])
      try snapshotService.captureSnapshot(in: db, historyId: 1, recipeId: eggBowlRowId)
    }
    let preCaptured = try snapshotService.capturedMacros(historyId: 1)

    // A later bundle drops the recipe (and the seaweed ingredient).
    _ = try await refresh(
      db, pass: makePass(current: decodeData(Self.smallerDataJSON), pins: [pin]))

    // The removal is explained, not silent.
    let removedRefs = Set(try diagnostics(db).filter { $0.code == "removed_from_bundle" }.map(\.ref))
    XCTAssertTrue(
      removedRefs.contains("fridgeluck.bundle.recipe/7"),
      "the removal must be diagnosed")
    // The meal is still in the journal: the row was kept, only retired.
    let journal = try UserDataRepository(db: db).cookingJournal()
    XCTAssertEqual(journal.count, 1, "the meal survives the removal refresh")
    XCTAssertEqual(journal[0].recipe.id, eggBowlRowId)
    XCTAssertEqual(journal[0].recipe.title, "Egg Bowl")
    // The frozen macros are untouched by the removal.
    let postCaptured = try snapshotService.capturedMacros(historyId: 1)
    XCTAssertEqual(
      postCaptured.caloriesPerServing.bitPattern, preCaptured.caloriesPerServing.bitPattern,
      "snapshot macros must not move when the entry is removed")
  }

  /// The contract's ID-stability rule, and what the code actually does when a
  /// bundle breaks it. A bundle id is the ownership identity: reusing id 7 for
  /// a different dish updates the same owned row in place, so past meals keep
  /// pointing at the row and now describe the new dish. The frozen snapshot
  /// keeps their recorded macros honest; only the title and live content move.
  /// A bundle that means to replace a dish must ship it under a NEW id and
  /// retire the old one (a removal), never recycle the id.
  func testReusingABundleIdRewritesTheDishInPlaceAndTheJournalFollowsIt() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pin = makePin(data: payload)
    _ = try await refresh(db, pass: makePass(current: payload, pins: [pin]))

    let eggBowlRowId = try await db.read { db in
      try Int64.fetchOne(
        db, sql: "SELECT id FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
    }!
    let snapshotService = NutritionSnapshotService(db: db)
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO cooking_history
            (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier)
          VALUES (?, ?, datetime('now'), NULL, 2, 1.0)
          """,
        arguments: [Int64(1), eggBowlRowId])
      try snapshotService.captureSnapshot(in: db, historyId: 1, recipeId: eggBowlRowId)
    }
    let preCaptured = try snapshotService.capturedMacros(historyId: 1)

    // The broken contract: id 7 comes back as a different dish.
    let hijackedJSON = """
      {
        "tags": ["breakfast", "dinner", "snack"],
        "ingredients": {
          "1": ["egg", 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, "piece", "keep cold", "salt", null],
          "2": ["rice", 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 0.001, "cup", "dry pantry", null, null],
          "3": ["seaweed", 20.0, 0.6, 3.0, 0.2, 0.5, 0.1, 8.7, "sheet", "dry pantry", null, "toasty"]
        },
        "recipes": [[7, "Lentil Stew", 40, 4, [[1, 100.0], [2, 200.0]], [], "Simmer lentils.", 1]]
      }
      """
    _ = try await refresh(
      db, pass: makePass(current: decodeData(hijackedJSON), pins: [pin]))

    // The reused id maps to exactly one row, rewritten in place — the row id
    // (and every reference to it) survives, now describing the new dish.
    try await db.read { db in
      let keyRows = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
      XCTAssertEqual(keyRows, 1, "an id owns exactly one row")
      let title = try String.fetchOne(
        db, sql: "SELECT title FROM recipes WHERE id = ?", arguments: [eggBowlRowId])
      XCTAssertEqual(title, "Lentil Stew", "the reused id rewrites the row in place")
    }
    // The journal follows the row: the meal now shows the new dish.
    let journal = try UserDataRepository(db: db).cookingJournal()
    XCTAssertEqual(journal.count, 1)
    XCTAssertEqual(journal[0].recipe.id, eggBowlRowId)
    XCTAssertEqual(journal[0].recipe.title, "Lentil Stew")
    // The frozen snapshot keeps the meal's recorded macros honest even though
    // the live row changed under it.
    let postCaptured = try snapshotService.capturedMacros(historyId: 1)
    XCTAssertEqual(
      postCaptured.caloriesPerServing.bitPattern, preCaptured.caloriesPerServing.bitPattern,
      "snapshot macros survive the in-place rewrite")
  }

  func testRerunningTheSamePassIsIdempotent() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pass = makePass(current: payload, pins: [makePin(data: payload)])

    let first = try await refresh(db, pass: pass)
    let second = try await refresh(db, pass: pass)

    XCTAssertEqual(first.ingredientsAdopted, 3)
    XCTAssertEqual(second.ingredientsAdopted, 0)
    XCTAssertEqual(second.ingredientsUpdated, 0)
    XCTAssertEqual(second.recipesUpdated, 0)
    XCTAssertEqual(second.ingredientsInserted, 0)
    XCTAssertEqual(second.recipesInserted, 0)
    XCTAssertEqual(try diagnostics(db), [])
    XCTAssertEqual(try ownedIngredientCount(db), 3)
  }

  // MARK: - Atomicity and pass construction

  func testFailureMidPassLeavesTheDatabaseUntouched() async throws {
    let db = try makeLegacyDatabase()
    let payload = decodeData(Self.fixtureDataJSON)
    let pass = makePass(current: payload, pins: [makePin(data: payload)])

    struct Boom: Error {}
    var threw = false
    do {
      _ = try await refresh(
        db, pass: pass,
        injections: .init(afterAdoption: { throw Boom() }))
      XCTFail("the injected failure should propagate")
    } catch {
      threw = true
    }
    XCTAssertTrue(threw)

    // The rolled-back transaction left nothing behind, and a clean retry succeeds.
    XCTAssertEqual(try ownershipState(db, key: "ownership_ready"), nil)
    XCTAssertEqual(try ownedIngredientCount(db), 0)
    let outcome = try await refresh(db, pass: pass)
    XCTAssertEqual(outcome.ingredientsAdopted, 3)
    XCTAssertEqual(outcome.recipesAdopted, 1)
  }

  func testPassConstructionKeepsPinnedCatalogsOutOfTheCurrentCatalog() {
    let older = decodeData(Self.fixtureDataJSON)
    let catalogA = decodeFixtureCatalog()
    let pins = [
      makePin(slug: "v0", data: older, catalog: []),
      makePin(slug: "v1", data: decodeData(Self.fixtureDataJSON), catalog: catalogA),
    ]
    let currentCatalog = decodeFixtureCatalog().map { raw in
      LegacyCatalogIngredient(
        fdcId: raw.fdcId, name: raw.name, calories: raw.calories + 5.0, protein: raw.protein,
        carbs: raw.carbs, fat: raw.fat, fiber: raw.fiber, sugar: raw.sugar, sodium: raw.sodium,
        notes: raw.notes, description: raw.description, categoryLabel: raw.categoryLabel,
        spriteGroup: raw.spriteGroup, spriteKey: raw.spriteKey)
    }

    let matched = BundledDataRefresher.loadCurrentPass(
      current: decodeData(Self.fixtureDataJSON),
      currentDataSha256: "sha-v1",
      currentCatalog: currentCatalog,
      pins: pins)
    XCTAssertEqual(
      matched.catalog.map(\.calories), currentCatalog.map(\.calories),
      "the pass applies the shipped current catalog, not the matching pin's export")

    let unmatched = BundledDataRefresher.loadCurrentPass(
      current: decodeData(Self.fixtureDataJSON),
      currentDataSha256: "unpinned",
      currentCatalog: currentCatalog,
      pins: pins)
    XCTAssertEqual(
      unmatched.catalog.map(\.calories), currentCatalog.map(\.calories),
      "no matching pin must not resurrect a pinned export as the current catalog")
  }

  // MARK: - Historical-snapshot readiness gate

  /// The pass must refuse before any write while snapshot readiness is pending:
  /// no adoption, no updates, no markers, no diagnostics.
  func testRefreshRefusesWithoutSnapshotReadinessAndWritesNothing() async throws {
    let db = try makeLegacyDatabase()
    let pass = makePass(
      current: decodeData(Self.changedDataJSON),
      pins: [makePin(slug: "v1", data: decodeData(Self.fixtureDataJSON))])

    do {
      _ = try await refresh(db, pass: pass, readiness: .pending)
      XCTFail("refresh must refuse without snapshot readiness")
    } catch {
      // expected: fail-closed refusal
    }

    try await db.read { db in
      let ownedRows = try Int.fetchOne(
        db, sql: """
          SELECT (SELECT COUNT(*) FROM ingredients WHERE ownership_key IS NOT NULL)
               + (SELECT COUNT(*) FROM recipes WHERE ownership_key IS NOT NULL)
          """)
      XCTAssertEqual(ownedRows, 0, "refusal must not adopt anything")
      let markers = try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bundled_recipe_state
          WHERE key IN ('ownership_ready', 'adoption_completed_at')
          """)
      XCTAssertEqual(markers, 0, "refusal must not write state markers")
      let diagnostics = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM bundle_refresh_diagnostics")
      XCTAssertEqual(diagnostics, 0, "refusal must not write diagnostics")
      let recipeRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes")
      XCTAssertEqual(recipeRows, 1, "refusal must not apply the current payload")
    }
  }

  /// A granted readiness lets the pass write. The catalog it applies is the one
  /// this build ships — never a pin's export — even when the current payload
  /// matches the newest pin exactly; pins still do their adoption job.
  func testTwoVersionPassAppliesCurrentCatalogNotPinnedCatalog() async throws {
    let db = try makeLegacyDatabase()
    let legacyCatalog = decodeFixtureCatalog()  // tofu, calories 76
    let correctedCatalog = [LegacyCatalogIngredient(
      fdcId: 167606, name: "tofu", calories: 90.0, protein: 8.0, carbs: 1.9, fat: 4.8,
      fiber: 0.3, sugar: 0.6, sodium: 0.007, notes: "SR Legacy", description: "firm block",
      categoryLabel: "Protein", spriteGroup: "protein", spriteKey: "tofu")]
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                                   typical_unit, storage_tip, pairs_with, notes, description,
                                   category_label, sprite_group, sprite_key,
                                   ownership_key, bundle_content_hash)
          VALUES (503, 'tofu', 76.0, 8.0, 1.9, 4.8, 0.3, 0.6, 0.007, NULL, NULL, NULL,
                  'SR Legacy', 'firm block', 'Protein', 'protein', 'tofu', ?, ?)
          """,
        arguments: [
          BundleOwnership.usdaIngredientKey(fdcId: 167606),
          CanonicalHash.hash(fields: BundleRowProjection.catalogIngredientFields(legacyCatalog[0])),
        ])
    }

    let current = decodeData(Self.changedDataJSON)
    let v1Pin = makePin(slug: "v1", data: decodeData(Self.fixtureDataJSON), catalog: legacyCatalog)
    let v2Pin = makePin(slug: "v2", data: current, catalog: legacyCatalog)
    let pass = BundledDataRefresher.loadCurrentPass(
      current: current,
      currentDataSha256: v2Pin.dataSha256,
      currentCatalog: correctedCatalog,
      pins: [v1Pin, v2Pin])
    _ = try await refresh(db, pass: pass)

    try await db.read { db in
      let tofu = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 503")!
      let calories: Double = tofu["calories"]
      XCTAssertEqual(calories, 90.0, "the shipped corrected catalog must be applied")
      let ownershipKey: String = tofu["ownership_key"]
      XCTAssertEqual(ownershipKey, BundleOwnership.usdaIngredientKey(fdcId: 167606))
      let egg = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 500")!
      let eggKey: String? = egg["ownership_key"]
      XCTAssertEqual(
        eggKey, BundleOwnership.ingredientKey(bundleIngredientId: 1),
        "pins still do their adoption job")
    }
  }

  /// Explicit `.pending` readiness keeps the refresh fail-closed: hydration
  /// still equips the database, but the refresh pass is refused and no refresh
  /// markers are written. (The launch default is now the production
  /// provider; this pins the refusal contract the provider replaced.)
  func testLaunchPathWithPendingReadinessRefusesTheRefreshPass() async throws {
    let db = try makeLegacyDatabase()
    let appDB = AppDatabase(dbQueue: db)

    try await appDB.warmBundledContentIfNeeded(readiness: .pending)

    try await db.read { db in
      let markers = try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bundled_recipe_state
          WHERE key IN ('ownership_ready', 'adoption_completed_at')
          """)
      XCTAssertEqual(markers, 0, "a pending readiness must leave the refresh refused")
    }
  }

  /// The launch default is the production readiness provider: with no meals
  /// logged, snapshot coverage holds trivially, so the refresh runs to its
  /// markers and adoption — the same outcome an established readiness gave.
  func testLaunchPathDefaultsToTheHistoricalNutritionReadinessProvider() async throws {
    let db = try makeLegacyDatabase(matchingRealBundle: true)
    let appDB = AppDatabase(dbQueue: db)

    try await appDB.warmBundledContentIfNeeded()

    try await db.read { db in
      let markers = try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bundled_recipe_state
          WHERE key IN ('ownership_ready', 'adoption_completed_at')
          """)
      XCTAssertEqual(markers, 2, "the production provider admits the refresh")
      let egg = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 500")!
      let eggKey: String? = egg["ownership_key"]
      XCTAssertEqual(eggKey, BundleOwnership.ingredientKey(bundleIngredientId: 1))
    }
  }

  // MARK: - Changed-bundle invariance (journal / daily / Health)

  /// A refresh that really changes bundle-derived content must not move a
  /// single Double bit in historical output. Snapshot lines freeze at capture,
  /// so the journal (cookingJournal), the daily chart (dailyMacroTotals), and
  /// the Apple Health record source (capturedMacros × consumed × portion,
  /// the arithmetic MealLogSyncCoordinator feeds AppleHealthMealRecord) must
  /// read bit-identical values after the refresh updates the catalog under
  /// the meal.
  func testChangedBundleRefreshKeepsJournalDailyAndHealthOutputsBitIdentical()
  async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    _ = try await refresh(
      db, pass: makePass(current: payload, pins: [makePin(data: payload)]))

    // Log a meal with a fixture-style history insert and capture its nutrition
    // snapshot in the same transaction (the project's fixture rule for
    // cooking-history rows).
    let snapshotService = NutritionSnapshotService(db: db)
    // The bundle id is an ownership key, not the row id: resolve the row the
    // refresher actually created for 'Egg Bowl'.
    let eggBowlRowId = try await db.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT id FROM recipes WHERE ownership_key = 'fridgeluck.bundle.recipe/7'")
    }!
    try await db.write { db in
      try db.execute(
        sql: """
          INSERT INTO cooking_history
            (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier)
          VALUES (?, ?, datetime('now'), NULL, 2, 1.5)
          """,
        arguments: [Int64(1), eggBowlRowId])
      try snapshotService.captureSnapshot(in: db, historyId: 1, recipeId: eggBowlRowId)
    }

    let repository = UserDataRepository(db: db)
    let preJournal = try repository.cookingJournal()
    let preDaily = try repository.dailyMacroTotals(lastDays: 1)
    let preCaptured = try snapshotService.capturedMacros(historyId: 1)
    // MealLogSyncCoordinator: scale = Double(max(1, servingsConsumed)) * portion.
    let scale = Double(max(1, 2)) * 1.5

    XCTAssertGreaterThan(preJournal.count, 0, "journal must be non-empty pre-refresh")
    XCTAssertGreaterThan(preJournal[0].macrosConsumed.calories, 0)
    XCTAssertGreaterThan(preDaily.first?.calories ?? 0, 0, "daily must sum the meal")
    XCTAssertGreaterThan(preCaptured.caloriesPerServing, 0)

    // The changed bundle: rice's protein moves 2.7 -> 3.0 in the shipped
    // payload. Only the machine-generated fixture digit changes.
    var changedJSON = Self.fixtureDataJSON
    XCTAssertTrue(changedJSON.contains("\"rice\", 130.0, 2.7"))
    changedJSON = changedJSON.replacingOccurrences(
      of: "\"rice\", 130.0, 2.7", with: "\"rice\", 130.0, 3.0")
    let changedPayload = decodeData(changedJSON)

    _ = try await refresh(
      db,
      pass: makePass(current: changedPayload, pins: [makePin(data: payload)]))

    // The refresh really changed bundle-derived content.
    try await db.read { db in
      let riceProtein = try Double.fetchOne(
        db, sql: "SELECT protein FROM ingredients WHERE name = 'rice'")
      XCTAssertEqual(riceProtein, 3.0, "the refresh must change the catalog under the meal")
    }

    let postJournal = try repository.cookingJournal()
    let postDaily = try repository.dailyMacroTotals(lastDays: 1)
    let postCaptured = try snapshotService.capturedMacros(historyId: 1)

    // Journal: same meal, bit-identical frozen macros.
    XCTAssertEqual(postJournal.count, preJournal.count)
    XCTAssertEqual(postJournal[0].id, preJournal[0].id)
    XCTAssertEqual(postJournal[0].recipe.id, preJournal[0].recipe.id)
    XCTAssertEqual(postJournal[0].recipe.title, "Egg Bowl")
    XCTAssertEqual(
      postJournal[0].macrosConsumed.calories.bitPattern,
      preJournal[0].macrosConsumed.calories.bitPattern, "journal calories")
    XCTAssertEqual(
      postJournal[0].macrosConsumed.protein.bitPattern,
      preJournal[0].macrosConsumed.protein.bitPattern, "journal protein")
    XCTAssertEqual(
      postJournal[0].macrosConsumed.carbs.bitPattern,
      preJournal[0].macrosConsumed.carbs.bitPattern, "journal carbs")
    XCTAssertEqual(
      postJournal[0].macrosConsumed.fat.bitPattern,
      preJournal[0].macrosConsumed.fat.bitPattern, "journal fat")

    // Daily chart: bit-identical sums.
    XCTAssertEqual(postDaily.count, preDaily.count)
    for (pre, post) in zip(preDaily, postDaily) {
      XCTAssertEqual(post.calories.bitPattern, pre.calories.bitPattern, "daily calories")
      XCTAssertEqual(post.protein.bitPattern, pre.protein.bitPattern, "daily protein")
      XCTAssertEqual(post.carbs.bitPattern, pre.carbs.bitPattern, "daily carbs")
      XCTAssertEqual(post.fat.bitPattern, pre.fat.bitPattern, "daily fat")
    }

    // Apple Health record source: bit-identical per-serving values, and the
    // scaled record doubles the coordinator would write.
    func healthBits(_ m: RecipeMacros) -> [UInt64] {
      [
        m.caloriesPerServing * scale, m.proteinPerServing * scale,
        m.carbsPerServing * scale, m.fatPerServing * scale,
        m.fiberPerServing * scale, m.sugarPerServing * scale,
        m.sodiumPerServing * scale,
      ].map(\.bitPattern)
    }
    XCTAssertEqual(healthBits(postCaptured), healthBits(preCaptured), "Health record doubles")
  }

  // MARK: - Full launch path on real bundle resources

  func testWarmBundledContentIfNeededEquipsAFreshInstallEndToEnd() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let appDB = AppDatabase(dbQueue: db)

    try await appDB.warmBundledContentIfNeeded(readiness: .ready)

    try await assertEveryShippedEntryIsOwnedOrExplained(appDB)
    // A second launch re-runs everything without changing a thing.
    let outcome = try await appDB.warmBundledContentOutcomeAfterRerun()
    XCTAssertEqual(outcome.ingredientsAdopted, 0)
    XCTAssertEqual(outcome.recipesAdopted, 0)
    XCTAssertEqual(outcome.ingredientsUpdated, 0)
    XCTAssertEqual(outcome.recipesUpdated, 0)
    XCTAssertEqual(outcome.ingredientsInserted, 0)
    XCTAssertEqual(outcome.recipesInserted, 0)
  }

  func testWarmBundledContentIfNeededAdoptsAnUpgradedInstall() async throws {
    let db = try makeLegacyDatabase(matchingRealBundle: true)
    let appDB = AppDatabase(dbQueue: db)

    try await appDB.warmBundledContentIfNeeded(readiness: .ready)

    try await assertEveryShippedEntryIsOwnedOrExplained(appDB)
    try await db.read { db in
      // Legacy ingredient row ids were adopted onto the bundle entries their
      // content matches: row 500's real-v1 egg content earned ingredient/1.
      let legacyRow = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 500")!
      let legacyKey: String? = legacyRow["ownership_key"]
      XCTAssertEqual(legacyKey, BundleOwnership.ingredientKey(bundleIngredientId: 1))
      // The legacy recipe's content matches no bundle version, so its row
      // survives with its own id — unowned, but explained.
      let legacyRecipe = try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = 900")!
      let legacyRecipeKey: String? = legacyRecipe["ownership_key"]
      XCTAssertNil(legacyRecipeKey)
      let explained = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM bundle_refresh_diagnostics WHERE entity_ref = 'recipe/legacy:900'")
      XCTAssertGreaterThan(explained ?? 0, 0)
    }
  }

  /// After a full launch pass on the real bundle resources, every data.json and
  /// catalog entry must be owned by a row — or explained by a diagnostic. This
  /// mirrors the pass's own postcondition, re-derived from the shipped payloads.
  private func assertEveryShippedEntryIsOwnedOrExplained(_ appDB: AppDatabase) async throws {
    guard let dataUrl = Bundle.main.url(forResource: "data", withExtension: "json") else {
      XCTFail("data.json missing from the test host bundle")
      return
    }
    let payload = try JSONDecoder().decode(BundledData.self, from: try Data(contentsOf: dataUrl))
    guard let pinsDirectory = Bundle.main.url(forResource: "LegacyBundles", withExtension: nil)
    else {
      XCTFail("LegacyBundles folder missing from the test host bundle")
      return
    }
    let pins = try LegacyBundlePins.load(from: pinsDirectory)

    try await appDB.dbQueue.read { db in
      func isOwned(_ key: String) throws -> Bool {
        let ingredientRows = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM ingredients WHERE ownership_key = ?", arguments: [key])
          ?? 0
        let recipeRows = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM recipes WHERE ownership_key = ?", arguments: [key]) ?? 0
        return ingredientRows + recipeRows > 0
      }
      func isExplained(_ key: String) throws -> Bool {
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM bundle_refresh_diagnostics
            WHERE entity_ref = ? AND code = 'blocked_by_unadopted_row'
            """,
          arguments: [key]) ?? 0 > 0
      }

      for (idString, raw) in payload.ingredients {
        guard let id = Int(idString) else { continue }
        let key = BundleOwnership.ingredientKey(bundleIngredientId: id)
        XCTAssertTrue(
          try isOwned(key) || isExplained(key),
          "ingredient entry \(id) (\(raw.name)) is neither owned nor explained")
      }
      for raw in payload.recipes {
        let key = BundleOwnership.recipeKey(bundleRecipeId: raw.id)
        XCTAssertTrue(
          try isOwned(key) || isExplained(key),
          "recipe entry \(raw.id) (\(raw.title)) is neither owned nor explained")
      }
      for pin in pins {
        for entry in pin.catalog {
          let key = BundleOwnership.usdaIngredientKey(fdcId: entry.fdcId)
          XCTAssertTrue(
            try isOwned(key) || isExplained(key),
            "catalog entry \(entry.fdcId) (\(entry.name)) is neither owned nor explained")
        }
      }
      // Adoption-phase explanations are legitimate on a full launch path: a
      // blocked bundle entry (same-name unadopted row) and a legacy row whose
      // content matches no bundle version (unmatched_row). Anything else —
      // modified rows, name conflicts, unresolved dependencies — would mean
      // the pass guessed or lost shipped content.
      let unexpectedDiagnostics = try Row.fetchAll(
        db, sql: "SELECT code FROM bundle_refresh_diagnostics"
      )
      .filter { row -> Bool in
        let code: String = row["code"]
        return code != "blocked_by_unadopted_row" && code != "unmatched_row"
      }
      .count
      XCTAssertEqual(
        unexpectedDiagnostics, 0, "a full launch pass should not need other explanations")
    }
  }
}

// MARK: - Test seams

extension AppDatabase {
  /// Re-runs the ownership refresh and returns its counts, for idempotence checks.
  func warmBundledContentOutcomeAfterRerun() async throws -> BundledDataRefreshOutcome {
    guard let dataUrl = Bundle.main.url(forResource: "data", withExtension: "json") else {
      return BundledDataRefreshOutcome()
    }
    let jsonData = try Data(contentsOf: dataUrl)
    let bundled = try JSONDecoder().decode(BundledData.self, from: jsonData)
    guard let pinsDirectory = Bundle.main.url(forResource: "LegacyBundles", withExtension: nil)
    else {
      return BundledDataRefreshOutcome()
    }
    let pins = try LegacyBundlePins.load(from: pinsDirectory)
    let currentCatalog: [LegacyCatalogIngredient]
    if let catalogUrl = Bundle.main.url(
      forResource: "usda_ingredient_catalog", withExtension: "sqlite")
    {
      currentCatalog = try BundledDataLoader.currentCatalogIngredients(from: catalogUrl)
    } else {
      currentCatalog = []
    }
    let pass = BundledDataRefresher.loadCurrentPass(
      current: bundled,
      currentDataSha256: LegacyBundlePins.sha256Hex(jsonData),
      currentCatalog: currentCatalog,
      pins: pins)
    return try await BundledDataRefresher.refresh(appDB: self, pass: pass, readiness: .ready)
  }
}
