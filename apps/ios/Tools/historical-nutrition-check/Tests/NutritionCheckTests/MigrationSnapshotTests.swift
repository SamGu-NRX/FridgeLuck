import Foundation
import GRDB
import XCTest

@testable import NutritionCheck

/// Milestone 1 checks: the v20 snapshot schema, the backfill, the capture
/// writer, and rollback of a composed logging transaction.
final class MigrationSnapshotTests: XCTestCase {
  // MARK: - Helpers

  /// Queue migrated to v18 with the catalog and pre-snapshot meals seeded.
  private func v18World(_ name: String) throws -> DatabaseQueue {
    let queue = try Fixtures.makeQueue(name)
    try DatabaseMigrations.migrate(queue, upTo: Fixtures.v18)
    try queue.write { db in
      try Fixtures.insertCatalog(db)
      for meal in Fixtures.meals {
        try Fixtures.insertMeal(db, meal)
      }
    }
    return queue
  }

  private func bits(_ value: Double) -> UInt64 { value.bitPattern }

  // MARK: - v20 backfill

  func testBackfillRowCountsProvenanceAndFrozenServings() throws {
    let queue = try v18World("backfill-counts")
    try DatabaseMigrations.migrate(queue)

    try queue.read { db in
      // Meals 1-3 are snapshotted; meal 4 is the orphan (recipe 3 exists
      // here, so it also gets a snapshot — orphan-skip is covered below).
      let snapshotCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM cooking_history_nutrition_snapshots")
      XCTAssertEqual(snapshotCount, 4)

      let backfilled = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM cooking_history_nutrition_snapshots WHERE provenance = 'upgrade_backfill'")
      XCTAssertEqual(backfilled, 4)

      let servings = try Int.fetchOne(
        db,
        sql: "SELECT recipe_servings FROM cooking_history_nutrition_snapshots WHERE history_id = 1")
      XCTAssertEqual(servings, 2)

      // Every backfilled meal reports the current version.
      let versions = try Int.fetchAll(
        db, sql: "SELECT DISTINCT snapshot_version FROM cooking_history_nutrition_snapshots")
      XCTAssertEqual(versions, [NutritionSnapshot.currentVersion])

      // Meal 1: recipe 1 has three required lines; meal 3: same; meal 4: one.
      for (historyId, count) in [(Int64(1), 3), (Int64(2), 3), (Int64(3), 3), (Int64(4), 1)] {
        let lines = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM cooking_history_nutrition_lines WHERE history_id = ?",
          arguments: [historyId])
        XCTAssertEqual(lines, count, "history \(historyId)")
      }
    }
  }

  func testBackfillLineOrderSubstitutesAndRatiosBitExact() throws {
    let queue = try v18World("backfill-lines")
    try DatabaseMigrations.migrate(queue)

    try queue.read { db in
      // Catalog values the backfill must reproduce bit-exactly.
      let ing2 = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 2")!
      let ing1 = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 1")!

      // Meal 1 swaps ingredient 3 -> 2 at ratio 0.333333. Lines follow
      // recipe_ingredients rowid order (the pre-snapshot accumulation order).
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT * FROM cooking_history_nutrition_lines WHERE history_id = 1 ORDER BY line_index")
      XCTAssertEqual(rows.count, 3)

      XCTAssertEqual(rows[0]["original_ingredient_id"] as Int64, 1)
      XCTAssertEqual(bits(rows[0]["calories"] as Double), bits(ing1["calories"] as Double))
      XCTAssertEqual(bits(rows[0]["quantity_grams"] as Double), bits(150.0))
      XCTAssertEqual(bits(rows[0]["swap_ratio"] as Double), bits(1.0))

      XCTAssertEqual(rows[1]["original_ingredient_id"] as Int64, 2)
      XCTAssertEqual(bits(rows[1]["quantity_grams"] as Double), bits(33.75))

      // Swapped line: substitute 2's nutrient values, original id preserved,
      // ratio frozen as given (not COALESCEd away).
      XCTAssertEqual(rows[2]["original_ingredient_id"] as Int64, 3)
      XCTAssertEqual(rows[2]["substitute_ingredient_id"] as Int64, 2)
      for nutrient in ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"] {
        XCTAssertEqual(
          bits(rows[2][nutrient] as Double), bits(ing2[nutrient] as Double),
          "swapped line \(nutrient) must freeze the substitute's value")
      }
      XCTAssertEqual(bits(rows[2]["swap_ratio"] as Double), bits(0.333333))
    }
  }

  func testOrphanHistoriesAreStructurallyImpossible() throws {
    // cooking_history.recipe_id references recipes and the GRDB migrator
    // validates foreign keys after every migration, so a history row whose
    // recipe is gone cannot exist in a real database. The backfill's LEFT
    // JOIN skip is defensive, not reachable. Pin the invariant: inserting an
    // orphan history is rejected.
    let queue = try v18World("orphan-impossible")
    XCTAssertThrowsError(
      try queue.write { db in
        try db.execute(
          sql: "INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier) VALUES (?, ?, ?, ?, ?, ?)",
          arguments: [Int64(41), Int64(999), "2026-10-01 19:00:00.000", NSNull(), NSNull(), 1.0]
        )
      }
    )
    try DatabaseMigrations.migrate(queue)
    try queue.read { db in
      let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cooking_history_nutrition_snapshots")
      XCTAssertEqual(total, 4)
    }
  }

  func testBackfillCompletesEmptyRecipeWithZeroLines() throws {
    let queue = try v18World("backfill-empty")
    // Meal on the empty recipe (recipe 2, zero lines).
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [Int64(20), Int64(2), "2026-10-01 09:00:00.000", NSNull(), NSNull(), 1.0]
      )
    }

    try DatabaseMigrations.migrate(queue)

    try queue.read { db in
      let servings = try Int.fetchOne(
        db,
        sql: "SELECT recipe_servings FROM cooking_history_nutrition_snapshots WHERE history_id = 20")
      XCTAssertEqual(servings, 4, "frozen servings come from the recipe header")

      let lines = try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM cooking_history_nutrition_lines WHERE history_id = 20")
      XCTAssertEqual(lines, 0, "empty recipe completes with a zero-line snapshot")
    }

    // And the snapshot reads are consistent for that meal.
    let totals = try queue.read { db in
      try NutritionSnapshot.consumedTotals(
        in: db, historyId: 20, storedServingsConsumed: nil, portionMultiplier: 1.0)
    }
    XCTAssertEqual(bits(totals.calories), bits(0.0))
  }

  // MARK: - Capture writer

  func testCaptureFreezesEffectiveInputsFractionalGramsAndOrder() throws {
    let queue = try v18World("capture-writer")
    try DatabaseMigrations.migrate(queue)
    let service = NutritionSnapshotService(db: queue)

    // Log a new meal on recipe 1 with a fractional swap, through the same
    // composed writes a real log performs, then capture.
    try queue.write { db in
      try Fixtures.insertMeal(db, .init(
        id: 30, recipeId: 1, cookedAt: "2026-10-02 08:00:00.000",
        servingsConsumed: 2, portion: 0.5,
        swaps: [.init(originalId: 1, substituteId: 3, ratio: 1.25)]
      ))
      try service.captureSnapshot(in: db, historyId: 30, recipeId: 1)
    }

    try queue.read { db in
      let header = try Row.fetchOne(
        db, sql: "SELECT * FROM cooking_history_nutrition_snapshots WHERE history_id = 30")!
      XCTAssertEqual(header["snapshot_version"] as Int, NutritionSnapshot.currentVersion)
      XCTAssertEqual(header["provenance"] as String, "logged_at_capture")
      XCTAssertEqual(header["recipe_servings"] as Int, 2)

      let ing3 = try Row.fetchOne(db, sql: "SELECT * FROM ingredients WHERE id = 3")!
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT * FROM cooking_history_nutrition_lines WHERE history_id = 30 ORDER BY line_index")
      XCTAssertEqual(rows.count, 3)

      // Fractional grams and the unswapped ratio.
      XCTAssertEqual(rows[0]["original_ingredient_id"] as Int64, 1)
      XCTAssertEqual(rows[0]["substitute_ingredient_id"] as Int64?, 3)
      XCTAssertEqual(bits(rows[0]["quantity_grams"] as Double), bits(150.0))
      XCTAssertEqual(bits(rows[0]["swap_ratio"] as Double), bits(1.25))
      for nutrient in ["calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium"] {
        XCTAssertEqual(
          bits(rows[0][nutrient] as Double), bits(ing3[nutrient] as Double),
          "captured line \(nutrient) must freeze the substitute's per-100g value")
      }

      // Unswapped lines freeze ratio 1.0 and the original's values.
      XCTAssertEqual(rows[1]["substitute_ingredient_id"] as Int64?, nil)
      XCTAssertEqual(bits(rows[1]["swap_ratio"] as Double), bits(1.0))
      XCTAssertEqual(bits(rows[1]["quantity_grams"] as Double), bits(33.75))
    }
  }

  func testCaptureFailureRollsBackHistorySwapsStreakAndInventory() throws {
    let queue = try v18World("capture-rollback")
    try DatabaseMigrations.migrate(queue)
    let service = NutritionSnapshotService(db: queue)

    // The composed log transaction: history + swaps + streak + inventory
    // lot/event/item, then the snapshot capture. The capture is injected a
    // failure by pointing at a recipe that does not exist.
    XCTAssertThrowsError(
      try queue.write { db in
        try Fixtures.insertMeal(db, .init(
          id: 31, recipeId: 1, cookedAt: "2026-10-02 09:00:00.000",
          servingsConsumed: 1, portion: 1.0, swaps: [
            .init(originalId: 3, substituteId: 2, ratio: 0.5),
          ]
        ))
        try Fixtures.insertComposedLogWrites(db, ingredientId: 1, day: "2026-10-02")
        try service.captureSnapshot(in: db, historyId: 31, recipeId: 99999)
      }
    )

    try queue.read { db in
      // The fixture world pre-seeded four meals (10 snapshot lines, 1 swap).
      // The failed capture must add nothing to any of them: not the new
      // history, not its swap, not the streak, not any composed inventory
      // write.
      for (table, expected, label) in [
        ("cooking_history", 4, "history"),
        ("cooking_history_swaps", 1, "swaps"),
        ("streaks", 0, "streak"),
        ("inventory_lots", 0, "inventory lot"),
        ("inventory_events", 0, "inventory event"),
        ("inventory_items", 0, "inventory item"),
        ("cooking_history_nutrition_snapshots", 4, "snapshot"),
        ("cooking_history_nutrition_lines", 10, "snapshot lines"),
      ] {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        XCTAssertEqual(count, expected, "\(label) must roll back with the failed capture")
      }
    }
  }

  // MARK: - Guards and fallbacks

  func testMissingSnapshotThrowsInsteadOfCatalogFallback() throws {
    let queue = try v18World("missing-snapshot")
    try DatabaseMigrations.migrate(queue)

    // A meal logged before snapshots existed (no snapshot row): frozen
    // servings must throw instead of falling back to the mutable catalog.
    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [Int64(32), Int64(1), "2026-10-02 10:00:00.000", NSNull(), NSNull(), 1.0]
      )
    }

    XCTAssertThrowsError(
      try queue.read { db in
        _ = try NutritionSnapshot.frozenServings(in: db, historyId: 32)
      }
    )
  }

  func testUnsupportedSnapshotVersionThrows() throws {
    let queue = try v18World("version-guard")
    try DatabaseMigrations.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: "UPDATE cooking_history_nutrition_snapshots SET snapshot_version = ? WHERE history_id = 1",
        arguments: [NutritionSnapshot.currentVersion + 1]
      )
    }

    XCTAssertThrowsError(
      try queue.read { db in
        _ = try NutritionSnapshot.frozenServings(in: db, historyId: 1)
      }
    )
  }

  func testNullConsumedServingsFallBackToFrozenServings() throws {
    let queue = try v18World("consumed-fallback")
    try DatabaseMigrations.migrate(queue)

    // Meal 2 has NULL servings_consumed and portion 0.75: the fallback count
    // is the FROZEN recipe servings (2), not the mutable catalog.
    let totals = try queue.read { db in
      try NutritionSnapshot.consumedTotals(
        in: db, historyId: 2, storedServingsConsumed: nil, portionMultiplier: 0.75)
    }

    // Journal arithmetic, grouped exactly as the SQL evaluates it:
    // SUM((nutrient / 100) * grams * ratio) per line in line_index order,
    // then × (consumed × portion / max(frozenServings, 1)).
    // Meal 2 has no swaps: 150g ing1, 33.75g ing2, 30.5g ing3 at ratio 1.0.
    let ing1 = Fixtures.ingredients[0]
    let ing2 = Fixtures.ingredients[1]
    let ing3 = Fixtures.ingredients[2]
    let expected =
      ((ing1.calories / 100.0) * 150.0)
      + ((ing2.calories / 100.0) * 33.75)
      + ((ing3.calories / 100.0) * 30.5)
    XCTAssertEqual(
      bits(totals.calories),
      bits(expected * (2.0 * 0.75 / 2.0)),
      "NULL consumed servings must fall back to the frozen servings")
  }

  func testSqliteVersionAndMigrationBounds() throws {
    let queue = try Fixtures.makeQueue("bounds")
    try DatabaseMigrations.migrate(queue)

    let (version, applied) = try queue.read { db -> (String, [String]) in
      let version = try String.fetchOne(db, sql: "SELECT sqlite_version()")!
      let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
      return (version, applied)
    }

    // Self-reporting record of the environment the checks ran against.
    print("CHECK sqlite_version=\(version)")
    print("CHECK migrations_applied=\(applied.joined(separator: ","))")
    // The migration registry ends at v20: this branch adds the last one and
    // registers nothing after it.
    XCTAssertEqual(applied.last, "v20_historical_nutrition_snapshots")
  }

  // MARK: - recordCooking capture paths

  func testEveryRecordCookingPathCapturesASnapshot() throws {
    let queue = try v18World("record-paths")
    try DatabaseMigrations.migrate(queue)
    let personalization = PersonalizationService(db: queue)

    // Queue-level path: used by the meal finalization view.
    let fromQueueOverload = try personalization.recordCooking(
      recipeId: 1, rating: 5, servingsConsumed: 1, portionMultiplier: 1.0)
    // Transaction-scoped path: used by MealLogService's composed log.
    let fromTransactionOverload = try queue.write { db in
      try personalization.recordCooking(in: db, recipeId: 2, portionMultiplier: 1.0, swaps: [])
    }

    try queue.read { db in
      // Recipe 1 has three required ingredients; recipe 2 is the empty
      // recipe and completes with a zero-line snapshot, like the backfill.
      for (historyId, expectedLines) in [(fromQueueOverload, 3), (fromTransactionOverload, 0)] {
        let snapshotCount = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM cooking_history_nutrition_snapshots WHERE history_id = ?",
          arguments: [historyId])
        XCTAssertEqual(
          snapshotCount, 1,
          "history \(historyId) logged without a snapshot would break historical reads")
        let recordedProvenance = try String.fetchOne(
          db,
          sql: "SELECT provenance FROM cooking_history_nutrition_snapshots WHERE history_id = ?",
          arguments: [historyId])
        XCTAssertEqual(recordedProvenance, "logged_at_capture")
        let lineCount = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM cooking_history_nutrition_lines WHERE history_id = ?",
          arguments: [historyId])
        XCTAssertEqual(
          lineCount, expectedLines, "history \(historyId) captured the wrong line count")
      }
    }
  }

  // MARK: - Shared bundled-refresh readiness provider

  func testReadinessProviderAcceptsCompleteHistoryAndRejectsGaps() throws {
    let queue = try v18World("readiness")
    try DatabaseMigrations.migrate(queue)
    let service = NutritionSnapshotService(db: queue)

    // Complete history at the current version passes.
    try queue.read { db in
      try service.verifyHistoricalSnapshotReadiness(in: db)
    }

    // A stale snapshot version refuses the refresh.
    XCTAssertThrowsError(
      try queue.write { db in
        try db.execute(
          sql: "UPDATE cooking_history_nutrition_snapshots SET snapshot_version = 99 WHERE history_id = 1")
        try service.verifyHistoricalSnapshotReadiness(in: db)
      }
    )

    // A missing snapshot header refuses the refresh.
    XCTAssertThrowsError(
      try queue.write { db in
        try db.execute(
          sql: "DELETE FROM cooking_history_nutrition_snapshots WHERE history_id = 2")
        try service.verifyHistoricalSnapshotReadiness(in: db)
      }
    )

    // The refused writes rolled back; the world is ready again.
    try queue.read { db in
      try service.verifyHistoricalSnapshotReadiness(in: db)
    }
  }
}
