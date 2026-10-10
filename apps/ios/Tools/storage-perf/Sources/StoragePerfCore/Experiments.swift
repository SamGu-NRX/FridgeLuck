import Foundation
import GRDB

// MARK: - Index / query experiments
//
// Alternatives run ONLY in disposable experiment databases (fresh seeded files
// in a temp directory, deleted afterwards). Production schema, indexes, and
// Migrations.swift are never touched here — an experiment's CREATE INDEX lives
// and dies with its disposable file.
//
// Every alternative must clear two gates before it counts as valid:
//   1. exact output parity — decoded result rows equal the production query's,
//      value for value in order (doubles compared by raw bit pattern);
//   2. bit-sensitive nutrition parity — every nutrition total reproduces the
//      production double exactly (bitPattern equality), because report values
//      feed Apple Health and the nutrition log where a 1-ulp drift would show.
//
// A gate failure is a FINDING (the alternative is rejected), not a crash.

struct ExperimentResult {
  var name: String
  var description: String
  var alternativeIndex: String?
  var baselinePlan: [PlanRow]
  var alternativePlan: [PlanRow]
  var exactOutputParity: Bool
  var nutritionBitParity: Bool
  var baselineUs: [Int64]
  var alternativeUs: [Int64]
  var notes: String

  var passes: Bool { exactOutputParity && nutritionBitParity }
}

enum IndexExperiments {
  static func run(
    directory: String, seed: UInt64, warmup: Int, iterations: Int
  ) throws -> [ExperimentResult] {
    // five_year 4x: large enough for plans to differentiate, small enough to
    // seed the disposable copy quickly.
    let seeded = try WorkloadSeeder.makeSeeded(
      profile: .fiveYear, scale: 4, seed: seed, directory: directory,
      name: "experiment_base")
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try run(on: seeded, warmup: warmup, iterations: iterations)
  }

  static func run(on seeded: SeededDatabase, warmup: Int, iterations: Int) throws
    -> [ExperimentResult]
  {
    var results: [ExperimentResult] = []
    results.append(try useSoonStringBounds(seeded, warmup: warmup, iterations: iterations))
    results.append(try activeItemsWindow(seeded, warmup: warmup, iterations: iterations))
    results.append(try journalBatch(seeded, warmup: warmup, iterations: iterations))
    results.append(try dailyMacrosBoundary(seeded, warmup: warmup, iterations: iterations))
    return results
  }

  // --- helpers -----------------------------------------------------------

  /// Canonical row rendering with doubles as raw bit patterns, so "equal" is
  /// bit-sensitive end to end.
  private static func canonicalRows(_ rows: [[QueryValue]]) -> String {
    rows.map { row in
      "[" + row.map(\.canonical).joined(separator: ",") + "]"
    }.joined(separator: "\n")
  }

  private static func sha(_ rows: [[QueryValue]]) -> String {
    SHA256.hex(canonicalRows(rows))
  }

  private static func timeRepeated(
    warmup: Int, iterations: Int, _ body: () throws -> Void
  ) rethrows -> [Int64] {
    var samples: [Int64] = []
    for _ in 0..<warmup { _ = try Metrics.timeUs(body) }
    for _ in 0..<iterations { samples.append(try Metrics.timeUs(body)) }
    return samples
  }

  // --- E1: useSoonSuggestions with direct string bounds + covering index ----

  /// The production query wraps both sides in datetime() — that defeats every
  /// index on expires_at. Because GRDB stores dates as 'YYYY-MM-DD HH:MM:SS.SSS'
  /// UTC text, plain lexicographic string comparisons can replace the
  /// datetime() calls, letting a (remaining_grams, expires_at, ingredient_id)
  /// index serve the filter. Gated on exact output parity.
  private static func useSoonStringBounds(
    _ seeded: SeededDatabase, warmup: Int, iterations: Int
  ) throws -> ExperimentResult {
    let baselineSQL = MirroredQueries.all.first { $0.name == "inventory_use_soon" }!.sql

    // Now-boundaries computed the way SQLite computes them for the same rows.
    let formatter = utcFormatter()
    let now = Date()
    let plus3 = formatter.string(from: now.addingTimeInterval(3 * 86400))

    let alternativeSQL = """
      SELECT
        il.ingredient_id AS ingredient_id,
        i.name AS ingredient_name,
        SUM(il.remaining_grams) AS remaining_grams,
        MIN(il.expires_at) AS earliest_expires_at,
        AVG(il.confidence_score) AS avg_confidence_score
      FROM inventory_lots il
      JOIN ingredients i ON i.id = il.ingredient_id
      WHERE il.remaining_grams > 0
        AND il.expires_at IS NOT NULL
        AND il.expires_at >= ?
        AND il.expires_at <= ?
      GROUP BY il.ingredient_id, i.name
      ORDER BY datetime(earliest_expires_at) ASC, remaining_grams DESC
      LIMIT 12
      """

    // A write connection: E1 materializes its experiment index (idx_exp_use_soon)
    // in the disposable seeded copy only — production schema is never touched.
    return try seeded.dbQueue.write { db in
      let baselineRows = try rows(db: db, sql: baselineSQL, arguments: ["+3 days", 12])
      let altRowsBeforeIndex = try rows(
        db: db, sql: alternativeSQL, arguments: [formatter.string(from: now), plus3])
      let baselineTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try rows(db: db, sql: baselineSQL, arguments: ["+3 days", 12])
      }

      try db.execute(
        sql: """
          CREATE INDEX idx_exp_use_soon
          ON inventory_lots(remaining_grams, expires_at, ingredient_id)
          """)
      try? db.execute(sql: "ANALYZE")
      let altRows = try rows(
        db: db, sql: alternativeSQL, arguments: [formatter.string(from: now), plus3])
      let altTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try rows(db: db, sql: alternativeSQL, arguments: [formatter.string(from: now), plus3])
      }

      let baselinePlan = try Metrics.explainQueryPlan(db: db, sql: baselineSQL, arguments: ["+3 days", 12])
      let altPlan = try Metrics.explainQueryPlan(
        db: db, sql: alternativeSQL, arguments: [formatter.string(from: now), plus3])

      // Parity is judged against the unindexed alternative run: the index may
      // only change the plan, never the rows.
      let altSelfParity = sha(altRowsBeforeIndex) == sha(altRows)
      let exact = altSelfParity && sha(baselineRows) == sha(altRows)
      let nutritionBit = nutritionBitsEqual(baselineRows, altRows)

      return ExperimentResult(
        name: "use_soon_string_bounds",
        description:
          "useSoonSuggestions: replace datetime() wrappers with direct string bounds; covering index (remaining_grams, expires_at, ingredient_id)",
        alternativeIndex: "inventory_lots(remaining_grams, expires_at, ingredient_id)",
        baselinePlan: baselinePlan,
        alternativePlan: altPlan,
        exactOutputParity: exact,
        nutritionBitParity: nutritionBit,
        baselineUs: baselineTiming,
        alternativeUs: altTiming,
        notes:
          "SUM/AVG order can shift when the plan changes; bit parity is measured and reported, not assumed."
      )
    }
  }

  // --- E2: fetchAllActiveItems without the correlated subquery --------------

  /// The most_recent_source correlated subquery runs once per output group.
  /// Alternative: one window-function pass (ROW_NUMBER over acquired_at) with
  /// the same tie-breaking the subquery's LIMIT 1 exposes.
  private static func activeItemsWindow(
    _ seeded: SeededDatabase, warmup: Int, iterations: Int
  ) throws -> ExperimentResult {
    let baselineSQL = MirroredQueries.all.first { $0.name == "inventory_active_items" }!.sql

    let alternativeSQL = """
      WITH ranked AS (
        SELECT
          il.ingredient_id AS ingredient_id,
          il.storage_location AS storage_location,
          il.source AS source,
          ROW_NUMBER() OVER (
            PARTITION BY il.ingredient_id, il.storage_location
            ORDER BY il.acquired_at DESC, il.id DESC
          ) AS rn
        FROM inventory_lots il
        WHERE il.remaining_grams > 0
      )
      SELECT
        il.ingredient_id AS ingredient_id,
        i.name AS ingredient_name,
        il.storage_location AS storage_location,
        SUM(il.remaining_grams) AS total_remaining_grams,
        AVG(il.confidence_score) AS avg_confidence_score,
        MIN(il.expires_at) AS earliest_expires_at,
        MAX(il.updated_at) AS last_updated_at,
        COUNT(il.id) AS lot_count,
        MAX(il.quantity_is_estimate) AS has_estimated_quantity,
        (SELECT source FROM ranked
         WHERE ranked.ingredient_id = il.ingredient_id
           AND ranked.storage_location = il.storage_location
           AND ranked.rn = 1) AS most_recent_source
      FROM inventory_lots il
      JOIN ingredients i ON i.id = il.ingredient_id
      WHERE il.remaining_grams > 0
      GROUP BY il.ingredient_id, il.storage_location
      ORDER BY i.name ASC
      """

    return try seeded.dbQueue.read { db in
      let baselineRows = try rows(db: db, sql: baselineSQL, arguments: [])
      let altRows = try rows(db: db, sql: alternativeSQL, arguments: [])
      let baselineTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try rows(db: db, sql: baselineSQL, arguments: [])
      }
      let altTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try rows(db: db, sql: alternativeSQL, arguments: [])
      }
      let baselinePlan = try Metrics.explainQueryPlan(db: db, sql: baselineSQL, arguments: [])
      let altPlan = try Metrics.explainQueryPlan(db: db, sql: alternativeSQL, arguments: [])

      let exact = baselineRows.count == altRows.count && sha(baselineRows) == sha(altRows)
      return ExperimentResult(
        name: "active_items_window",
        description:
          "fetchAllActiveItems: replace the per-group correlated subquery with a window-function ranking CTE (same tie-break: acquired_at DESC)",
        alternativeIndex: nil,
        baselinePlan: baselinePlan,
        alternativePlan: altPlan,
        exactOutputParity: exact,
        nutritionBitParity: true,  // no nutrition columns in this read
        baselineUs: baselineTiming,
        alternativeUs: altTiming,
        notes: "most_recent_source ties broken by acquired_at DESC, id DESC in both forms."
      )
    }
  }

  // --- E3: cookingJournal batching the per-row snapshot lookups -------------

  /// Production cookingJournal runs 2 extra queries per history row (N+1:
  /// frozenServings + consumedTotals). Alternative: one batched aggregate over
  /// the same page, gated on per-meal macro bit parity against the production
  /// per-row results.
  private static func journalBatch(
    _ seeded: SeededDatabase, warmup: Int, iterations: Int
  ) throws -> ExperimentResult {
    let pageSQL = MirroredQueries.all.first { $0.name == "journal_page_200" }!.sql

    return try seeded.dbQueue.read { db in
      // Production path: page query + frozenServings + consumedTotals per row.
      func productionMacros() throws -> [(Int64, (Double, Double, Double, Double))] {
        let pageRows = try Row.fetchAll(db, sql: pageSQL, arguments: StatementArguments([]))
        var out: [(Int64, (Double, Double, Double, Double))] = []
        for row in pageRows {
          let historyId: Int64 = row["history_id"]
          let storedServingsConsumed: Int? = row["servings_consumed"]
          let portionMultiplier: Double = row["portion_multiplier"] ?? 1.0
          let totals = try NutritionSnapshot.consumedTotals(
            in: db, historyId: historyId,
            storedServingsConsumed: storedServingsConsumed,
            portionMultiplier: portionMultiplier)
          out.append((historyId, (totals.calories, totals.protein, totals.carbs, totals.fat)))
        }
        return out
      }

      let batchedSQL = """
        SELECT
          ch.id AS history_id,
          SUM(
            (l.calories / 100.0 * l.quantity_grams * l.swap_ratio)
            * COALESCE(ch.servings_consumed, s.recipe_servings) / s.recipe_servings
            * ch.portion_multiplier
          ) AS total_cal,
          SUM(
            (l.protein / 100.0 * l.quantity_grams * l.swap_ratio)
            * COALESCE(ch.servings_consumed, s.recipe_servings) / s.recipe_servings
            * ch.portion_multiplier
          ) AS total_pro,
          SUM(
            (l.carbs / 100.0 * l.quantity_grams * l.swap_ratio)
            * COALESCE(ch.servings_consumed, s.recipe_servings) / s.recipe_servings
            * ch.portion_multiplier
          ) AS total_carb,
          SUM(
            (l.fat / 100.0 * l.quantity_grams * l.swap_ratio)
            * COALESCE(ch.servings_consumed, s.recipe_servings) / s.recipe_servings
            * ch.portion_multiplier
          ) AS total_fat
        FROM cooking_history ch
        JOIN cooking_history_nutrition_snapshots s ON s.history_id = ch.id
        JOIN cooking_history_nutrition_lines l ON l.history_id = ch.id
        WHERE ch.id IN (
          SELECT ch2.id FROM cooking_history ch2
          ORDER BY ch2.cooked_at DESC
          LIMIT 200
        )
        GROUP BY ch.id
        """

      func batchedRows() throws -> [(Int64, (Double, Double, Double, Double))] {
        let rows = try Row.fetchAll(db, sql: batchedSQL, arguments: StatementArguments([]))
        return rows.map { row in
          (
            row["history_id"] as Int64,
            (
              row["total_cal"] as? Double ?? 0,
              row["total_pro"] as? Double ?? 0,
              row["total_carb"] as? Double ?? 0,
              row["total_fat"] as? Double ?? 0
            )
          )
        }
      }

      let baseline = try productionMacros()
      let alt = try batchedRows()

      let baselineTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try productionMacros()
      }
      let altTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try batchedRows()
      }

      // Exact parity: same ids in the same order and bit-equal macro doubles.
      // The batched form factors (x/servings) * consumed * multiplier
      // differently than consumedTotals' x * consumed / servings — if SQLite
      // rounds differently the bit gate fails and the alternative is rejected.
      let exact =
        baseline.map(\.0) == alt.map(\.0)
        && zip(baseline, alt).allSatisfy { lhs, rhs in
          lhs.1.0.bitPattern == rhs.1.0.bitPattern
            && lhs.1.1.bitPattern == rhs.1.1.bitPattern
            && lhs.1.2.bitPattern == rhs.1.2.bitPattern
            && lhs.1.3.bitPattern == rhs.1.3.bitPattern
        }

      let baselinePlan = try Metrics.explainQueryPlan(db: db, sql: pageSQL, arguments: [])
      let altPlan = try Metrics.explainQueryPlan(db: db, sql: batchedSQL, arguments: [])

      return ExperimentResult(
        name: "journal_batch",
        description:
          "cookingJournal: batch the per-row frozenServings/consumedTotals lookups into one aggregate over the 200-row page",
        alternativeIndex: nil,
        baselinePlan: baselinePlan,
        alternativePlan: altPlan,
        exactOutputParity: exact,
        nutritionBitParity: exact,
        baselineUs: baselineTiming,
        alternativeUs: altTiming,
        notes:
          "Bit gate requires the batched arithmetic to reproduce per-meal consumedTotals doubles exactly; any association difference rejects the alternative."
      )
    }
  }

  // --- E4: dailyMacroTotals with a raw cooked_at boundary prefilter ---------

  /// Production filters meals with datetime(ch.cooked_at,'localtime') >=
  /// datetime(date('now','localtime',?)) — a function evaluation per row.
  /// Alternative: prefilter ch.cooked_at >= boundary (UTC text comparison)
  /// before the same localtime condition. The same row set must result.
  private static func dailyMacrosBoundary(
    _ seeded: SeededDatabase, warmup: Int, iterations: Int
  ) throws -> ExperimentResult {
    let baselineSQL = MirroredQueries.all.first { $0.name == "macros_daily_30" }!.sql

    // Boundary = start of the 30-day window in UTC text. On a UTC host (the
    // recorded environment) the boundary equals the localtime boundary; the
    // parity gate proves the row set matches on this data regardless.
    let formatter = utcFormatter()
    let boundary = formatter.string(from: Date().addingTimeInterval(-29 * 86400))

    let alternativeSQL = """
      SELECT date(ch.cooked_at, 'localtime') AS day,
             SUM(
               (l.calories / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
               * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
             ) AS total_cal,
             SUM(
               (l.protein / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
               * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
             ) AS total_pro,
             SUM(
               (l.carbs / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
               * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
             ) AS total_carb,
             SUM(
               (l.fat / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
               * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
             ) AS total_fat
      FROM cooking_history ch
      JOIN recipes r ON r.id = ch.recipe_id
      JOIN cooking_history_nutrition_snapshots s
        ON s.history_id = ch.id AND s.snapshot_version = 1
      JOIN cooking_history_nutrition_lines l ON l.history_id = ch.id
      WHERE ch.cooked_at >= ?
        AND datetime(ch.cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
      GROUP BY day
      ORDER BY day ASC
      """

    return try seeded.dbQueue.read { db in
      let baselineRows = try rows(db: db, sql: baselineSQL, arguments: ["-29 days"])
      let altRows = try rows(db: db, sql: alternativeSQL, arguments: [boundary, "-29 days"])
      let baselineTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try rows(db: db, sql: baselineSQL, arguments: ["-29 days"])
      }
      let altTiming = try timeRepeated(warmup: warmup, iterations: iterations) {
        _ = try rows(db: db, sql: alternativeSQL, arguments: [boundary, "-29 days"])
      }
      let baselinePlan = try Metrics.explainQueryPlan(db: db, sql: baselineSQL, arguments: ["-29 days"])
      let altPlan = try Metrics.explainQueryPlan(
        db: db, sql: alternativeSQL, arguments: [boundary, "-29 days"])

      let exact = sha(baselineRows) == sha(altRows)
      return ExperimentResult(
        name: "daily_macros_boundary",
        description:
          "dailyMacroTotals: prefilter cooked_at with a raw string boundary before the localtime comparisons",
        alternativeIndex: nil,
        baselinePlan: baselinePlan,
        alternativePlan: altPlan,
        exactOutputParity: exact,
        nutritionBitParity: exact,
        baselineUs: baselineTiming,
        alternativeUs: altTiming,
        notes:
          "Parity proven on this seeded data at this boundary; a timezone-shifted host must re-run the gate before acting on the result."
      )
    }
  }

  // --- shared row fetch + nutrition bit comparison ---------------------------

  private static func utcFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }

  private static func rows(db: Database, sql: String, arguments: [Any?]) throws
    -> [[QueryValue]]
  {
    let fetched = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
    return fetched.map { row in
      row.map { (_, dbValue) in QueryValue(dbValue: dbValue) }
    }
  }

  /// True when every cell matches bit-for-bit (doubles by bitPattern).
  private static func nutritionBitsEqual(
    _ lhs: [[QueryValue]], _ rhs: [[QueryValue]]
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (lrow, rrow) in zip(lhs, rhs) {
      guard lrow.count == rrow.count else { return false }
      for (l, r) in zip(lrow, rrow) {
        switch (l, r) {
        case (.null, .null):
          continue
        case let (.int(a), .int(b)):
          if a != b { return false }
        case let (.double(a), .double(b)):
          if a.bitPattern != b.bitPattern { return false }
        case let (.string(a), .string(b)):
          if a != b { return false }
        default:
          return false
        }
      }
    }
    return true
  }
}

/// One SQLite cell in canonical form (doubles keep raw bits).
enum QueryValue {
  case null
  case int(Int64)
  case double(Double)
  case string(String)

  init(dbValue: DatabaseValue) {
    if dbValue.isNull {
      self = .null
      return
    }
    if let v = Int64.fromDatabaseValue(dbValue) {
      self = .int(v)
    } else if let v = Double.fromDatabaseValue(dbValue) {
      self = .double(v)
    } else if let v = String.fromDatabaseValue(dbValue) {
      self = .string(v)
    } else {
      self = .null
    }
  }

  var canonical: String {
    switch self {
    case .null: return "null"
    case .int(let v): return "i:\(v)"
    case .double(let v): return "d:\(String(v.bitPattern, radix: 16))"
    case .string(let v): return "s:\(v)"
    }
  }
}
