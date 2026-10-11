import Foundation
import GRDB
import XCTest

@testable import NutritionCheck
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Flow E — changed-bundle integration with the refresh owner
/// (PR #44, branch obv/fl-next-bundled-refresh, vendored at 7dc2b219204c —
/// see VendoredBundleRefresh/PROVENANCE.md).
///
/// One narrative, three movements, all through the REAL refresher and the REAL
/// snapshot-readiness provider (`NutritionSnapshotService.verifyHistoricalSnapshotReadiness`):
///
/// E1  The `.pending` readiness default refuses a refresh before any write, on a
///     database that has history but no readiness provider — fail-closed holds at
///     the integration seam, not just in unit tests.
/// E2  After the v18→v20 cutover, a first pass adopts the installed rows to the
///     pinned payload and a second pass carries a CHANGED payload (ingredient 1
///     calories 52.17 → 55.55, the "egg 145→155" correction shape). The owned row
///     updates in place — and every frozen output stays bit-identical
///     (`Double.bitPattern`): per-meal journal macros, today, daily totals, and
///     the captured Apple Health macros for all meals. A sanity check recomputes
///     the original live-table aggregation and verifies its bits DID move, so the
///     exercise cannot pass vacuously.
/// E3  Deleting one snapshot header flips the same refresh to refusal — nothing
///     further is written.
final class BundleRefreshFlowETests: XCTestCase {
  // MARK: - Bit helpers (same contract as CutoverParityTests)

  private func bits(_ value: Double) -> String {
    String(format: "%016llx", value.bitPattern)
  }

  private func assertBitEqual(
    _ label: String, _ old: Double, _ new: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      old.bitPattern, new.bitPattern,
      "\(label): expected frozen bits 0x\(bits(old)) vs found 0x\(bits(new)) "
        + "(values \(old) / \(new))",
      file: file, line: line)
  }

  // MARK: - Payload fixtures

  /// The fixture corpus in data.json shape. Ingredient entries carry the exact
  /// values the fixture rows are hydrated to in `seedCutoverWorld` (typical_unit
  /// and storage_tip set, education/display columns NULL — the dataJson
  /// provenance projection), so adoption matches by content; only ingredient 1's
  /// calories ever change.
  private func payloadJSON(ingredient1Calories: Double) -> String {
    func ingredient(_ id: Int, _ cal: Double, _ pro: Double, _ carb: Double, _ fat: Double,
                    _ fib: Double, _ sug: Double, _ sod: Double) -> String {
      """
      "\(id)": ["Ingredient \(id)", \(cal), \(pro), \(carb), \(fat), \(fib), \(sug), \(sod), "g", "tip"]
      """
    }
    let i1 = ingredient(1, ingredient1Calories, 0.83, 11.31, 0.37, 1.7, 2.13, 4.0)
    let i2 = ingredient(2, 89.21, 1.09, 22.84, 0.33, 2.6, 12.23, 1.0)
    let i3 = ingredient(3, 248.63, 4.51, 0.11, 24.77, 0.0, 0.49, 7.0)
    return """
    {
      "tags": [],
      "ingredients": {
        \(i1),
        \(i2),
        \(i3)
      },
      "recipes": [
        [1, "Recipe 1", 15, 2, [[1, 150.0], [2, 33.75], [3, 30.5]], [], "cook", 0],
        [2, "Recipe 2", 15, 4, [], [], "cook", 0],
        [3, "Recipe 3", 15, 1, [[1, 100.0]], [], "cook", 0]
      ]
    }
    """
  }

  private static let originalCalories: Double = 52.17
  private static let changedCalories: Double = 55.55

  private func decodePayload(_ json: String) throws -> BundledData {
    try JSONDecoder().decode(BundledData.self, from: Data(json.utf8))
  }

  private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func makePass(currentJSON: String, pinJSON: String) throws -> BundledDataRefresher.Pass {
    let pin = PinnedBundlePayload(
      slug: "historical-nutrition-check",
      bundleId: "hnc-flow-e-pin",
      data: try decodePayload(pinJSON),
      dataSha256: sha256Hex(pinJSON),
      catalog: [])
    return BundledDataRefresher.loadCurrentPass(
      current: try decodePayload(currentJSON),
      currentDataSha256: sha256Hex(currentJSON),
      currentCatalog: [],
      pins: [pin])
  }

  // MARK: - Database fixture (the cutover world)

  /// v18-schema world: the fixture catalog with the columns the data.json writer
  /// hydrates (typical_unit/storage_tip set; education/display columns NULL —
  /// that is the dataJson provenance projection), and four meals: a substitute
  /// swap at a non-terminating ratio, NULL consumed servings, a fractional
  /// portion, and a yesterday meal. Today/yesterday come from SQLite itself so
  /// every dated read sees the same day boundary.
  private func seedCutoverWorld(_ name: String) throws -> DatabaseQueue {
    let queue = try Fixtures.makeQueue(name)
    try DatabaseMigrations.migrate(queue, upTo: Fixtures.v18)
    try queue.write { db in
      try Fixtures.insertCatalog(db)
      try db.execute(
        sql: "UPDATE ingredients SET typical_unit = 'g', storage_tip = 'tip' WHERE id IN (1, 2, 3)")
      let meals: [(id: Int64, recipeId: Int64, when: String, consumed: Int?, portion: Double,
                   swap: (Int64, Int64, Double)?)] = [
        (21, 1, "datetime('now','localtime','-90 minutes')", 1, 1.0, (3, 2, 0.333333)),
        (22, 1, "datetime('now','localtime','-40 minutes')", nil, 0.75, nil),
        (23, 3, "datetime('now','localtime','-20 minutes')", 1, 1.0, nil),
        (24, 1, "datetime('now','localtime','-1 day')", 2, 1.3, nil),
      ]
      for meal in meals {
        try db.execute(
          sql: """
            INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier)
            VALUES (?, ?, \(meal.when), NULL, ?, ?)
            """,
          arguments: [
            meal.id, meal.recipeId, meal.consumed ?? NSNull(), meal.portion,
          ])
        if let swap = meal.swap {
          try db.execute(
            sql: """
              INSERT INTO cooking_history_swaps (history_id, original_ingredient_id, substitute_ingredient_id, ratio)
              VALUES (?, ?, ?, ?)
              """,
            arguments: [meal.id, swap.0, swap.1, swap.2])
        }
      }
    }

    // Cutover, then the refresh owner's stream: this branch migrates to
    // v20_historical_nutrition_snapshots (backfilling snapshot headers), and
    // PR #44 registers v21_bundle_ownership after it. The two streams'
    // migrations apply cleanly in sequence against one database; the fixture
    // applies the owner's body by hand (see
    // VendoredBundleOwnershipMigration.swift) so the real refresher sees the
    // ownership schema it expects.
    try DatabaseMigrations.migrate(queue)
    try queue.write { db in
      try VendoredBundleOwnershipMigration.apply(db)
    }
    return queue
  }

  // MARK: - The original live-table aggregation (verbatim reference SQL)

  /// The original `UserDataRepository.todayMacros` catalog-based query — the same
  /// verbatim copy CutoverParityTests carries. Used here only for the
  /// non-vacuousness sanity check: after the refresh changes the live ingredient
  /// row, this path's bits MUST move (the frozen snapshot-backed outputs must not).
  private func oldTodayMacros(db: Database) throws -> [String: Double] {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COALESCE(SUM(
            (i.calories / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
            * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
          ), 0) AS total_cal,
          COALESCE(SUM(
            (i.protein / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
            * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
          ), 0) AS total_pro,
          COALESCE(SUM(
            (i.carbs / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
            * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
          ), 0) AS total_carb,
          COALESCE(SUM(
            (i.fat / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
            * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
          ), 0) AS total_fat
        FROM cooking_history ch
        JOIN recipes r ON r.id = ch.recipe_id
        JOIN recipe_ingredients ri ON ri.recipe_id = r.id AND ri.is_required = 1
        LEFT JOIN cooking_history_swaps sw
          ON sw.history_id = ch.id AND sw.original_ingredient_id = ri.ingredient_id
        JOIN ingredients i ON i.id = COALESCE(sw.substitute_ingredient_id, ri.ingredient_id)
        WHERE date(ch.cooked_at, 'localtime') = date('now', 'localtime')
        """
    )
    guard let row else { return ["cal": 0, "pro": 0, "carb": 0, "fat": 0] }
    return [
      "cal": row["total_cal"] as? Double ?? 0,
      "pro": row["total_pro"] as? Double ?? 0,
      "carb": row["total_carb"] as? Double ?? 0,
      "fat": row["total_fat"] as? Double ?? 0,
    ]
  }

  // MARK: - Frozen-output reader (snapshot-backed production paths)

  private struct FrozenOutputs {
    var today: [String: Double]
    var daily: [String: [String: Double]]
    var journal: [Int64: [String: Double]]
    var health: [Int64: [String: Double]]
  }

  private func readFrozenOutputs(_ queue: DatabaseQueue) throws -> FrozenOutputs {
    let repo = UserDataRepository(db: queue)
    let snapshotService = NutritionSnapshotService(db: queue)

    let today = try repo.todayMacros()
    let daily = try repo.dailyMacroTotals(lastDays: 7)
    let journal = try repo.cookingJournal(limit: 50)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")

    var out = FrozenOutputs(today: [:], daily: [:], journal: [:], health: [:])
    out.today = [
      "cal": today.calories, "pro": today.protein,
      "carb": today.carbs, "fat": today.fat,
    ]
    for point in daily {
      out.daily[formatter.string(from: point.date)] = [
        "cal": point.calories, "pro": point.protein,
        "carb": point.carbs, "fat": point.fat,
      ]
    }
    for entry in journal {
      out.journal[entry.id] = [
        "cal": entry.macrosConsumed.calories,
        "pro": entry.macrosConsumed.protein,
        "carb": entry.macrosConsumed.carbs,
        "fat": entry.macrosConsumed.fat,
      ]
    }
    for id: Int64 in [21, 22, 23, 24] {
      let captured = try snapshotService.capturedMacros(historyId: id)
      out.health[id] = [
        "cal": captured.caloriesPerServing,
        "pro": captured.proteinPerServing,
        "carb": captured.carbsPerServing,
        "fat": captured.fatPerServing,
        "fib": captured.fiberPerServing,
        "sug": captured.sugarPerServing,
        "sod": captured.sodiumPerServing,
      ]
    }
    return out
  }

  private func assertFrozenOutputsUnchanged(
    _ before: FrozenOutputs, _ after: FrozenOutputs,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    for key in ["cal", "pro", "carb", "fat"] {
      assertBitEqual(
        "today.\(key)", before.today[key]!, after.today[key]!, file: file, line: line)
    }
    XCTAssertEqual(Set(before.daily.keys), Set(after.daily.keys), "daily day set changed")
    for (day, beforeDay) in before.daily {
      let afterDay = after.daily[day]!
      for key in ["cal", "pro", "carb", "fat"] {
        assertBitEqual(
          "daily \(day).\(key)", beforeDay[key]!, afterDay[key]!, file: file, line: line)
      }
    }
    for id: Int64 in [21, 22, 23, 24] {
      let beforeJournal = try XCTUnwrap(before.journal[id], "journal \(id) missing before")
      let afterJournal = try XCTUnwrap(after.journal[id], "journal \(id) missing after")
      for key in ["cal", "pro", "carb", "fat"] {
        assertBitEqual(
          "journal \(id).\(key)", beforeJournal[key]!, afterJournal[key]!, file: file, line: line)
      }
      let beforeHealth = try XCTUnwrap(before.health[id], "health \(id) missing before")
      let afterHealth = try XCTUnwrap(after.health[id], "health \(id) missing after")
      for key in ["cal", "pro", "carb", "fat", "fib", "sug", "sod"] {
        assertBitEqual(
          "health \(id).\(key)", beforeHealth[key]!, afterHealth[key]!, file: file, line: line)
      }
    }
  }

  // MARK: - Write-state probes

  private struct OwnershipCounts: Equatable {
    var ingredients: Int
    var recipes: Int
  }

  private func ownershipCounts(_ queue: DatabaseQueue) throws -> OwnershipCounts {
    try queue.read { db in
      OwnershipCounts(
        ingredients: try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM ingredients WHERE ownership_key IS NOT NULL") ?? 0,
        recipes: try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM recipes WHERE ownership_key IS NOT NULL") ?? 0)
    }
  }

  private func stateValue(_ queue: DatabaseQueue, key: String) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db, sql: "SELECT value FROM bundled_recipe_state WHERE key = ?", arguments: [key])
    }
  }

  private func liveCalories(_ queue: DatabaseQueue, ingredientId: Int64) throws -> Double {
    try queue.read { db in
      try Double.fetchOne(
        db, sql: "SELECT calories FROM ingredients WHERE id = ?", arguments: [ingredientId])!
    }
  }

  // MARK: - Flow E

  func testBundleRefreshE1PendingRefusesE2AdoptAndUpdateFreezesBitsE3DeletedHeaderRefuses() throws {
    let queue = try seedCutoverWorld("bundle-refresh-flow-e")
    let originalJSON = payloadJSON(ingredient1Calories: Self.originalCalories)
    let changedJSON = payloadJSON(ingredient1Calories: Self.changedCalories)
    let passA = try makePass(currentJSON: originalJSON, pinJSON: originalJSON)
    let passB = try makePass(currentJSON: changedJSON, pinJSON: originalJSON)

    // The cutover backfill must leave the world ready for the real provider
    // before any refresh is attempted.
    try queue.read { db in
      try NutritionSnapshotService(db: DatabaseQueue())
        .verifyHistoricalSnapshotReadiness(in: db)
    }

    // ---- E1: the `.pending` default refuses before any write.
    XCTAssertThrowsError(
      try queue.write { db in
        try BundledDataRefresher.refreshInTransaction(db, pass: passA, readiness: .pending)
      }
    ) { error in
      guard case BundledDataRefreshError.snapshotReadinessRefused = error else {
        XCTFail("expected snapshotReadinessRefused, got \(error)")
        return
      }
    }
    XCTAssertEqual(try ownershipCounts(queue), OwnershipCounts(ingredients: 0, recipes: 0),
      "refusal must not stamp ownership")
    XCTAssertNil(try stateValue(queue, key: "ownership_ready"))
    XCTAssertNil(try stateValue(queue, key: "refresh_bundle_hash"))

    // ---- E2 movement 1: adoption through the REAL readiness provider.
    let frozenBefore = try readFrozenOutputs(queue)
    let adoption = try queue.write { db in
      try BundledDataRefresher.refreshInTransaction(
        db, pass: passA, readiness: .historicalNutrition)
    }
    XCTAssertEqual(adoption.ingredientsAdopted, 3)
    XCTAssertEqual(adoption.recipesAdopted, 3)
    XCTAssertEqual(adoption.ingredientsUpdated, 0)
    XCTAssertEqual(try ownershipCounts(queue), OwnershipCounts(ingredients: 3, recipes: 3))
    XCTAssertEqual(try stateValue(queue, key: "ownership_ready"), "1")

    // Adoption itself (an ownership stamp + marker) must not disturb a single
    // frozen bit either.
    try assertFrozenOutputsUnchanged(frozenBefore, try readFrozenOutputs(queue))

    // ---- E2 movement 2: the changed payload updates the owned row in place.
    let update = try queue.write { db in
      try BundledDataRefresher.refreshInTransaction(
        db, pass: passB, readiness: .historicalNutrition)
    }
    XCTAssertEqual(update.ingredientsUpdated, 1, "exactly the changed ingredient updates")
    XCTAssertEqual(update.ingredientsInserted, 0)
    XCTAssertEqual(update.recipesUpdated, 0)
    XCTAssertEqual(update.recipesInserted, 0)
    XCTAssertEqual(
      try liveCalories(queue, ingredientId: 1), Self.changedCalories,
      "the owned row must carry the changed payload")
    XCTAssertEqual(try liveCalories(queue, ingredientId: 2), 89.21)
    XCTAssertEqual(try liveCalories(queue, ingredientId: 3), 248.63)
    XCTAssertEqual(
      try stateValue(queue, key: "refresh_bundle_hash"), sha256Hex(changedJSON))

    // The frozen outputs must be bit-identical across the content change.
    try assertFrozenOutputsUnchanged(frozenBefore, try readFrozenOutputs(queue))

    // Sanity (non-vacuousness): the ORIGINAL live-table aggregation reads the
    // live row, so its calories bits MUST have moved. If this ever matches, the
    // fixture no longer exercises a changed bundle.
    let liveOld = try queue.read { db in try oldTodayMacros(db: db) }
    XCTAssertNotEqual(
      liveOld["cal"]!.bitPattern, frozenBefore.today["cal"]!.bitPattern,
      "fixture sanity: the live aggregation did not move, so the refresh was not exercised")

    // ---- E3: a missing snapshot header flips the same refresh to refusal.
    try queue.write { db in
      try db.execute(
        sql: "DELETE FROM cooking_history_nutrition_snapshots WHERE history_id = 21")
    }
    XCTAssertThrowsError(
      try queue.write { db in
        try BundledDataRefresher.refreshInTransaction(
          db, pass: passB, readiness: .historicalNutrition)
      }
    ) { error in
      if case BundledDataRefreshError.postConditionFailed = error {
        XCTFail("refusal must come from the readiness gate, not a postcondition: \(error)")
      }
    }
    // Nothing further was written: the owned row, markers, and ownership all
    // still carry exactly what E2 left.
    XCTAssertEqual(try liveCalories(queue, ingredientId: 1), Self.changedCalories)
    XCTAssertEqual(try ownershipCounts(queue), OwnershipCounts(ingredients: 3, recipes: 3))
    XCTAssertEqual(
      try stateValue(queue, key: "refresh_bundle_hash"), sha256Hex(changedJSON))
    XCTAssertEqual(try stateValue(queue, key: "ownership_ready"), "1")
  }
}
