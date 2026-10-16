import GRDB
import XCTest

@testable import FridgeLuck
import FLFeatureLogic

/// Persistence side: cook-plan migrations apply, plans round-trip through `cook_plan*` tables,
/// and the adapter snapshot reads recipes, lots, staples, and allergens with honest semantics.
final class LeChefPlanPersistenceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeDatabase() throws -> DatabaseQueue {
    // Production always registers the cook migrations after the core v1 schema, and the adapter
    // reads recipe titles from it, so the plan-only fixture carries the minimal core table.
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_planfixtures_recipes") { db in
      try db.create(table: "recipes") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("title", .text).notNull()
        t.column("time_minutes", .integer).notNull()
        t.column("servings", .integer).notNull().defaults(to: 1)
        t.column("instructions", .text).notNull()
      }
    }
    try migrator.migrate(dbQueue)
    try CookSessionMigrations.migrate(dbQueue)
    return dbQueue
  }

  /// Seeds the core v1 schema pieces the adapter reads. Uses the production migrator's v1
  /// migration by running it on a fresh queue, then appends cook migrations.
  private func makeCoreDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_seedhelper") { db in
      try db.create(table: "recipes") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("title", .text).notNull()
        t.column("time_minutes", .integer).notNull()
        t.column("servings", .integer).notNull().defaults(to: 1)
        t.column("instructions", .text).notNull()
        t.column("tags", .integer).defaults(to: 0)
        t.column("source", .text).defaults(to: "bundled")
        t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }
      try db.create(table: "ingredients") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull().unique()
        t.column("calories", .double).notNull()
        t.column("protein", .double).notNull()
        t.column("carbs", .double).notNull()
        t.column("fat", .double).notNull()
        t.column("fiber", .double).defaults(to: 0)
        t.column("sugar", .double).defaults(to: 0)
        t.column("sodium", .double).defaults(to: 0)
      }
      try db.create(table: "recipe_ingredients") { t in
        t.column("recipe_id", .integer).notNull().references("recipes", onDelete: .cascade)
        t.column("ingredient_id", .integer).notNull().references("ingredients")
        t.column("is_required", .boolean).notNull().defaults(to: true)
        t.column("quantity_grams", .double).notNull()
        t.column("display_quantity", .text).notNull()
        t.primaryKey(["recipe_id", "ingredient_id"])
      }
      try db.create(table: "health_profile") { t in
        t.primaryKey("id", .integer, onConflict: .replace).check { $0 == 1 }
        t.column("goal", .text).defaults(to: "general")
        t.column("dietary_restrictions", .text).defaults(to: "[]")
        t.column("allergen_ingredient_ids", .text).defaults(to: "[]")
        t.column("updated_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
      }
      try db.create(table: "pantry_assumptions") { t in
        t.column("ingredient_id", .integer).notNull().references("ingredients", onDelete: .cascade)
        t.column("tier", .text).notNull().defaults(to: "only_if_confirmed")
        t.column("added_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
        t.primaryKey(["ingredient_id"])
      }
      try db.create(table: "inventory_lots") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("ingredient_id", .integer).notNull().references("ingredients", onDelete: .cascade)
        t.column("quantity_grams", .double).notNull()
        t.column("remaining_grams", .double).notNull()
        t.column("storage_location", .text).notNull().defaults(to: "unknown")
        t.column("confidence_score", .double).notNull().defaults(to: 1.0)
        // Production v16's column, mirrored here so the fixture matches the schema the
        // adapter actually runs against.
        t.column("quantity_is_estimate", .boolean).notNull().defaults(to: false)
        t.column("source", .text).notNull().defaults(to: "manual")
        t.column("acquired_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("expires_at", .datetime)
        t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }
    }
    // The adapter's snapshot read now also covers the recipe-catalog tables; the fixture
    // creates the same shape production's catalog migrations do.
    migrator.registerMigration("catalog_seedhelper") { db in
      try db.create(table: "recipes_catalog_ingredients") { t in
        t.primaryKey("key", .text)
        t.column("fdc_id", .integer)
        t.column("legacy_id", .integer)
        t.column("display_name", .text).notNull()
        t.column("category", .text).notNull()
        t.column("aliases", .text).notNull().defaults(to: "[]")
      }
      try db.create(table: "recipes_catalog") { t in
        t.primaryKey("catalog_id", .text)
        t.column("revision", .integer).notNull()
        t.column("title", .text).notNull()
        t.column("cuisine", .text).notNull()
        t.column("minutes", .integer).notNull()
        t.column("servings", .integer).notNull()
        t.column("claims", .text).notNull()
        t.column("nutrition", .text)
        t.column("rights_status", .text).notNull()
        t.column("rights_evidence", .text).notNull()
        t.column("legacy_recipe_id", .integer).references("recipes", onDelete: .setNull)
      }
      try db.create(table: "recipes_catalog_lines") { t in
        t.primaryKey(["catalog_id", "position"])
        t.column("catalog_id", .text).notNull().references("recipes_catalog", onDelete: .cascade)
        t.column("position", .integer).notNull()
        t.column("ingredient_key", .text)
        t.column("quantity_kind", .text).notNull()
        t.column("quantity_grams", .double)
        t.column("is_required", .boolean).notNull().defaults(to: true)
        t.column("assumed_staple", .boolean).notNull().defaults(to: false)
      }
      try db.create(table: "recipes_catalog_ingredient_bridge") { t in
        t.column("ingredient_key", .text).notNull()
          .references("recipes_catalog_ingredients", onDelete: .cascade)
        t.column("ingredient_id", .integer).notNull().references("ingredients", onDelete: .cascade)
        t.column("resolved_by", .text).notNull()
        t.primaryKey(["ingredient_key", "ingredient_id"])
      }
    }
    try migrator.migrate(dbQueue)
    try CookSessionMigrations.migrate(dbQueue)
    return dbQueue
  }

  private func insertRecipe(
    _ db: Database, id: Int64, title: String, minutes: Int = 30, servings: Int = 2,
    lines: [(ingredientID: Int64, name: String, grams: Double, required: Bool)]
  ) throws {
    try db.execute(
      sql: "INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES (?, ?, ?, ?, '')",
      arguments: [id, title, minutes, servings])
    for ingredient in lines {
      try db.execute(
        sql: "INSERT OR IGNORE INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (?, ?, 0, 0, 0, 0)",
        arguments: [ingredient.ingredientID, ingredient.name])
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (?, ?, ?, ?, 'x')
          """,
        arguments: [id, ingredient.ingredientID, ingredient.required, ingredient.grams])
    }
  }

  private func insertLot(
    _ db: Database, ingredientID: Int64, grams: Double, confidence: Double = 1.0,
    expiresIn: Double? = nil
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO inventory_lots (ingredient_id, quantity_grams, remaining_grams, confidence_score, expires_at)
        VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        ingredientID, grams, grams, confidence,
        expiresIn.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
      ])
  }

  // MARK: - Migrations

  func testCookMigrationsApplyTwiceIsHarmlessBecauseVersioned() throws {
    // The same queue must tolerate a second migrate call: versioned migrations are a no-op.
    let dbQueue = try DatabaseQueue()
    try CookSessionMigrations.migrate(dbQueue)
    try CookSessionMigrations.migrate(dbQueue)
  }

  func testPlanTablesRejectOutOfRangeHorizon() throws {
    let dbQueue = try makeDatabase()
    XCTAssertThrowsError(
      try dbQueue.write { db in
        try db.execute(
          sql: "INSERT INTO cook_plan (id, created_at, horizon_dinners) VALUES ('plan_x', ?, 9)",
          arguments: [now])
      })
  }

  // MARK: - Round trip

  func testPlanSavesAndLoadsBackLineByLine() throws {
    let dbQueue = try makeDatabase()
    let dinnerLines = [
      PlanLine(
        ingredientID: 10, name: "rice", isRequired: true,
        required: PlanQuantity(value: 200), lineState: .sufficient, short: nil, swap: nil),
      PlanLine(
        ingredientID: 11, name: "butter", isRequired: true,
        required: PlanQuantity(value: 300), lineState: .short,
        short: PlanQuantity(value: 100), swap: nil),
      PlanLine(
        ingredientID: 12, name: "salt", isRequired: true, required: nil,
        lineState: .quantityUnknown, short: nil, swap: nil),
      PlanLine(
        ingredientID: 13, name: "olive oil", isRequired: true,
        required: PlanQuantity(value: 20), lineState: .assumedStaple, short: nil, swap: nil),
      PlanLine(
        ingredientID: 14, name: "lemon", isRequired: true,
        required: PlanQuantity(value: 50), lineState: .needsReconfirming, short: nil, swap: nil),
      PlanLine(
        ingredientID: 15, name: "tofu", isRequired: true,
        required: PlanQuantity(value: 200), lineState: .sufficient, short: nil,
        swap: PlanSwap(originalID: 16, substituteID: 15, note: "for chicken", reviewed: true)),
    ]
    try dbQueue.write { db in
      // The plan references recipe 42; the title joins from the core table on load.
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, instructions) VALUES (42, 'Fried rice', 25, '')")
    }
    let plan = LeChefPlan(
      planID: "plan_roundtrip", createdAt: now,
      dinners: [
        PlannedDinner(
          position: 1, dinnerID: "plan_roundtrip-d1",
          recipe: RecipeRef(source: .catalog, id: "42", revision: 1), recipeDatabaseID: 42,
          title: "Fried rice", servings: 2, timeMinutes: 25, lines: dinnerLines)
      ],
      shoppingList: [
        ShoppingLine(
          ingredientID: 11, name: "butter", amount: PlanQuantity(value: 100),
          assumedStaple: false)
      ],
      fitSummary: PlanFitSummary(
        sufficientLines: 3, totalLines: 6, swapCount: 1,
        attention: ["butter", "salt", "olive oil", "lemon"]))

    try dbQueue.write { db in try PlanDataAdapter.save(plan, in: db) }
    let loaded = try PlanDataAdapter(dbQueue: dbQueue, now: now).load(planID: "plan_roundtrip")
    let restored = try XCTUnwrap(loaded)
    XCTAssertEqual(restored.planID, "plan_roundtrip")
    XCTAssertEqual(restored.createdAt, now)
    XCTAssertEqual(restored.fitSummary.sufficientLines, 3)
    XCTAssertEqual(restored.fitSummary.totalLines, 6)
    XCTAssertEqual(restored.dinners.count, 1)
    let dinner = restored.dinners[0]
    XCTAssertEqual(dinner.servings, 2)
    XCTAssertEqual(dinner.recipe.id, "42")
    XCTAssertEqual(dinner.lines.count, 6)
    XCTAssertEqual(dinner.lines[1].lineState, .short)
    XCTAssertEqual(dinner.lines[1].short?.value ?? 0, 100, accuracy: 0.001)
    XCTAssertEqual(dinner.lines[2].lineState, .quantityUnknown)
    XCTAssertEqual(dinner.lines[3].lineState, .assumedStaple)
    XCTAssertEqual(dinner.lines[4].lineState, .needsReconfirming)
    XCTAssertEqual(dinner.lines[5].swap?.substituteID, 15)
    XCTAssertEqual(dinner.lines[5].swap?.reviewed, true)
    // A restored plan rebuilds its title and shopping list from the stored record rather than
    // losing them: titles join from recipes, the list merges the stored line states.
    XCTAssertEqual(dinner.title, "Fried rice")
    XCTAssertEqual(
      restored.shoppingList,
      [
        ShoppingLine(
          ingredientID: 11, name: "butter", amount: PlanQuantity(value: 100), assumedStaple: false),
        ShoppingLine(
          ingredientID: 13, name: "olive oil", amount: PlanQuantity(value: 20), assumedStaple: true),
      ])
  }

  func testSavingTheSamePlanIDReplacesTheRecord() throws {
    let dbQueue = try makeDatabase()
    func makePlan(lines: Int) -> LeChefPlan {
      LeChefPlan(
        planID: "plan_replace", createdAt: now,
        dinners: [
          PlannedDinner(
            position: 1, dinnerID: "plan_replace-d1",
            recipe: RecipeRef(source: .catalog, id: "1", revision: 1), recipeDatabaseID: 1,
            title: "A", servings: 2, timeMinutes: 10,
            lines: (0..<lines).map { index in
              PlanLine(
                ingredientID: Int64(10 + index), name: "i\(index)", isRequired: true,
                required: PlanQuantity(value: 10), lineState: .sufficient, short: nil, swap: nil)
            })
        ], shoppingList: [],
        fitSummary: PlanFitSummary(sufficientLines: lines, totalLines: lines, swapCount: 0, attention: nil))
    }
    try dbQueue.write { db in try PlanDataAdapter.save(makePlan(lines: 1), in: db) }
    try dbQueue.write { db in try PlanDataAdapter.save(makePlan(lines: 3), in: db) }
    let loaded = try PlanDataAdapter(dbQueue: dbQueue, now: now).load(planID: "plan_replace")
    XCTAssertEqual(loaded?.dinners[0].lines.count, 3)
    let count = try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cook_plan WHERE id = 'plan_replace'")
    }
    XCTAssertEqual(count, 1)
  }

  // MARK: - Review round (comment 6199711301)

  func testProductionSchemaDrivesEstimateTaintNotConfidence() throws {
    // Production v16's inventory_lots.quantity_is_estimate is the authority (SPEC §7 via #142:
    // confidence never confirms a quantity). A scan-intake lot the user never reviewed stays an
    // estimate even at confidence 0.9 — its lines are needs_reconfirming, never plain sufficient.
    let dbQueue = try DatabaseQueue()
    try DatabaseMigrations.migrate(dbQueue)
    try CookSessionMigrations.migrate(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, instructions) VALUES (1, 'Sauce', 20, '')")
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (10, 'tomato', 0, 0, 0, 0)")
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (1, 10, 1, 100, 'x')
          """)
      try db.execute(
        sql: """
          INSERT INTO inventory_lots
            (ingredient_id, quantity_grams, remaining_grams, confidence_score, quantity_is_estimate)
          VALUES (10, 400, 400, 0.9, 1)
          """)
    }
    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    XCTAssertEqual(snapshot.pool.isEstimateTainted(10), true)
  }

  func testSavedPlansReserveTheirLinesFromTheSnapshotPool() throws {
    // §7 step 1: the already-planned set reserves its stock — a snapshot taken after saving a
    // plan must not offer those grams to the next allocation. A sufficient line reserves its
    // full requirement; a short line reserves the covered share (requirement minus shortfall).
    let dbQueue = try makeCoreDatabase()
    try dbQueue.write { db in
      try insertRecipe(
        db, id: 1, title: "Fried rice",
        lines: [(10, "rice", 100, true), (11, "butter", 300, true)])
      try insertLot(db, ingredientID: 10, grams: 400)
      try insertLot(db, ingredientID: 11, grams: 400)
      let reserved = LeChefPlan(
        planID: "plan_saved", createdAt: now,
        dinners: [
          PlannedDinner(
            position: 1, dinnerID: "plan_saved-d1",
            recipe: RecipeRef(source: .catalog, id: "1", revision: 1), recipeDatabaseID: 1,
            title: "Fried rice", servings: 2, timeMinutes: 30,
            lines: [
              PlanLine(
                ingredientID: 10, name: "rice", isRequired: true,
                required: PlanQuantity(value: 200), lineState: .sufficient, short: nil, swap: nil),
              PlanLine(
                ingredientID: 11, name: "butter", isRequired: true,
                required: PlanQuantity(value: 300), lineState: .short,
                short: PlanQuantity(value: 100), swap: nil),
            ])
        ], shoppingList: [],
        fitSummary: PlanFitSummary(sufficientLines: 1, totalLines: 2, swapCount: 0, attention: nil))
      try PlanDataAdapter.save(reserved, in: db)
    }
    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    XCTAssertEqual(snapshot.pool.availableGrams(10), 200, accuracy: 0.001)
    XCTAssertEqual(snapshot.pool.availableGrams(11), 200, accuracy: 0.001)
  }

  func testLoadRestoresLinesInSavedOrderBeyondTenLines() throws {
    // Line ids sort lexicographically on read; the stored format must not scramble at l10.
    let dbQueue = try makeDatabase()
    let plan = LeChefPlan(
      planID: "plan_order", createdAt: now,
      dinners: [
        PlannedDinner(
          position: 1, dinnerID: "plan_order-d1",
          recipe: RecipeRef(source: .catalog, id: "1", revision: 1), recipeDatabaseID: 1,
          title: "A", servings: 2, timeMinutes: 10,
          lines: (0..<12).map { index in
            PlanLine(
              ingredientID: Int64(10 + index), name: "i\(index)", isRequired: true,
              required: PlanQuantity(value: 10), lineState: .sufficient, short: nil, swap: nil)
          })
      ], shoppingList: [],
      fitSummary: PlanFitSummary(sufficientLines: 12, totalLines: 12, swapCount: 0, attention: nil))
    try dbQueue.write { db in try PlanDataAdapter.save(plan, in: db) }
    let loaded = try PlanDataAdapter(dbQueue: dbQueue, now: now).load(planID: "plan_order")
    XCTAssertEqual(loaded?.dinners[0].lines.map(\.ingredientID), Array(Int64(10)...21))
  }

  func testDeletingAPlanCascadesToDinnersAndLines() throws {
    let dbQueue = try makeDatabase()
    let plan = LeChefPlan(
      planID: "plan_cascade", createdAt: now,
      dinners: [
        PlannedDinner(
          position: 1, dinnerID: "plan_cascade-d1",
          recipe: RecipeRef(source: .catalog, id: "1", revision: 1), recipeDatabaseID: 1,
          title: "A", servings: 2, timeMinutes: 10,
          lines: [
            PlanLine(
              ingredientID: 10, name: "rice", isRequired: true, required: PlanQuantity(value: 10),
              lineState: .sufficient, short: nil, swap: nil)
          ])
      ], shoppingList: [],
      fitSummary: PlanFitSummary(sufficientLines: 1, totalLines: 1, swapCount: 0, attention: nil))
    try dbQueue.write { db in try PlanDataAdapter.save(plan, in: db) }
    try dbQueue.write { db in
      try db.execute(sql: "DELETE FROM cook_plan WHERE id = 'plan_cascade'")
    }
    let dinnerCount = try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cook_plan_dinner")
    }
    let lineCount = try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cook_plan_line")
    }
    XCTAssertEqual(dinnerCount, 0)
    XCTAssertEqual(lineCount, 0)
  }

  // MARK: - Snapshot read

  func testSnapshotReadsCandidatesLotsStaplesAndAllergens() throws {
    let dbQueue = try makeCoreDatabase()
    try dbQueue.write { db in
      try insertRecipe(
        db, id: 1, title: "Fried rice",
        lines: [
          (10, "rice", 200, true), (11, "egg", 100, false),
        ])
      try insertRecipe(
        db, id: 2, title: "Peanut noodles",
        lines: [(12, "peanuts", 100, true)])
      try insertLot(db, ingredientID: 10, grams: 400, expiresIn: 2 * 86_400)
      try insertLot(db, ingredientID: 11, grams: 100)
      // Low-confidence lot: a photo estimate, never a confirmed quantity. The FK needs the
      // ingredient rows to exist first.
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (13, 'cream', 0, 0, 0, 0)")
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (14, 'olive oil', 0, 0, 0, 0)")
      try insertLot(db, ingredientID: 13, grams: 300, confidence: 0.4)
      try db.execute(
        sql: "INSERT INTO pantry_assumptions (ingredient_id, tier) VALUES (?, ?)",
        arguments: [14, "always_have"])
      try db.execute(
        sql: "INSERT OR REPLACE INTO health_profile (id, allergen_ingredient_ids) VALUES (1, ?)",
        arguments: ["[12]"])
    }

    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)
    let snapshot = try adapter.loadSnapshot()

    XCTAssertEqual(snapshot.hasAnyStockLots, true)
    XCTAssertEqual(snapshot.candidates.count, 2)
    let friedRice = try XCTUnwrap(snapshot.candidates.first { $0.databaseID == 1 })
    XCTAssertEqual(friedRice.title, "Fried rice")
    XCTAssertEqual(friedRice.baseServings, 2)
    XCTAssertEqual(friedRice.lines.count, 2)

    // The peanut recipe is hard-filtered by the household allergen list.
    XCTAssertEqual(snapshot.eaters.first?.blockedIngredientIDs, [12])
    // The use-soon lot is inside the horizon and the estimate lot taints its ingredient.
    XCTAssertEqual(snapshot.pool.availableGrams(10), 400, accuracy: 0.001)
    XCTAssertEqual(snapshot.pool.availableGrams(13), 300, accuracy: 0.001)
    XCTAssertEqual(snapshot.pool.isEstimateTainted(13), true)
    XCTAssertEqual(snapshot.pool.isEstimateTainted(10), false)
    XCTAssertEqual(snapshot.stapleIngredientIDs, [14])
  }

  func testExpiredLotsLeaveThePoolButLotsExist() throws {
    let dbQueue = try makeCoreDatabase()
    try dbQueue.write { db in
      try insertRecipe(
        db, id: 1, title: "A", lines: [(10, "spinach", 100, true)])
      try insertLot(db, ingredientID: 10, grams: 200, expiresIn: -86_400)
    }
    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    XCTAssertEqual(snapshot.hasAnyStockLots, true)
    XCTAssertEqual(snapshot.pool.availableGrams(10), 0, accuracy: 0.001)
  }

  func testEmptyKitchenReportsNoLots() throws {
    let dbQueue = try makeCoreDatabase()
    try dbQueue.write { db in
      try insertRecipe(db, id: 1, title: "A", lines: [(10, "rice", 100, true)])
    }
    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    XCTAssertEqual(snapshot.hasAnyStockLots, false)
    XCTAssertEqual(snapshot.pool.availableGrams(10), 0, accuracy: 0.001)
  }
}
