import GRDB
import XCTest

@testable import FridgeLuck
import FLFeatureLogic

/// The weekly horizon (SPEC.md §14, #52 adapted): the same allocator across seven slots —
/// repeats priced, the same main two days in a row penalized, surplus servings covering a later
/// slot — plus the adapter's catalog-recipe and reviewed-substitution integration it rides on.
final class LeChefPlanWeeklyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func lot(
    _ id: Int64, _ grams: Double, expiresIn: Double? = nil
  ) -> PlanLot {
    PlanLot(
      ingredientID: id, grams: grams,
      expiresAt: expiresIn.map { now.addingTimeInterval($0) }, quantityIsEstimate: false)
  }

  private func candidate(
    _ id: Int64, title: String = "Recipe", servings: Int = 2, minutes: Int? = 30,
    lines: [PlanCandidateLine]
  ) -> PlanCandidate {
    PlanCandidate(
      databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1), title: title,
      timeMinutes: minutes, baseServings: servings, lines: lines)
  }

  private func line(_ id: Int64, name: String, grams: Double, required: Bool = true) -> PlanCandidateLine {
    PlanCandidateLine(ingredientID: id, name: name, grams: grams, isRequired: required)
  }

  private func request(
    dinners: Int, servings: [Int] = [], candidates: [PlanCandidate], pool: StockPool,
    staples: Set<Int64> = [], eaters: [PlanEater] = [],
    substitutions: [PlanSubstitution] = [], weekly: PlanWeeklyPolicy? = nil
  ) -> PlanRequest {
    PlanRequest(
      dinnerCount: dinners, servingsPerDinner: servings, candidates: candidates, eaters: eaters,
      substitutions: substitutions, stapleIngredientIDs: staples, pool: pool,
      excludeDatabaseIDs: [], weekly: weekly, planID: "plan_weekly", createdAt: now)
  }

  /// The weekly policy the view model applies for five to seven dinners.
  private var weeklyPolicy: PlanWeeklyPolicy {
    PlanWeeklyPolicy(
      eatersPerDinner: nil, repeatPenalty: PlanSheetViewModel.weeklyRepeatPenalty,
      consecutiveMainIngredientPenalty: PlanSheetViewModel.weeklyConsecutiveMainPenalty)
  }

  // MARK: - One allocator, seven slots

  func testWeeklySevenSlotsNeverDoubleCountStock() {
    // Seven candidates, each needing 300 g of the same ingredient; 700 g exist. Repeats are
    // priced, not banned, so every slot fills — and total consumption can never exceed the
    // pool: the merged shortfall is exactly demand − stock.
    let candidates = (1...7).map { index in
      candidate(Int64(index), lines: [line(10, name: "rice", grams: 300)])
    }
    let plan = PlanAllocating.allocate(
      request(
        dinners: 7, candidates: candidates, pool: StockPool(lots: [lot(10, 700)], now: now),
        weekly: weeklyPolicy))
    XCTAssertEqual(plan.dinners.count, 7)
    XCTAssertEqual(plan.shoppingList.count, 1)
    XCTAssertEqual(plan.shoppingList.first?.ingredientID, 10)
    XCTAssertEqual(plan.shoppingList.first?.amount.value ?? 0, 2_100 - 700, accuracy: 0.001)
    // Hand-computed walk: two full dinners (300 + 300), one partial (100), four empty.
    let covered = plan.dinners.compactMap { dinner in
      dinner.lines.first.map { ($0.required?.value ?? 300) - ($0.short?.value ?? 0) }
    }
    XCTAssertEqual(covered.reduce(0, +), 700, accuracy: 0.001)
    XCTAssertEqual(covered[0], 300, accuracy: 0.001)
    XCTAssertEqual(covered[2], 100, accuracy: 0.001)
  }

  func testWeeklyRepeatPenaltyKeepsTheWeekVaried() {
    // Two equally covered recipes: without the penalty the smaller id wins every slot; with it
    // a repeat drops behind the fresh alternative and returns only when nothing fresh remains.
    let a = candidate(1, lines: [line(10, name: "rice", grams: 100)])
    let b = candidate(2, lines: [line(11, name: "beans", grams: 100)])
    let pool = { StockPool(lots: [self.lot(10, 500), self.lot(11, 500)], now: self.now) }

    let priced = PlanAllocating.allocate(
      request(
        dinners: 3, candidates: [a, b], pool: pool(),
        weekly: PlanWeeklyPolicy(repeatPenalty: 1_000)))
    XCTAssertEqual(priced.dinners.map(\.recipeDatabaseID), [1, 2, 1])

    let unpriced = PlanAllocating.allocate(
      request(dinners: 3, candidates: [a, b], pool: pool(), weekly: PlanWeeklyPolicy()))
    XCTAssertEqual(unpriced.dinners.map(\.recipeDatabaseID), [1, 1, 1])
  }

  func testConsecutiveMainIngredientPenaltyBreaksBackToBackMains() {
    // Candidates 1 and 3 share the main ingredient; 2 does not. The penalty keeps the same
    // main from appearing two days in a row without banning the ingredient for the week.
    let first = candidate(1, lines: [line(10, name: "rice", grams: 100)])
    let other = candidate(2, lines: [line(11, name: "beans", grams: 100)])
    let sameAgain = candidate(3, lines: [line(10, name: "noodles", grams: 100)])
    let pool = { StockPool(lots: [self.lot(10, 500), self.lot(11, 500)], now: self.now) }

    let priced = PlanAllocating.allocate(
      request(
        dinners: 3, candidates: [first, other, sameAgain], pool: pool(),
        weekly: PlanWeeklyPolicy(repeatPenalty: 1_000, consecutiveMainIngredientPenalty: 500)))
    XCTAssertEqual(priced.dinners.map(\.recipeDatabaseID), [1, 2, 3])

    let unpriced = PlanAllocating.allocate(
      request(
        dinners: 3, candidates: [first, other, sameAgain], pool: pool(),
        weekly: PlanWeeklyPolicy(repeatPenalty: 0, consecutiveMainIngredientPenalty: 0)))
    XCTAssertEqual(unpriced.dinners.map(\.recipeDatabaseID), [1, 1, 1])
  }

  func testThreeDinnerDefaultStillExcludesRepeats() {
    // Without a weekly policy the chosen recipe is excluded outright — the default horizon is
    // byte-for-byte unchanged by the weekly machinery.
    let a = candidate(1, lines: [line(10, name: "rice", grams: 100)])
    let b = candidate(2, lines: [line(11, name: "beans", grams: 100)])
    let c = candidate(3, lines: [line(12, name: "oats", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 3, candidates: [a, b, c],
        pool: StockPool(lots: [lot(10, 500), lot(11, 500), lot(12, 500)], now: now)))
    XCTAssertEqual(plan.dinners.map(\.recipeDatabaseID), [1, 2, 3])
  }

  func testWeeklyPlanIsDeterministic() {
    let candidates = [
      candidate(1, lines: [line(10, name: "rice", grams: 200)]),
      candidate(2, lines: [line(10, name: "rice", grams: 100), line(11, name: "beans", grams: 100)]),
      candidate(3, lines: [line(11, name: "beans", grams: 150)]),
    ]
    let make = {
      PlanAllocating.allocate(
        self.request(
          dinners: 7, servings: [4], candidates: candidates,
          pool: StockPool(lots: [self.lot(10, 600), self.lot(11, 300)], now: self.now),
          weekly: self.weeklyPolicy))
    }
    XCTAssertEqual(make(), make())
  }

  // MARK: - Leftover carry

  func testLeftoverCarryCoversTheNextSlotAndReservesNothing() {
    // Cook 4 servings, eat 2: the surplus covers the next slot. The leftovers night re-serves
    // the carried dish with no lines of its own and reserves nothing — four recipes feed seven
    // slots and the stock (exactly the cooked demand) comes out fully sufficient.
    let candidates = (1...4).map { index in
      candidate(
        Int64(index), title: "Dish \(index)",
        lines: [line(Int64(9 + index), name: "ing\(index)", grams: 100)])
    }
    let lots = (10...13).map { lot(Int64($0), 200) }
    let plan = PlanAllocating.allocate(
      request(
        dinners: 7, servings: [4], candidates: candidates,
        pool: StockPool(lots: lots, now: now),
        weekly: PlanWeeklyPolicy(
          eatersPerDinner: 2, repeatPenalty: 1_000, consecutiveMainIngredientPenalty: 500)))
    XCTAssertEqual(plan.dinners.count, 7)
    let leftovers = plan.dinners.filter { $0.leftoverOfDinnerID != nil }
    XCTAssertEqual(leftovers.map(\.position), [2, 4, 6])
    for night in leftovers {
      let cooked = plan.dinners.first { $0.dinnerID == night.leftoverOfDinnerID }
      XCTAssertEqual(cooked?.title, night.title)
      XCTAssertEqual(cooked?.recipeDatabaseID, night.recipeDatabaseID)
      XCTAssertEqual(night.servings, 2)
      XCTAssertEqual(night.lines, [])
    }
    // Exact sufficiency proves the leftovers nights reserved nothing new.
    XCTAssertEqual(plan.shoppingList, [])
    XCTAssertTrue(plan.dinners.filter { $0.leftoverOfDinnerID == nil }.allSatisfy { dinner in
      dinner.lines.allSatisfy { $0.lineState == .sufficient }
    })
  }

  func testLeftoverCarryNeedsAFullRoundOfEaters() {
    // Cook 3, eat 2: one spare serving per dish is not a leftovers night. Two different dishes
    // each leaving one portion cannot pool into one — the leftovers night re-serves ONE dish and
    // must be covered by that dish's own surplus, so every slot here plans a fresh dinner.
    let candidates = (1...5).map { index in
      candidate(
        Int64(index), lines: [line(Int64(9 + index), name: "ing\(index)", grams: 100)])
    }
    let lots = (10...14).map { lot(Int64($0), 150) }
    let plan = PlanAllocating.allocate(
      request(
        dinners: 5, servings: [3], candidates: candidates,
        pool: StockPool(lots: lots, now: now),
        weekly: PlanWeeklyPolicy(
          eatersPerDinner: 2, repeatPenalty: 1_000, consecutiveMainIngredientPenalty: 500)))
    XCTAssertEqual(plan.dinners.map(\.position), [1, 2, 3, 4, 5])
    XCTAssertTrue(
      plan.dinners.allSatisfy { $0.leftoverOfDinnerID == nil },
      "no cooked dish leaves a full round of eaters, so no leftovers night may be promised")
  }

  func testLeftoverNightExtendsTheMainIngredientChain() {
    // The leftovers night re-serves the same dish, so the next cooked slot still sees that
    // main as "yesterday's" — candidate 2 (same main) is penalized, candidate 3 wins.
    let sameMain = candidate(2, lines: [line(10, name: "rice", grams: 100)])
    let otherMain = candidate(3, lines: [line(11, name: "beans", grams: 100)])
    let first = candidate(1, lines: [line(10, name: "fried rice", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 3, servings: [4], candidates: [first, sameMain, otherMain],
        pool: StockPool(lots: [lot(10, 200), lot(11, 200)], now: now),
        weekly: PlanWeeklyPolicy(
          eatersPerDinner: 2, repeatPenalty: 1_000, consecutiveMainIngredientPenalty: 500)))
    XCTAssertEqual(plan.dinners.map(\.recipeDatabaseID), [1, 1, 3])
    XCTAssertEqual(plan.dinners[1].leftoverOfDinnerID, plan.dinners[0].dinnerID)
  }

  // MARK: - Weekly gates

  func testAllergensRemainAHardFilterInTheWeeklyHorizon() {
    // The blocked recipe is excluded outright, not penalized; the week repeats the safe one.
    let allergic = candidate(1, lines: [line(10, name: "peanuts", grams: 100)])
    let safe = candidate(2, lines: [line(11, name: "oats", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 2, candidates: [allergic, safe],
        pool: StockPool(lots: [lot(10, 100), lot(11, 100)], now: now),
        eaters: [PlanEater(id: "e1", blockedIngredientIDs: [10])], weekly: weeklyPolicy))
    XCTAssertEqual(plan.dinners.map(\.recipeDatabaseID), [2, 2])
  }

  func testShortLineCapAppliesToWeeklyRepeatsToo() {
    // §7 step 4 still gates every position: a candidate with three short required lines is
    // never selectable — repeats do not rescue it, and nothing feasible ships honestly empty.
    let impossible = candidate(
      1, lines: [
        line(10, name: "saffron", grams: 100),
        line(11, name: "truffle", grams: 100),
        line(12, name: "lobster", grams: 100),
      ])
    let plan = PlanAllocating.allocate(
      request(dinners: 3, candidates: [impossible], pool: StockPool(lots: [], now: now),
              weekly: weeklyPolicy))
    XCTAssertEqual(plan.dinners, [])
    XCTAssertEqual(plan.shoppingList, [])
  }

  // MARK: - Adapter: catalog recipes, staples, substitutions

  /// Core v1 schema (the plan adapter's reads) — mirrors the production migrator's v1 shape.
  static func makeDatabase() throws -> DatabaseQueue {
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
      try db.execute(sql: "INSERT INTO health_profile (id) VALUES (1)")
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
        // Production v16 (Migrations.swift): the estimate flag the plan adapter reads.
        t.column("quantity_is_estimate", .boolean).notNull().defaults(to: false)
        t.column("source", .text).notNull().defaults(to: "manual")
        t.column("acquired_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("expires_at", .datetime)
        t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
        t.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
      }
    }
    migrator.registerMigration("catalog_seedhelper") { db in
      try db.create(table: "recipes_catalog_ingredients") { t in
        t.primaryKey("key", .text)
        t.column("fdc_id", .integer)
        t.column("legacy_id", .integer)
        t.column("display_name", .text).notNull()
        t.column("category", .text).notNull()
        t.column("aliases", .text).notNull().defaults(to: "[]")
        t.column("classes", .text).notNull().defaults(to: "[]")
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
    // Production cook-plan tables (cook_plan_dinner/cook_plan_line) — the snapshot
    // adapter reads them for reserved and leftover lines, and the round-trip test
    // already migrates this same hand-built fixture, so the production subsystem
    // composes cleanly with the seed helper.
    try CookSessionMigrations.migrate(dbQueue)
    return dbQueue
  }

  /// A small bridged catalog: rice/egg/tofu/chicken keys resolve to app ingredients 1-4;
  /// the catalog staple (salt) stays unresolved. One catalog row succeeds legacy recipe 1.
  static func seedCatalog(_ db: DatabaseQueue) throws {
    try db.write { db in
      for (id, name) in [(1, "Rice"), (2, "Egg"), (3, "Tofu"), (4, "Chicken")] {
        try db.execute(
          sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (?, ?, 0, 0, 0, 0)",
          arguments: [id, name])
      }
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, instructions) VALUES (1, 'Fried Rice', 20, 'x')")
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_grams, display_quantity)
          VALUES (1, 1, 200, '200 g')
          """)
      for lot in [(1, 400.0), (2, 200.0), (3, 300.0), (4, 400.0)] {
        try db.execute(
          sql: "INSERT INTO inventory_lots (ingredient_id, quantity_grams, remaining_grams) VALUES (?, ?, ?)",
          arguments: [lot.0, lot.1, lot.1])
      }
      for (key, display, bridged, classes) in [
        ("rice", "Rice", 1, "[\"plant\"]"), ("egg", "Egg", 2, "[\"egg\"]"),
        ("tofu", "Tofu", 3, "[\"soy\",\"plant\"]"), ("chicken", "Chicken", 4, "[\"meat\"]"),
        ("mystery_key", "Mystery", nil, "[\"unknown\"]"),
        ("salt", "Salt", nil, "[\"mineral\"]"),
      ] {
        try db.execute(
          sql: "INSERT INTO recipes_catalog_ingredients (key, display_name, category, classes) VALUES (?, ?, 'produce', ?)",
          arguments: [key, display, classes])
        if let bridged {
          try db.execute(
            sql: "INSERT INTO recipes_catalog_ingredient_bridge (ingredient_key, ingredient_id, resolved_by) VALUES (?, ?, 'legacy_id')",
            arguments: [key, bridged])
        }
      }
      // rcp-000201 standalone; rcp-000202 succeeds legacy 1; the rest standalone.
      try insertCatalogRecipe(
        db, catalogID: "rcp-000201", revision: 3, title: "Rice Bowl", legacy: nil,
        lines: [("rice", 200, false)])
      try insertCatalogRecipe(
        db, catalogID: "rcp-000202", revision: 2, title: "Fried Rice (Catalog)", legacy: 1,
        lines: [("rice", 200, false)])
      try insertCatalogRecipe(
        db, catalogID: "rcp-000203", revision: 1, title: "Mapo Tofu", legacy: nil,
        lines: [("tofu", 250, false), ("mystery_key", 30, false)])
      try insertCatalogRecipe(
        db, catalogID: "rcp-000204", revision: 1, title: "Chicken Dinner", legacy: nil,
        lines: [("chicken", 300, false)])
      try insertCatalogRecipe(
        db, catalogID: "rcp-000205", revision: 1, title: "Egg Night", legacy: nil,
        lines: [("egg", 150, true), ("salt", 5, true)])
    }
  }

  static func insertCatalogRecipe(
    _ db: Database, catalogID: String, revision: Int, title: String, legacy: Int64?,
    lines: [(key: String, grams: Double, staple: Bool)]
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO recipes_catalog
          (catalog_id, revision, title, cuisine, minutes, servings, claims, rights_status, rights_evidence, legacy_recipe_id)
        VALUES (?, ?, ?, 'home', 20, 2, '{}', 'cleared', 'original', ?)
        """,
      arguments: [catalogID, revision, title, legacy])
    for (index, entry) in lines.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO recipes_catalog_lines
            (catalog_id, position, ingredient_key, quantity_kind, quantity_grams, assumed_staple)
          VALUES (?, ?, ?, 'grams', ?, ?)
          """,
        arguments: [catalogID, index, entry.key, entry.grams, entry.staple])
    }
  }

  func testAdapterSnapshotReadsCatalogRecipesAlongsideLegacy() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)

    let snapshot = try adapter.loadSnapshot()

    let ids = snapshot.candidates.map(\.databaseID)
    // Catalog recipes ride negative digit-tail identities disjoint from legacy positives,
    // sorted ascending; the catalog successor of legacy recipe 1 yields to it.
    XCTAssertEqual(ids, [-205, -204, -203, -201, 1])
    XCTAssertFalse(ids.contains(-202), "a catalog successor yields to its matchable legacy recipe")

    let riceBowl = try XCTUnwrap(snapshot.candidates.first { $0.databaseID == -201 })
    XCTAssertEqual(riceBowl.ref, RecipeRef(source: .catalog, id: "rcp-000201", revision: 3))
    XCTAssertEqual(riceBowl.title, "Rice Bowl")
    XCTAssertEqual(riceBowl.lines.first?.ingredientID, 1, "the bridge resolves the canonical key")

    // An unresolved non-staple key keeps a stable sentinel identity and no usable quantity.
    let mapo = try XCTUnwrap(snapshot.candidates.first { $0.databaseID == -203 })
    let mystery = try XCTUnwrap(
      mapo.lines.first { $0.ingredientID != 3 },
      "the unresolved key keeps its attention line")
    XCTAssertEqual(
      mystery.ingredientID, PlanDataAdapter.sentinelIngredientID(for: "mystery_key"))
    XCTAssertLessThan(mystery.ingredientID, 0)
    XCTAssertEqual(mystery.grams, 0)
    XCTAssertEqual(mystery.name, "Mystery")

    // The catalog staple flag marks a bridged ingredient as a household staple; the
    // unresolved staple line (salt) is dropped outright.
    XCTAssertTrue(snapshot.stapleIngredientIDs.contains(2), "the flagged egg line marks egg a staple")
    let eggNight = try XCTUnwrap(snapshot.candidates.first { $0.databaseID == -205 })
    XCTAssertEqual(eggNight.lines.map(\.ingredientID), [2], "unresolved salt is dropped; the egg line stays")

    // Legacy candidates keep their existing identity and convention.
    let legacy = try XCTUnwrap(snapshot.candidates.first { $0.databaseID == 1 })
    XCTAssertEqual(legacy.ref.id, "1")
    XCTAssertEqual(legacy.title, "Fried Rice")
  }

  func testCatalogSuccessorReturnsWhenTheLegacyRecipeIsBlocked() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    try dbQueue.write { db in
      // A second successor of legacy 1 that carries no rice.
      try Self.insertCatalogRecipe(
        db, catalogID: "rcp-000207", revision: 1, title: "Egg Fried Greens", legacy: 1,
        lines: [("egg", 150, false)])
      try db.execute(
        sql: "UPDATE health_profile SET allergen_ingredient_ids = '[1]' WHERE id = 1")
    }
    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)

    let snapshot = try adapter.loadSnapshot()

    // Every recipe on the rice allergen leaves the snapshot, legacy and catalog alike,
    // exactly as recommendations drop them. The successor policy treats the blocked
    // legacy recipe as unusable, so its rice-free catalog successor stands again.
    let ids = Set(snapshot.candidates.map(\.databaseID))
    for blocked: Int64 in [1, -201, -202] {
      XCTAssertFalse(ids.contains(blocked), "\(blocked) offered despite the rice allergen")
    }
    XCTAssertTrue(ids.contains(-207), "the rice-free successor fills the blocked legacy slot")
    // The eaters list keeps the hard filter for swaps and later allocation.
    XCTAssertEqual(snapshot.eaters.first?.blockedIngredientIDs, [1])

    let plan = PlanAllocating.allocate(
      request(
        dinners: 3, candidates: snapshot.candidates, pool: snapshot.pool,
        eaters: snapshot.eaters, weekly: weeklyPolicy))
    XCTAssertEqual(plan.dinners.count, 3)
    for dinner in plan.dinners {
      XCTAssertFalse(
        [1, -201, -202].contains(dinner.recipeDatabaseID),
        "\(dinner.recipeDatabaseID) chosen despite the rice allergen")
    }
  }

  /// One canonical key can bridge to several app ingredients. The plan used to represent a
  /// catalog line by the smallest bridged id only, so a household that flagged the key's
  /// second id was planned that recipe anyway; recommendations check every bridge row.
  func testAllergenOnAnyBridgedIDOfALineRemovesTheCatalogRecipe() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    try dbQueue.write { db in
      // "Jasmine Rice" matches no allergen keyword group, so only the id exclusion can
      // catch it; the composition screen sees plain plant classes.
      try db.execute(
        sql: "INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES (6, 'Jasmine Rice', 0, 0, 0, 0)")
      try db.execute(
        sql: "INSERT INTO recipes_catalog_ingredient_bridge (ingredient_key, ingredient_id, resolved_by) VALUES ('rice', 6, 'alias')")
      try db.execute(
        sql: "UPDATE health_profile SET allergen_ingredient_ids = '[6]' WHERE id = 1")
    }

    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    let ids = Set(snapshot.candidates.map(\.databaseID))

    XCTAssertFalse(ids.contains(-201), "the rice line bridges to the flagged id 6")
    XCTAssertFalse(ids.contains(-202), "the rice line bridges to the flagged id 6")
    XCTAssertTrue(ids.contains(1), "legacy lines carry exact ids; legacy rice (1) is not id 6")
    XCTAssertTrue(ids.contains(-204), "recipes without the flagged ingredient stay")
  }

  /// The allocator's eater filter reads required lines only. An optional line on a flagged
  /// ingredient must still keep the recipe out, as the recommend pools do. Rice matches no
  /// allergen keyword group, so only the id exclusion can catch these lines.
  func testOptionalAllergenLineRemovesTheRecipe() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, instructions) VALUES (2, 'Chicken Plate', 25, 'x')")
      try db.execute(
        sql: """
          INSERT INTO recipe_ingredients (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (2, 4, 1, 200, '200 g'), (2, 1, 0, 50, '50 g')
          """)
      try Self.insertCatalogRecipe(
        db, catalogID: "rcp-000208", revision: 1, title: "Chicken With Rice", legacy: nil,
        lines: [("chicken", 200, false), ("rice", 50, false)])
      try db.execute(
        sql: "UPDATE recipes_catalog_lines SET is_required = 0 WHERE catalog_id = 'rcp-000208' AND ingredient_key = 'rice'")
      try db.execute(
        sql: "UPDATE health_profile SET allergen_ingredient_ids = '[1]' WHERE id = 1")
    }

    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    let ids = Set(snapshot.candidates.map(\.databaseID))

    XCTAssertFalse(ids.contains(2), "legacy recipe with an optional rice line")
    XCTAssertFalse(ids.contains(-208), "catalog recipe with an optional rice line")
    XCTAssertTrue(ids.contains(-204), "the rice-free chicken recipe stays")
  }

  /// A diet household gets only recipes proven to fit: legacy rows must carry the diet's
  /// tag and catalog rows its claim, the gates recommendations apply.
  func testVeganHouseholdGetsOnlyProvenVeganRecipes() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT INTO recipes (id, title, time_minutes, instructions, tags) VALUES (3, 'Rice Salad', 10, 'x', ?)",
        arguments: [RecipeTags.vegan.rawValue | RecipeTags.vegetarian.rawValue])
      try db.execute(
        sql: "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_grams, display_quantity) VALUES (3, 1, 150, '150 g')")
      try Self.insertCatalogRecipe(
        db, catalogID: "rcp-000209", revision: 1, title: "Plain Rice", legacy: nil,
        lines: [("rice", 150, false)])
      try db.execute(
        sql: "UPDATE recipes_catalog SET claims = '{\"vegetarian\":true,\"vegan\":true}' WHERE catalog_id = 'rcp-000209'")
      try db.execute(
        sql: "UPDATE health_profile SET dietary_restrictions = '[\"vegan\"]' WHERE id = 1")
    }

    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()

    // Fried Rice (1) has no vegan tag and the seeded catalog rows claim nothing.
    XCTAssertEqual(snapshot.candidates.map(\.databaseID).sorted(), [-209, 3])
  }

  func testCatalogPantryFixtureYieldsAFeasibleWeek() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)
    let snapshot = try adapter.loadSnapshot()

    // Cook 4 servings, eat 2: the weekly horizon with leftover carry.
    let request = PlanRequest(
      dinnerCount: 7, servingsPerDinner: [4], candidates: snapshot.candidates,
      eaters: snapshot.eaters, substitutions: snapshot.substitutions,
      stapleIngredientIDs: snapshot.stapleIngredientIDs, pool: snapshot.pool,
      excludeDatabaseIDs: [],
      weekly: PlanWeeklyPolicy(
        eatersPerDinner: 2, repeatPenalty: PlanSheetViewModel.weeklyRepeatPenalty,
        consecutiveMainIngredientPenalty: PlanSheetViewModel.weeklyConsecutiveMainPenalty),
      planID: "plan_catweek", createdAt: now)
    let plan = PlanAllocating.allocate(request)

    // Rice 400/400, chicken 400/600, tofu 300/500, egg 200/300 — three leftover nights fill
    // the week; no double counting (shortfalls are exactly demand − stock, merged per
    // ingredient). The shipped reviewed table offers egg→tofu (binder, 1:1) for the
    // bridged egg key, so the 100 g egg shortfall is covered by tofu: tofu's merged
    // shortfall is 200 + 100 = 300 g and egg drops off the list. The fixture's chicken
    // key has no reviewed swap (the table pairs chicken_breast, not chicken), so chicken
    // keeps its 200 g shortfall. Verified against the real allocator with and without the
    // substitutions bundle: bundleless runs yield [2:100, 3:200, 4:200] instead.
    XCTAssertEqual(plan.dinners.count, 7)
    XCTAssertEqual(plan.dinners.filter { $0.leftoverOfDinnerID != nil }.count, 3)
    let swappedEggLines = plan.dinners.flatMap { $0.lines }.filter {
      $0.swap?.originalID == 2 && $0.swap?.substituteID == 3 && $0.swap?.reviewed == true
    }
    XCTAssertGreaterThanOrEqual(
      swappedEggLines.count, 1, "the reviewed egg→tofu swap covers the egg shortfall")
    XCTAssertEqual(
      plan.shoppingList.map { "\($0.ingredientID):\($0.amount.value)" }.sorted(),
      ["3:300.0", "4:200.0"])
  }

  func testAdapterLoadsReviewedSubstitutionsFromTheService() throws {
    guard Bundle.main.url(forResource: "substitutions-v1", withExtension: "json") != nil
        || Bundle.main.url(
          forResource: "substitutions-v1", withExtension: "json", subdirectory: "Substitutions")
          != nil
    else {
      throw XCTSkip("substitutions-v1.json is not in this test bundle's main bundle")
    }
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)

    let snapshot = try adapter.loadSnapshot()

    // The shipped reviewed table swaps chicken (4) → tofu (23) at ratio 1.0; the adapter
    // surfaces it for the mapped chicken line, reviewed.
    let swap = try XCTUnwrap(
      snapshot.substitutions.first { $0.originalID == 4 && $0.substituteID == 23 },
      "the reviewed chicken→tofu swap should surface for the mapped chicken line")
    XCTAssertEqual(swap.substituteGramsPerOriginalGram, 1.0, accuracy: 0.001)
    XCTAssertEqual(swap.reviewed, true)
  }

  // MARK: - Review round: swaps, stock, identity, staples

  func testSwapCandidateRespectsBlockedIngredients() throws {
    // The household blocks tofu (23). Chicken is half-stocked; the reviewed chicken→tofu swap
    // must not cover the shortfall with a substitute the household blocked — the line stays
    // short and the shortfall lands on the shopping list.
    let chickenDinner = candidate(1, lines: [line(4, name: "chicken", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 1, candidates: [chickenDinner],
        pool: StockPool(lots: [lot(4, 50), lot(23, 100)], now: now),
        eaters: [PlanEater(id: "household", blockedIngredientIDs: [23])],
        substitutions: [PlanSubstitution(
          originalID: 4, substituteID: 23, substituteGramsPerOriginalGram: 1.0,
          note: "reviewed", reviewed: true)]))
    let chicken = try XCTUnwrap(plan.dinners[0].lines.first)
    XCTAssertEqual(chicken.lineState, .short)
    XCTAssertEqual(chicken.short?.value ?? 0, 50, accuracy: 0.001)
    XCTAssertNil(chicken.swap)
    XCTAssertEqual(plan.shoppingList.first?.ingredientID, 4)
    XCTAssertEqual(plan.shoppingList.first?.amount.value ?? 0, 50, accuracy: 0.001)
  }

  func testSwapClaimReservesStockWithinADinner() {
    // 100 g chicken and 100 g tofu needed; 50 g chicken and 100 g tofu in stock. The chicken
    // line's swap claims 50 g of tofu — the tofu line must then see 50 g left, not 100 again.
    // Both lines reading the same unchanged pool would hide 50 g from the shopping list.
    let dinner = candidate(
      1, lines: [line(4, name: "chicken", grams: 100), line(23, name: "tofu", grams: 100)])
    let plan = PlanAllocating.allocate(
      request(
        dinners: 1, candidates: [dinner],
        pool: StockPool(lots: [lot(4, 50), lot(23, 100)], now: now),
        substitutions: [PlanSubstitution(
          originalID: 4, substituteID: 23, substituteGramsPerOriginalGram: 1.0,
          note: "reviewed", reviewed: true)]))
    let tofu = plan.dinners[0].lines.first { $0.ingredientID == 23 }
    XCTAssertEqual(tofu?.lineState, .short)
    XCTAssertEqual(tofu?.short?.value ?? 0, 50, accuracy: 0.001)
    XCTAssertEqual(plan.shoppingList.map { "\($0.ingredientID):\($0.amount.value)" }, ["23:50.0"])
  }

  func testSnapshotFiltersBlockedSubstitutes() throws {
    guard Bundle.main.url(forResource: "substitutions-v1", withExtension: "json") != nil
        || Bundle.main.url(
          forResource: "substitutions-v1", withExtension: "json", subdirectory: "Substitutions")
          != nil
    else {
      throw XCTSkip("substitutions-v1.json is not in this test bundle's main bundle")
    }
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    try dbQueue.write { db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO health_profile (id, allergen_ingredient_ids) VALUES (1, ?)",
        arguments: ["[23]"])
    }
    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()

    // The reviewed chicken→tofu swap disappears once the household blocks tofu; swaps for
    // unblocked ingredients stay offered.
    XCTAssertFalse(
      snapshot.substitutions.contains { $0.originalID == 4 && $0.substituteID == 23 },
      "a blocked substitute must never be offered to the household")
    XCTAssertTrue(
      snapshot.substitutions.contains { $0.originalID == 2 },
      "screening removes only blocked substitutes, not every reviewed swap")
  }

  func testSavedCatalogDinnersReloadTheirDatabaseID() throws {
    let dbQueue = try Self.makeDatabase()
    try CookSessionMigrations.migrate(dbQueue)
    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)
    let plan = LeChefPlan(
      planID: "plan_catid", createdAt: now,
      dinners: [
        PlannedDinner(
          position: 1, dinnerID: "plan_catid-d1",
          recipe: RecipeRef(source: .catalog, id: "rcp-000201", revision: 3),
          recipeDatabaseID: PlanDataAdapter.catalogDatabaseID("rcp-000201"),
          title: "Rice Bowl", servings: 2, timeMinutes: nil, lines: []),
      ],
      shoppingList: [],
      fitSummary: PlanFitSummary(sufficientLines: 0, totalLines: 0, swapCount: 0, attention: nil))
    try adapter.save(plan)
    let reloaded = try XCTUnwrap(try adapter.load(planID: plan.planID))
    XCTAssertEqual(
      reloaded.dinners[0].recipeDatabaseID, PlanDataAdapter.catalogDatabaseID("rcp-000201"),
      "a catalog dinner must reload the identity needed for replacement and exclusion")
  }

  func testHouseholdStapleChoiceSurvivesTheCatalog() throws {
    let dbQueue = try Self.makeDatabase()
    try Self.seedCatalog(dbQueue)
    try dbQueue.write { db in
      // The household explicitly downgraded egg to confirm-first; rice carries no household row.
      try db.execute(
        sql: "INSERT OR REPLACE INTO pantry_assumptions (ingredient_id, tier) VALUES (?, ?)",
        arguments: [2, "only_if_confirmed"])
      try Self.insertCatalogRecipe(
        db, catalogID: "rcp-000206", revision: 1, title: "Rice Porridge", legacy: nil,
        lines: [("rice", 100, true)])
    }
    let snapshot = try PlanDataAdapter(dbQueue: dbQueue, now: now).loadSnapshot()
    XCTAssertFalse(
      snapshot.stapleIngredientIDs.contains(2),
      "the household's explicit tier wins over the catalog's assumed_staple default")
    XCTAssertTrue(
      snapshot.stapleIngredientIDs.contains(1),
      "catalog staples stay defaults for ingredients the household never tiered")
  }

  // MARK: - Persistence

  func testPlanLeftoverNightsRoundTripThroughCookPlanTables() throws {
    let dbQueue = try Self.makeDatabase()
    try CookSessionMigrations.migrate(dbQueue)
    let adapter = PlanDataAdapter(dbQueue: dbQueue, now: now)

    var plan = LeChefPlan(
      planID: "plan_rt", createdAt: now,
      dinners: [
        PlannedDinner(
          position: 1, dinnerID: "plan_rt-d1",
          recipe: RecipeRef(source: .catalog, id: "1", revision: 1), recipeDatabaseID: 1,
          title: "Stew", servings: 4, timeMinutes: 40,
          lines: [PlanLine(
            ingredientID: 10, name: "rice", isRequired: true,
            required: PlanQuantity(value: 200), lineState: .sufficient, short: nil, swap: nil)]),
        PlannedDinner(
          position: 2, dinnerID: "plan_rt-d2",
          recipe: RecipeRef(source: .catalog, id: "1", revision: 1), recipeDatabaseID: 1,
          title: "Stew", servings: 2, timeMinutes: 40, lines: [], leftoverOfDinnerID: "plan_rt-d1"),
        PlannedDinner(
          position: 3, dinnerID: "plan_rt-d3",
          recipe: RecipeRef(source: .catalog, id: "2", revision: 1), recipeDatabaseID: 2,
          title: "Stir-fry", servings: 2, timeMinutes: 25,
          lines: [PlanLine(
            ingredientID: 11, name: "beans", isRequired: true,
            required: PlanQuantity(value: 100), lineState: .sufficient, short: nil, swap: nil)]),
      ],
      shoppingList: [], fitSummary: PlanFitSummary(sufficientLines: 2, totalLines: 2, swapCount: 0, attention: nil))

    try adapter.save(plan)
    let reloaded = try XCTUnwrap(try adapter.load(planID: plan.planID))

    XCTAssertEqual(reloaded.dinners.count, 3)
    XCTAssertEqual(reloaded.dinners[0].leftoverOfDinnerID, nil)
    XCTAssertEqual(reloaded.dinners[1].leftoverOfDinnerID, "plan_rt-d1")
    XCTAssertEqual(reloaded.dinners[1].servings, 2)
    XCTAssertEqual(reloaded.dinners[1].lines, [])
    XCTAssertEqual(reloaded.dinners[2].leftoverOfDinnerID, nil)
    // Saving again stays idempotent with the marker present.
    plan = reloaded
    try adapter.save(plan)
    let second = try XCTUnwrap(try adapter.load(planID: plan.planID))
    XCTAssertEqual(second.dinners.map(\.leftoverOfDinnerID), [nil, "plan_rt-d1", nil])
  }

  // MARK: - View model

  @MainActor
  func testWeeklyPolicyFlipsAtFiveDinners() async throws {
    let candidates = (1...4).map { index in
      PlanCandidate(
        databaseID: Int64(index),
        ref: RecipeRef(source: .catalog, id: String(index), revision: 1),
        title: "Dish \(index)", timeMinutes: 30, baseServings: 2,
        lines: [PlanCandidateLine(
          ingredientID: Int64(9 + index), name: "ing\(index)", grams: 100, isRequired: true)])
    }
    let lots = (10...13).map { PlanLot(ingredientID: Int64($0), grams: 400, expiresAt: nil, quantityIsEstimate: false) }
    let snapshot = PlanSheetData(
      candidates: candidates, eaters: [], substitutions: [], stapleIngredientIDs: [],
      pool: StockPool(lots: lots, now: now), hasAnyStockLots: true)
    let viewModel = PlanSheetViewModel(now: now) { _ in snapshot }

    await viewModel.load()
    XCTAssertEqual(viewModel.dinnerCount, 3)
    XCTAssertFalse(viewModel.isWeeklyHorizon)

    // Cook 4 servings, eat 2: a weekly horizon carries the surplus to the next slot.
    viewModel.setServings(4, forDinnerAt: 0)
    viewModel.setDinnerCount(7)
    XCTAssertTrue(viewModel.isWeeklyHorizon)
    let weekly = try XCTUnwrap(viewModel.plan)
    XCTAssertEqual(weekly.dinners.count, 7)
    XCTAssertTrue(weekly.dinners.contains { $0.leftoverOfDinnerID != nil })

    // Back to the three-dinner default: same kitchen, no leftovers nights.
    viewModel.setDinnerCount(3)
    XCTAssertFalse(viewModel.isWeeklyHorizon)
    let short = try XCTUnwrap(viewModel.plan)
    XCTAssertEqual(short.dinners.count, 3)
    XCTAssertTrue(short.dinners.allSatisfy { $0.leftoverOfDinnerID == nil })
  }
}
