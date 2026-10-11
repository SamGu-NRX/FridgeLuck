import Foundation
import GRDB

// MARK: - Historical Nutrition Snapshots
//
// Logged meals must keep the nutrition they had when they were cooked. The
// catalog stays mutable (corrections, refreshes, re-syncs), so history reads
// consume frozen per-meal snapshots instead:
//
// - `cooking_history_nutrition_snapshots` freezes the meal's recipe servings
//   plus an explicit format version and provenance label.
// - `cooking_history_nutrition_lines` freezes one row per required recipe
//   ingredient: the effective ingredient values (substitute applied), the
//   quantity, the swap ratio, and all seven nutrient columns, in a stable
//   line order (ascending original ingredient id at capture time).
//
// Snapshots are values available at capture (or at the v21 upgrade), not
// recovered measurements of the original meal. Later catalog corrections
// cannot rewrite them.
//
// Read paths never fall back to the mutable catalog: a missing or
// future-version snapshot is an error. Per-line rows keep the existing SQL
// `SUM` shapes (journal, day, today) and the Swift fold used for Apple
// Health, so each path preserves its exact floating-point arithmetic.

enum NutritionSnapshot {
  /// Format version written by this app version. Reads require this exact
  /// version, so a future format change fails loudly instead of silently
  /// mixing formats.
  static let currentVersion = 1

  static let snapshotsTable = "cooking_history_nutrition_snapshots"
  static let linesTable = "cooking_history_nutrition_lines"

  /// Captured inside the logging transaction (meals logged on v21+).
  static let provenanceLoggedAtCapture = "logged_at_capture"
  /// Backfilled from the catalog during the v21 upgrade (pre-existing meals).
  static let provenanceUpgradeBackfill = "upgrade_backfill"

  enum SnapshotError: LocalizedError {
    case missingSnapshot(historyId: Int64)
    case unsupportedSnapshotVersion(historyId: Int64, found: Int)
    case unknownRecipe(recipeId: Int64)

    var errorDescription: String? {
      switch self {
      case .missingSnapshot(let historyId):
        return
          "Meal \(historyId) has no current nutrition snapshot. Reporting refuses to fall back to the mutable catalog."
      case .unsupportedSnapshotVersion(let historyId, let found):
        return
          "Meal \(historyId) nutrition snapshot version \(found) is not supported (expected \(currentVersion))."
      case .unknownRecipe(let recipeId):
        return "Cannot snapshot nutrition: recipe \(recipeId) is not in the database."
      }
    }
  }

  /// Frozen recipe servings for a logged meal. Throws when the meal has no
  /// current-version snapshot; reporting must not fall back to the mutable
  /// catalog.
  static func frozenServings(in db: Database, historyId: Int64) throws -> Int {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT recipe_servings, snapshot_version
          FROM \(snapshotsTable)
          WHERE history_id = ?
          """,
        arguments: [historyId]
      )
    else {
      throw SnapshotError.missingSnapshot(historyId: historyId)
    }

    let version: Int = row["snapshot_version"]
    guard version == currentVersion else {
      throw SnapshotError.unsupportedSnapshotVersion(historyId: historyId, found: version)
    }
    return row["recipe_servings"]
  }

  /// Absolute consumed macro totals for a single logged meal, computed with
  /// the journal's original arithmetic: SQL `SUM` over per-line
  /// `nutrient / 100 * grams * ratio`, then a Swift serving factor
  /// (`consumed * portion / max(frozenServings, 1)`), over frozen snapshot
  /// lines instead of the mutable catalog.
  ///
  /// A line whose effective ingredient was missing at backfill time carries
  /// NULL nutrients and contributes nothing, matching the catalog join it
  /// replaced.
  static func consumedTotals(
    in db: Database,
    historyId: Int64,
    storedServingsConsumed: Int?,
    portionMultiplier: Double
  ) throws -> MacroTotals {
    let frozenServings = try frozenServings(in: db, historyId: historyId)

    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COALESCE(SUM(calories / 100.0 * quantity_grams * swap_ratio), 0) AS total_cal,
          COALESCE(SUM(protein / 100.0 * quantity_grams * swap_ratio), 0) AS total_pro,
          COALESCE(SUM(carbs / 100.0 * quantity_grams * swap_ratio), 0) AS total_carb,
          COALESCE(SUM(fat / 100.0 * quantity_grams * swap_ratio), 0) AS total_fat
        FROM \(linesTable)
        WHERE history_id = ?
        """,
      arguments: [historyId]
    )

    guard let row else { return .zero }
    let servingsFactor =
      Double(storedServingsConsumed ?? frozenServings) * portionMultiplier
      / Double(max(frozenServings, 1))
    return MacroTotals(
      calories: (row["total_cal"] as? Double ?? 0) * servingsFactor,
      protein: (row["total_pro"] as? Double ?? 0) * servingsFactor,
      carbs: (row["total_carb"] as? Double ?? 0) * servingsFactor,
      fat: (row["total_fat"] as? Double ?? 0) * servingsFactor
    )
  }

  /// Loud guard for aggregate read paths: every history row visible through
  /// `visibleWhere` must carry a current-version snapshot. The row set is the
  /// same one the aggregate sums, so a missing snapshot surfaces as an error
  /// instead of silently re-deriving nutrition from the mutable catalog.
  static func requireCurrentSnapshots(
    in db: Database,
    visibleWhere: String,
    arguments: StatementArguments = []
  ) throws {
    guard
      let missingId = try Int64.fetchOne(
        db,
        sql: """
          SELECT ch.id
          FROM cooking_history ch
          JOIN recipes r ON r.id = ch.recipe_id
          WHERE \(visibleWhere)
            AND NOT EXISTS (
              SELECT 1 FROM \(snapshotsTable) s
              WHERE s.history_id = ch.id AND s.snapshot_version = \(currentVersion)
            )
          ORDER BY ch.id
          LIMIT 1
          """,
        arguments: arguments
      )
    else { return }

    throw SnapshotError.missingSnapshot(historyId: missingId)
  }
}

/// Writes and reads per-meal nutrition snapshots.
final class NutritionSnapshotService: Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  /// Freezes the nutrition inputs of a logged meal: the recipe's current
  /// serving count, and one line per required ingredient holding the
  /// effective ingredient values (substitute applied), quantity, swap ratio,
  /// and all seven nutrients, ordered by original ingredient id.
  ///
  /// Must run inside the same transaction that wrote the cooking history,
  /// swap, streak, and inventory rows (MealLogService.logMeal), so the
  /// snapshot exists exactly when the meal does.
  func captureSnapshot(in db: Database, historyId: Int64, recipeId: Int64) throws {
    guard
      let servings = try Int.fetchOne(
        db,
        sql: "SELECT servings FROM recipes WHERE id = ?",
        arguments: [recipeId]
      )
    else {
      throw NutritionSnapshot.SnapshotError.unknownRecipe(recipeId: recipeId)
    }

    try db.execute(
      sql: """
        INSERT INTO \(NutritionSnapshot.snapshotsTable) (
          history_id, recipe_servings, snapshot_version, provenance
        )
        VALUES (?, ?, ?, ?)
        """,
      arguments: [
        historyId, servings, NutritionSnapshot.currentVersion,
        NutritionSnapshot.provenanceLoggedAtCapture,
      ]
    )

    // Effective ingredient values: the substitute's row when a swap exists,
    // otherwise the original's. LEFT JOINs keep the capture resilient: a
    // line whose effective ingredient row is unavailable freezes NULL
    // nutrients and contributes nothing to reports, matching the catalog
    // join it replaces.
    let lines = try Row.fetchAll(
      db,
      sql: """
        SELECT ri.ingredient_id, ri.quantity_grams,
               sw.substitute_ingredient_id, sw.ratio,
               i.calories, i.protein, i.carbs, i.fat, i.fiber, i.sugar, i.sodium
        FROM recipe_ingredients ri
        LEFT JOIN cooking_history_swaps sw
          ON sw.history_id = ? AND sw.original_ingredient_id = ri.ingredient_id
        LEFT JOIN ingredients i
          ON i.id = COALESCE(sw.substitute_ingredient_id, ri.ingredient_id)
        WHERE ri.recipe_id = ? AND ri.is_required = 1
        ORDER BY ri.rowid
        """,
      arguments: [historyId, recipeId]
    )

    for (index, line) in lines.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO \(NutritionSnapshot.linesTable) (
            history_id, line_index, original_ingredient_id, substitute_ingredient_id,
            swap_ratio, quantity_grams, calories, protein, carbs, fat, fiber, sugar, sodium
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          historyId,
          index,
          line["ingredient_id"] as Int64,
          line["substitute_ingredient_id"] as Int64?,
          // No swap row means ratio 1.0, same COALESCE the v21 backfill
          // freezes; the LEFT JOIN leaves ratio NULL for unswapped lines.
          line["ratio"] as Double? ?? 1.0,
          line["quantity_grams"] as Double,
          line["calories"] as Double?,
          line["protein"] as Double?,
          line["carbs"] as Double?,
          line["fat"] as Double?,
          line["fiber"] as Double?,
          line["sugar"] as Double?,
          line["sodium"] as Double?,
        ]
      )
    }
  }

  /// Plan-aware capture for meals accepted through a consumption plan
  /// (`MealNutritionSnapshotting` seam, meal-corrections stream). The frozen lines
  /// carry the plan's APPLIED grams — the amounts the user verified and the Kitchen
  /// actually deducted — instead of recipe-reference grams scaled by a swap ratio:
  /// the plan already folded substitution and user edits into `appliedGrams`, so
  /// `swap_ratio` freezes at 1.0 and read arithmetic (`grams × ratio`) reproduces
  /// exactly the accepted state. Swap identity is still preserved in the id columns.
  ///
  /// The same tables, format version, and provenance discipline as the recipe-based
  /// capture; `revision` is accepted for seam symmetry and intentionally not stored —
  /// the snapshot always reflects the latest accepted state, so correcting a meal
  /// re-freezes it under the same `history_id` (the previous rows are removed first;
  /// deleting the history row cascades them).
  func captureSnapshot(
    in db: Database, historyId: Int64, plan: MealConsumptionPlan, revision: Int
  ) throws {
    try db.execute(
      sql: "DELETE FROM \(NutritionSnapshot.linesTable) WHERE history_id = ?",
      arguments: [historyId]
    )
    try db.execute(
      sql: "DELETE FROM \(NutritionSnapshot.snapshotsTable) WHERE history_id = ?",
      arguments: [historyId]
    )

    try db.execute(
      sql: """
        INSERT INTO \(NutritionSnapshot.snapshotsTable) (
          history_id, recipe_servings, snapshot_version, provenance
        )
        VALUES (?, ?, ?, ?)
        """,
      arguments: [
        historyId, plan.recipeServings, NutritionSnapshot.currentVersion,
        NutritionSnapshot.provenanceLoggedAtCapture,
      ]
    )

    for (index, line) in plan.lines.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO \(NutritionSnapshot.linesTable) (
            history_id, line_index, original_ingredient_id, substitute_ingredient_id,
            swap_ratio, quantity_grams, calories, protein, carbs, fat, fiber, sugar, sodium
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          historyId,
          index,
          line.originalIngredientId ?? line.resolvedIngredientId,
          line.originalIngredientId != nil ? line.resolvedIngredientId : nil,
          1.0,
          line.appliedGrams,
          line.nutritionPer100g.calories,
          line.nutritionPer100g.protein,
          line.nutritionPer100g.carbs,
          line.nutritionPer100g.fat,
          line.nutritionPer100g.fiber,
          line.nutritionPer100g.sugar,
          line.nutritionPer100g.sodium,
        ]
      )
    }
  }

  /// Per-serving macros for a logged meal, from its frozen snapshot.
  ///
  /// Mirrors NutritionService.macros(for:swaps:) operation for operation —
  /// Swift accumulation over ordered lines, `factor = grams * ratio / 100`,
  /// division by servings, sodium ×1000 — so Apple Health writes report the
  /// same bits the journal reports, anchored to frozen values.
  func capturedMacros(historyId: Int64) throws -> RecipeMacros {
    try db.read { db in
      let servings = Double(try NutritionSnapshot.frozenServings(in: db, historyId: historyId))

      let lines = try Row.fetchAll(
        db,
        sql: """
          SELECT quantity_grams, swap_ratio, calories, protein, carbs, fat, fiber, sugar, sodium
          FROM \(NutritionSnapshot.linesTable)
          WHERE history_id = ?
          ORDER BY line_index
          """,
        arguments: [historyId]
      )

      var totalCal = 0.0
      var totalPro = 0.0
      var totalCarb = 0.0
      var totalFat = 0.0
      var totalFib = 0.0
      var totalSug = 0.0
      var totalSod = 0.0

      for line in lines {
        // All-or-nothing: a line whose effective ingredient was missing at
        // capture time contributes nothing, like the catalog join it replaced.
        guard
          let cal: Double = line["calories"],
          let pro: Double = line["protein"],
          let carb: Double = line["carbs"],
          let fat: Double = line["fat"],
          let fib: Double = line["fiber"],
          let sug: Double = line["sugar"],
          let sod: Double = line["sodium"]
        else { continue }

        let grams: Double = line["quantity_grams"]
        let ratio: Double = line["swap_ratio"]
        let factor = (grams * ratio) / 100.0

        totalCal += cal * factor
        totalPro += pro * factor
        totalCarb += carb * factor
        totalFat += fat * factor
        totalFib += fib * factor
        totalSug += sug * factor
        totalSod += sod * factor
      }

      return RecipeMacros(
        caloriesPerServing: totalCal / servings,
        proteinPerServing: totalPro / servings,
        carbsPerServing: totalCarb / servings,
        fatPerServing: totalFat / servings,
        fiberPerServing: totalFib / servings,
        sugarPerServing: totalSug / servings,
        sodiumPerServing: (totalSod / servings) * 1000
      )
    }
  }

  // MARK: - Bundled-refresh readiness provider

  /// Shared readiness gate for bundled-data refreshes.
  ///
  /// The bundled-refresh stream (`BundledDataRefresher.HistoricalSnapshotReadiness`
  /// on `obv/fl-next-bundled-refresh`) refuses every refresh until this
  /// provider lands; its `verify: (Database) throws -> Void` shape matches
  /// this method so integration is a one-line wrapper. A refresh may only
  /// adopt new catalog data when history no longer depends on it:
  /// every logged meal has a snapshot header, every header is at the
  /// current snapshot version, and provenance is a known value. Line
  /// contents are deliberately not re-derived from the catalog here —
  /// frozen values are the point.
  func verifyHistoricalSnapshotReadiness(in db: Database) throws {
    let missing = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM cooking_history ch
        LEFT JOIN cooking_history_nutrition_snapshots s
          ON s.history_id = ch.id
        WHERE s.history_id IS NULL
        """)
    guard missing == 0 else {
      throw SnapshotReadinessError.incompleteSnapshots(count: missing ?? -1)
    }

    let stale = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM cooking_history_nutrition_snapshots
        WHERE snapshot_version != \(NutritionSnapshot.currentVersion)
        """)
    guard stale == 0 else {
      throw SnapshotReadinessError.unsupportedVersions(count: stale ?? -1)
    }

    let badProvenance = try Int.fetchOne(
      db,
      sql: """
        SELECT COUNT(*) FROM cooking_history_nutrition_snapshots
        WHERE provenance NOT IN ('logged_at_capture', 'upgrade_backfill')
        """)
    guard badProvenance == 0 else {
      throw SnapshotReadinessError.unknownProvenance(count: badProvenance ?? -1)
    }
  }
}

/// Reasons the bundled-data readiness gate refuses a refresh.
enum SnapshotReadinessError: Error, Equatable {
  case incompleteSnapshots(count: Int)
  case unsupportedVersions(count: Int)
  case unknownProvenance(count: Int)
}
