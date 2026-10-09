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
    catalog: [LegacyCatalogIngredient]? = nil
  ) -> BundledDataRefresher.Pass {
    BundledDataRefresher.Pass(
      current: current,
      currentDataSha256: "current-sha",
      catalog: catalog ?? pins.last?.catalog ?? [],
      pins: pins)
  }

  /// A database with all migrations applied and legacy-shaped content: the
  /// ingredients were hydrated by an old release with row ids that no longer
  /// match bundle ids, and the recipe row has an unrelated autoincrement id.
  private func makeLegacyDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                                   typical_unit, storage_tip)
          VALUES
            (500, 'egg', 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, 'piece', 'keep cold'),
            (501, 'rice', 130.0, 2.7, 28.0, 0.3, 0.4, 0.1, 0.001, 'cup', 'dry pantry'),
            (502, 'seaweed', 20.0, 0.6, 3.0, 0.2, 0.5, 0.1, 8.7, 'sheet', 'dry pantry');
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
    injections: BundledDataRefresher.InjectionPoints = .init()
  ) async throws -> BundledDataRefreshOutcome {
    try await BundledDataRefresher.refresh(
      appDB: AppDatabase(dbQueue: db), pass: pass, injections: injections)
  }

  private func diagnostics(_ db: DatabaseQueue) throws -> [(ref: String, code: String)] {
    try db.read { db in
      try Row.fetchAll(
        db, sql: "SELECT entity_ref, code FROM bundle_refresh_diagnostics ORDER BY entity_ref, code"
      )
      .map { row -> (ref: String, code: String) in
        let ref: String = row["entity_ref"]
        let code: String = row["code"]
        return (ref: ref, code: code)
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
    let hasDiagnostics = try db.read { $0.tableExists("bundle_refresh_diagnostics") }
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
      try db.execute(sql: "INSERT INTO ingredients (id, name) VALUES (1, 'a'), (2, 'b')")
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

    try db.read { db in
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

  func testAmbiguousLegacyRowsStayUnownedWithDiagnostics() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    try db.write { db in
      // Two rows reproduce one bundle entry: content matches, identity cannot.
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat, fiber, sugar, sodium,
                                   typical_unit, storage_tip)
          VALUES
            (600, 'egg', 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, 'piece', 'keep cold'),
            (601, 'egg', 140.0, 12.0, 1.0, 10.0, 0.0, 0.0, 0.14, 'piece', 'keep cold');
          """)
    }

    _ = try await refresh(db, pass: makePass(current: payload, pins: [makePin(data: payload)]))

    try db.read { db in
      let keys = try Row.fetchAll(
        db, sql: "SELECT id, ownership_key FROM ingredients WHERE name = 'egg' ORDER BY id"
      )
      .compactMap { row -> String? in
        let key: String? = row["ownership_key"]
        return key
      }
      XCTAssertEqual(keys, ["fridgeluck.bundle.ingredient/1"], "exactly one row wins")
    }
    XCTAssertEqual(try diagnostics(db).map(\.code), ["duplicate_adoption_target"])
  }

  func testUnmatchedLegacyRowGetsADIagnosticAndStaysUnowned() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let payload = decodeData(Self.fixtureDataJSON)
    try db.write { db in
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein) VALUES (700, 'egg', 999.0, 1.0)"
      )
    }

    _ = try await refresh(db, pass: makePass(current: payload, pins: [makePin(data: payload)]))

    XCTAssertEqual(try diagnostics(db).map(\.code), ["unmatched_row"])
    try db.read { db in
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
    try db.read { db in
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
    try db.read { db in
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
    try db.write { db in
      try db.execute(
        sql:
          "UPDATE recipes SET instructions = 'my own version' WHERE ownership_key = 'fridgeluck.bundle.recipe/7'"
      )
    }
    let thirdOutcome = try await refresh(
      db, pass: makePass(current: changedPayload, pins: [pin]))
    XCTAssertEqual(thirdOutcome.recipesUpdated, 0)
    try db.read { db in
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
    try db.write { db in
      // A legacy row the adoption could not match (different content) blocks the
      // catalog entry of the same name rather than stealing or duplicating it.
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories) VALUES (800, 'tofu', 1.0)")
    }

    _ = try await refresh(
      db, pass: makePass(current: payload, pins: [makePin(data: payload, catalog: catalog)]))

    XCTAssertEqual(try diagnostics(db).map(\.code), ["blocked_by_unadopted_row"])
    try db.read { db in
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
    try db.write { db in
      // A row owned by a different bundle entry already holds the name.
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, ownership_key, bundle_content_hash)
          VALUES (900, 'tofu', 1.0, 'fridgeluck.bundle.ingredient/404', 'deadbeef')
          """)
    }

    _ = try await refresh(
      db, pass: makePass(current: payload, pins: [makePin(data: payload, catalog: catalog)]))

    XCTAssertTrue(
      try diagnostics(db)
        .contains { $0.ref == "usda.fdc/167606" && $0.code == "name_conflict" })
    try db.read { db in
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
    try db.read { db in
      let kept = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ingredients WHERE id = 502")
      XCTAssertEqual(kept, 1, "rows are never deleted")
    }
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

  func testPassConstructionPrefersThePinMatchingTheCurrentPayload() {
    let older = decodeData(Self.fixtureDataJSON)
    let catalogA = decodeFixtureCatalog()
    let pins = [
      makePin(slug: "v0", data: older, catalog: []),
      makePin(slug: "v1", data: decodeData(Self.fixtureDataJSON), catalog: catalogA),
    ]

    let matched = BundledDataRefresher.loadCurrentPass(
      current: decodeData(Self.fixtureDataJSON), currentDataSha256: "sha-v1", pins: pins)
    XCTAssertEqual(matched.catalog.map(\.fdcId), catalogA.map(\.fdcId))

    let unmatched = BundledDataRefresher.loadCurrentPass(
      current: decodeData(Self.fixtureDataJSON), currentDataSha256: "unpinned", pins: pins)
    XCTAssertEqual(
      unmatched.catalog.map(\.fdcId), catalogA.map(\.fdcId),
      "no matching pin: the most recent pin's catalog describes the shipped catalog")
  }

  // MARK: - Full launch path on real bundle resources

  func testWarmBundledContentIfNeededEquipsAFreshInstallEndToEnd() async throws {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    let appDB = AppDatabase(dbQueue: db)

    try await appDB.warmBundledContentIfNeeded()

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
    let db = try makeLegacyDatabase()
    let appDB = AppDatabase(dbQueue: db)

    try await appDB.warmBundledContentIfNeeded()

    try await assertEveryShippedEntryIsOwnedOrExplained(appDB)
    try db.read { db in
      // Legacy row ids survived the whole launch path.
      let legacyRow = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 500")!
      let legacyKey: String? = legacyRow["ownership_key"]
      XCTAssertNotNil(legacyKey)
      let legacyRecipe = try Row.fetchOne(db, sql: "SELECT * FROM recipes WHERE id = 900")!
      let legacyRecipeKey: String? = legacyRecipe["ownership_key"]
      XCTAssertNotNil(legacyRecipeKey)
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
      let unexpectedDiagnostics = try Row.fetchAll(
        db, sql: "SELECT code FROM bundle_refresh_diagnostics"
      )
      .filter { row -> Bool in
        let code: String = row["code"]
        return code != "blocked_by_unadopted_row"
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
    let pass = BundledDataRefresher.loadCurrentPass(
      current: bundled,
      currentDataSha256: LegacyBundlePins.sha256Hex(jsonData),
      pins: pins)
    return try await BundledDataRefresher.refresh(appDB: self, pass: pass)
  }
}
