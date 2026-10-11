import Foundation
import GRDB
import XCTest

@testable import NutritionCheck

/// Cutover parity: after the v18 → v20 upgrade, the snapshot-backed day/today
/// aggregates, per-meal journal totals, and captured (Apple Health) macros must
/// equal — bit for bit, `Double.bitPattern` — what the ORIGINAL aggregation
/// paths computed on the same rows.
///
/// The original paths are the pre-branch production code, copied verbatim:
/// the catalog-based SUM queries from `UserDataRepository` (operator order and
/// column affinity preserved exactly, including `/ 100.0`, the COALESCE chain,
/// and the recipes join), and the old `NutritionService.macros` Swift-side
/// fold that fed Apple Health before snapshots.
///
/// A genuine bit mismatch is preserved, not tuned away: it fails this test
/// with both operands' bit patterns so the explanation can be recorded in the
/// PR handoff instead of the comparison being loosened.
final class CutoverParityTests: XCTestCase {
  // MARK: - Bit helpers

  private func bits(_ value: Double) -> String {
    String(format: "%016llx", value.bitPattern)
  }

  private func assertBitEqual(
    _ label: String, _ old: Double, _ new: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      old.bitPattern, new.bitPattern,
      "\(label): original path bits 0x\(bits(old)) vs snapshot path bits 0x\(bits(new)) "
        + "(values \(old) / \(new)) — genuine mismatch preserved for explanation",
      file: file, line: line)
  }

  // MARK: - Original aggregation paths (verbatim pre-branch SQL)

  /// The original `UserDataRepository.todayMacros` catalog-based query.
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

  /// The original `UserDataRepository.dailyMacroTotals` catalog-based grouped
  /// query — one grouped pass over the window, exactly as production ran it.
  private func oldDailyMacros(db: Database, lastDays: Int) throws -> [String: [String: Double]] {
    let safeDays = max(1, lastDays)
    let modifier = "-\(safeDays - 1) days"
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT date(ch.cooked_at, 'localtime') AS day,
               SUM(
                 (i.calories / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
                 * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
               ) AS total_cal,
               SUM(
                 (i.protein / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
                 * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
               ) AS total_pro,
               SUM(
                 (i.carbs / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
                 * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
               ) AS total_carb,
               SUM(
                 (i.fat / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0) / r.servings)
                 * COALESCE(ch.servings_consumed, r.servings) * ch.portion_multiplier
               ) AS total_fat
        FROM cooking_history ch
        JOIN recipes r ON r.id = ch.recipe_id
        JOIN recipe_ingredients ri ON ri.recipe_id = r.id AND ri.is_required = 1
        LEFT JOIN cooking_history_swaps sw
          ON sw.history_id = ch.id AND sw.original_ingredient_id = ri.ingredient_id
        JOIN ingredients i ON i.id = COALESCE(sw.substitute_ingredient_id, ri.ingredient_id)
        WHERE datetime(ch.cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
        GROUP BY day
        ORDER BY day ASC
        """,
      arguments: [modifier]
    )
    var byDay: [String: [String: Double]] = [:]
    for row in rows {
      guard let day: String = row["day"] else { continue }
      byDay[day] = [
        "cal": row["total_cal"] as? Double ?? 0,
        "pro": row["total_pro"] as? Double ?? 0,
        "carb": row["total_carb"] as? Double ?? 0,
        "fat": row["total_fat"] as? Double ?? 0,
      ]
    }
    return byDay
  }

  /// The original per-meal journal fold: SUM over required recipe ingredients
  /// (swap-adjusted), then scaled outside SQL by consumed × portion / servings.
  private func oldJournalMacros(
    db: Database, historyId: Int64, recipeServings: Int, storedConsumed: Int?, portion: Double
  ) throws -> [String: Double] {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COALESCE(SUM(i.calories / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0)), 0) AS total_cal,
          COALESCE(SUM(i.protein / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0)), 0) AS total_pro,
          COALESCE(SUM(i.carbs / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0)), 0) AS total_carb,
          COALESCE(SUM(i.fat / 100.0 * ri.quantity_grams * COALESCE(sw.ratio, 1.0)), 0) AS total_fat
        FROM recipe_ingredients ri
        LEFT JOIN cooking_history_swaps sw
          ON sw.history_id = ? AND sw.original_ingredient_id = ri.ingredient_id
        JOIN ingredients i ON i.id = COALESCE(sw.substitute_ingredient_id, ri.ingredient_id)
        WHERE ri.recipe_id = (SELECT recipe_id FROM cooking_history WHERE id = ?) AND ri.is_required = 1
        """,
      arguments: [historyId, historyId]
    )
    guard let row else { return ["cal": 0, "pro": 0, "carb": 0, "fat": 0] }
    let consumed = storedConsumed ?? recipeServings
    let factor = Double(consumed) * portion / Double(max(recipeServings, 1))
    return [
      "cal": (row["total_cal"] as? Double ?? 0) * factor,
      "pro": (row["total_pro"] as? Double ?? 0) * factor,
      "carb": (row["total_carb"] as? Double ?? 0) * factor,
      "fat": (row["total_fat"] as? Double ?? 0) * factor,
    ]
  }

  // MARK: - Fixture

  private struct LocalMeal {
    let id: Int64
    let recipeId: Int64
    let cookedAtSQL: String  // evaluated by SQLite, so 'today' is self-consistent
    let consumed: Int?
    let portion: Double
    let swap: (original: Int64, substitute: Int64, ratio: Double)?
  }

  /// Today/yesterday are computed by SQLite itself so the dated reads and the
  /// old paths always see the same day boundary, whatever the host clock.
  private func seedWorld(_ name: String) throws -> DatabaseQueue {
    let queue = try Fixtures.makeQueue(name)
    try DatabaseMigrations.migrate(queue, upTo: Fixtures.v18)
    try queue.write { db in
      try Fixtures.insertCatalog(db)

      // Same fractional-gram corpus as the backfill tests, with a substitute
      // swap at a non-terminating ratio, NULL consumed servings, a fractional
      // portion, and a yesterday meal so the 7-day window is not degenerate.
      let meals: [LocalMeal] = [
        .init(id: 11, recipeId: 1, cookedAtSQL: "datetime('now','localtime','-90 minutes')",
              consumed: 1, portion: 1.0, swap: (3, 2, 0.333333)),
        .init(id: 12, recipeId: 1, cookedAtSQL: "datetime('now','localtime','-40 minutes')",
              consumed: nil, portion: 0.75, swap: nil),
        .init(id: 13, recipeId: 3, cookedAtSQL: "datetime('now','localtime','-20 minutes')",
              consumed: 1, portion: 1.0, swap: nil),
        .init(id: 14, recipeId: 1, cookedAtSQL: "datetime('now','localtime','-1 day')",
              consumed: 2, portion: 1.3, swap: nil),
      ]
      for meal in meals {
        try db.execute(
          sql: """
            INSERT INTO cooking_history (id, recipe_id, cooked_at, rating, servings_consumed, portion_multiplier)
            VALUES (?, ?, \(meal.cookedAtSQL), NULL, ?, ?)
            """,
          arguments: [meal.id, meal.recipeId, meal.consumed ?? NSNull(), meal.portion]
        )
        if let swap = meal.swap {
          try db.execute(
            sql: """
              INSERT INTO cooking_history_swaps (history_id, original_ingredient_id, substitute_ingredient_id, ratio)
              VALUES (?, ?, ?, ?)
              """,
            arguments: [meal.id, swap.original, swap.substitute, swap.ratio]
          )
        }
      }
    }
    return queue
  }

  // MARK: - The parity check

  func testCutoverAggregatesJournalAndHealthBitsMatchOriginalPaths() throws {
    let queue = try seedWorld("cutover-parity")

    // 1. Original-path references on the v18 world (before any snapshot).
    let oldServings = try queue.read { db -> [Int64: Int] in
      let ids: [Int64] = [11, 12, 13, 14]
      var out: [Int64: Int] = [:]
      for id in ids {
        let recipeId = try Int64.fetchOne(
          db, sql: "SELECT recipe_id FROM cooking_history WHERE id = ?", arguments: [id])!
        out[id] = try Int.fetchOne(
          db, sql: "SELECT servings FROM recipes WHERE id = ?", arguments: [recipeId])!
      }
      return out
    }
    let consumed: [Int64: Int?] = [11: 1, 12: nil, 13: 1, 14: 2]
    let portions: [Int64: Double] = [11: 1.0, 12: 0.75, 13: 1.0, 14: 1.3]

    let oldToday = try queue.read { db in try oldTodayMacros(db: db) }
    let oldDaily = try queue.read { db in try oldDailyMacros(db: db, lastDays: 7) }
    let oldJournal = try queue.read { db -> [Int64: [String: Double]] in
      var out: [Int64: [String: Double]] = [:]
      for id in [Int64(11), 12, 13, 14] {
        out[id] = try oldJournalMacros(
          db: db, historyId: id, recipeServings: oldServings[id]!,
          storedConsumed: consumed[id]!, portion: portions[id]!)
      }
      return out
    }

    // Old per-serving (Apple Health) reference: the old NutritionService.macros
    // fold, computed from the same catalog rows.
    func oldPerServing(db: Database, recipeId: Int64, swap: (original: Int64, substitute: Int64, ratio: Double)?) throws -> [String: Double] {
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT i.calories, i.protein, i.carbs, i.fat, i.fiber, i.sugar, i.sodium,
                 ri.quantity_grams, ri.ingredient_id
          FROM recipe_ingredients ri
          JOIN ingredients i ON i.id = ri.ingredient_id
          WHERE ri.recipe_id = ? AND ri.is_required = 1
          ORDER BY ri.rowid
          """,
        arguments: [recipeId]
      )
      var totals = ["cal": 0.0, "pro": 0.0, "carb": 0.0, "fat": 0.0, "fib": 0.0, "sug": 0.0, "sod": 0.0]
      for row in rows {
        let ingId: Int64 = row["ingredient_id"]
        var grams: Double = row["quantity_grams"]
        var sub: Row? = nil
        if let swap, swap.original == ingId {
          grams *= swap.ratio
          sub = try Row.fetchOne(
            db, sql: "SELECT calories, protein, carbs, fat, fiber, sugar, sodium FROM ingredients WHERE id = ?",
            arguments: [swap.substitute])
        }
        let factor = grams / 100.0
        totals["cal"]! += (sub?["calories"] ?? (row["calories"] as Double)) * factor
        totals["pro"]! += (sub?["protein"] ?? (row["protein"] as Double)) * factor
        totals["carb"]! += (sub?["carbs"] ?? (row["carbs"] as Double)) * factor
        totals["fat"]! += (sub?["fat"] ?? (row["fat"] as Double)) * factor
        totals["fib"]! += (sub?["fiber"] ?? (row["fiber"] as Double)) * factor
        totals["sug"]! += (sub?["sugar"] ?? (row["sugar"] as Double)) * factor
        totals["sod"]! += (sub?["sodium"] ?? (row["sodium"] as Double)) * factor
      }
      let servings = Double(try Int.fetchOne(
        db, sql: "SELECT servings FROM recipes WHERE id = ?", arguments: [recipeId]) ?? 0)
      guard servings > 0 else {
        return ["cal": 0, "pro": 0, "carb": 0, "fat": 0, "fib": 0, "sug": 0, "sod": 0]
      }
      for key in totals.keys { totals[key]! /= servings }
      // The original NutritionService.macros converted sodium from grams to
      // milligrams here ((totalSod / servings) * 1000) — RecipeMacros
      // documents sodiumPerServing as milligrams. Missing this conversion is
      // a reference bug, not a product difference.
      totals["sod"]! *= 1000
      return totals
    }
    let oldHealth = try queue.read { db -> [Int64: [String: Double]] in
      var out: [Int64: [String: Double]] = [:]
      for (id, recipeId) in [(Int64(11), Int64(1)), (12, 1), (13, 3), (14, 1)] {
        let swap: (original: Int64, substitute: Int64, ratio: Double)? =
          (id == 11) ? (3, 2, 0.333333) : nil
        out[id] = try oldPerServing(db: db, recipeId: recipeId, swap: swap)
      }
      return out
    }

    // 2. Upgrade and read through the snapshot-backed paths.
    try DatabaseMigrations.migrate(queue)
    let repo = UserDataRepository(db: queue)
    let snapshotService = NutritionSnapshotService(db: queue)

    let newToday = try repo.todayMacros()
    assertBitEqual("today.calories", oldToday["cal"]!, newToday.calories)
    assertBitEqual("today.protein", oldToday["pro"]!, newToday.protein)
    assertBitEqual("today.carbs", oldToday["carb"]!, newToday.carbs)
    assertBitEqual("today.fat", oldToday["fat"]!, newToday.fat)

    let newDaily = try repo.dailyMacroTotals(lastDays: 7)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    var comparedNonZero = 0
    for point in newDaily {
      let key = formatter.string(from: point.date)
      // The old grouped query emits a row only for days that had meals; days
      // without rows are the unchanged zero-fill behavior.
      let old = oldDaily[key] ?? ["cal": 0, "pro": 0, "carb": 0, "fat": 0]
      assertBitEqual("day \(key).calories", old["cal"]!, point.calories)
      assertBitEqual("day \(key).protein", old["pro"]!, point.protein)
      assertBitEqual("day \(key).carbs", old["carb"]!, point.carbs)
      assertBitEqual("day \(key).fat", old["fat"]!, point.fat)
      if old["cal"]! != 0 { comparedNonZero += 1 }
    }
    XCTAssertGreaterThanOrEqual(comparedNonZero, 2, "expected today and yesterday to carry data")

    let journal = try repo.cookingJournal(limit: 50)
    for id in [Int64(11), 12, 13, 14] {
      let entry = try XCTUnwrap(journal.first(where: { $0.id == id }), "journal entry \(id) missing")
      let old = oldJournal[id]!
      assertBitEqual("journal \(id).calories", old["cal"]!, entry.macrosConsumed.calories)
      assertBitEqual("journal \(id).protein", old["pro"]!, entry.macrosConsumed.protein)
      assertBitEqual("journal \(id).carbs", old["carb"]!, entry.macrosConsumed.carbs)
      assertBitEqual("journal \(id).fat", old["fat"]!, entry.macrosConsumed.fat)
    }

    // Captured macros feed Apple Health (MealLogSyncCoordinator); they must
    // equal the old per-serving computation bit for bit, all seven nutrients.
    for id in [Int64(11), 12, 13, 14] {
      let captured = try snapshotService.capturedMacros(historyId: id)
      let old = oldHealth[id]!
      assertBitEqual("health \(id).caloriesPerServing", old["cal"]!, captured.caloriesPerServing)
      assertBitEqual("health \(id).proteinPerServing", old["pro"]!, captured.proteinPerServing)
      assertBitEqual("health \(id).carbsPerServing", old["carb"]!, captured.carbsPerServing)
      assertBitEqual("health \(id).fatPerServing", old["fat"]!, captured.fatPerServing)
      assertBitEqual("health \(id).fiberPerServing", old["fib"]!, captured.fiberPerServing)
      assertBitEqual("health \(id).sugarPerServing", old["sug"]!, captured.sugarPerServing)
      assertBitEqual("health \(id).sodiumPerServing", old["sod"]!, captured.sodiumPerServing)
    }
  }
}
