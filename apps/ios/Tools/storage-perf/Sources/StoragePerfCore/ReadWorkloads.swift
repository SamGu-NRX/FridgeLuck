import Foundation
import GRDB

// MARK: - Real repository reads
//
// Every timed workload calls a REAL production repository function against the
// seeded database (same functions the app ships). Plans are captured for the
// same SQL text; MirrorSQLTests pins each mirror to the production source it
// mirrors (whitespace-normalized fragment match), so plans cannot drift from
// the queries that are actually timed.

struct PlanRow: Equatable {
  var selectid: Int
  var order: Int
  var from: Int
  var detail: String
}

struct ReadWorkload {
  var name: String
  /// Iterations override (nil = run default). Heavy scans get fewer.
  var iterations: Int?
  var run: (DatabaseQueue) throws -> Void
}

enum RepositoryReads {
  /// Per-database workload set. Ingredient ids for point reads are fixed
  /// catalog ids (every seeded database has 280 ingredients), so no run-time
  /// state leaks in. The list is built by appending (a typed local) — a single
  /// giant array literal of closures does not type-check in reasonable time.
  static func workloads(db: DatabaseQueue) -> [ReadWorkload] {
    let inventory = InventoryRepository(db: db)
    let userData = UserDataRepository(db: db)

    // Fixed probe inputs (catalog ids exist in every seeded database).
    let probeIngredients: [Int64] = [1, 21, 41, 61, 81, 101, 121, 141, 161, 181, 201, 221]
    var probePreview: [(ingredientId: Int64, grams: Double)] = []
    for index in 0..<10 {
      let id: Int64 = Int64(7 + index * 19)
      let grams: Double = Double(50 + index * 37)
      probePreview.append((ingredientId: id, grams: grams))
    }

    var workloads: [ReadWorkload] = []
    func add(_ name: String, _ iterations: Int? = nil, _ body: @escaping (DatabaseQueue) throws -> Void) {
      workloads.append(ReadWorkload(name: name, iterations: iterations, run: body))
    }

    add("inventory_use_soon") { _ in
      _ = try inventory.useSoonSuggestions()
    }
    add("inventory_active_items", 8) { _ in
      _ = try inventory.fetchAllActiveItems()
    }
    add("inventory_recent_events") { _ in
      _ = try inventory.recentEvents()
    }
    add("inventory_total_remaining") { _ in
      for id in probeIngredients {
        _ = try inventory.totalRemainingGrams(for: id)
      }
    }
    add("inventory_preview_consumption") { _ in
      _ = try inventory.previewConsumption(ingredientGrams: probePreview)
    }
    add("inventory_has_event") { _ in
      _ = try inventory.hasEvent(eventType: .consume, sourceRef: "seed-no-such-ref")
    }
    add("journal_page_200") { _ in
      _ = try userData.cookingJournal(limit: 200)
    }
    add("journal_full", 5) { _ in
      _ = try userData.cookingJournal()
    }
    add("macros_daily_30") { _ in
      _ = try userData.dailyMacroTotals(lastDays: 30)
    }
    add("macros_today") { _ in
      _ = try userData.todayMacros()
    }
    add("meals_by_day_30") { _ in
      _ = try userData.mealsByDay(lastDays: 30)
    }
    return workloads
  }
}

// MARK: - Mirrored production SQL (for EXPLAIN QUERY PLAN)
//
// Each entry: the SQL the timed workload executes (arguments substituted with
// the same shapes the workload passes). `matchFragment` is a distinctive
// substring of the production source text; MirrorSQLTests proves the mirror
// matches the REAL source copied in by Scripts/refresh.sh.

struct MirroredQuery {
  var name: String
  var sql: String
  var arguments: [Any?]
  var sourceFile: String
  var matchFragment: String
}

enum MirroredQueries {
  /// Computed (not a stored `static let`) so Swift 6 strict concurrency is
  /// satisfied without making the argument array Sendable.
  static var all: [MirroredQuery] { [
    MirroredQuery(
      name: "inventory_use_soon",
      sql: """
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
          AND datetime(il.expires_at) >= datetime('now')
          AND datetime(il.expires_at) <= datetime('now', ?)
        GROUP BY il.ingredient_id, i.name
        ORDER BY datetime(earliest_expires_at) ASC, remaining_grams DESC
        LIMIT ?
        """,
      arguments: ["+3 days", 12],
      sourceFile: "InventoryRepository.swift",
      matchFragment: "GROUP BY il.ingredient_id, i.name"),
    MirroredQuery(
      name: "inventory_active_items",
      sql: """
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
          (SELECT source FROM inventory_lots sub
           WHERE sub.ingredient_id = il.ingredient_id
             AND sub.storage_location = il.storage_location
             AND sub.remaining_grams > 0
           ORDER BY sub.acquired_at DESC LIMIT 1) AS most_recent_source
        FROM inventory_lots il
        JOIN ingredients i ON i.id = il.ingredient_id
        WHERE il.remaining_grams > 0
        GROUP BY il.ingredient_id, il.storage_location
        ORDER BY i.name ASC
        """,
      arguments: [],
      sourceFile: "InventoryRepository.swift",
      matchFragment: "(SELECT source FROM inventory_lots sub"),
    MirroredQuery(
      name: "inventory_recent_events",
      sql: """
        SELECT *
        FROM inventory_events
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
      arguments: [50],
      sourceFile: "InventoryRepository.swift",
      matchFragment: "ORDER BY created_at DESC, id DESC"),
    MirroredQuery(
      name: "inventory_total_remaining",
      sql: """
        SELECT COALESCE(SUM(remaining_grams), 0)
        FROM inventory_lots
        WHERE ingredient_id = ? AND remaining_grams > 0
        """,
      arguments: [101],
      sourceFile: "InventoryRepository.swift",
      matchFragment: "SELECT COALESCE(SUM(remaining_grams), 0)"),
    MirroredQuery(
      name: "inventory_preview_consumption",
      sql: """
        SELECT
          i.name AS ingredient_name,
          COALESCE(SUM(il.remaining_grams), 0) AS available_grams
        FROM ingredients i
        LEFT JOIN inventory_lots il
          ON il.ingredient_id = i.id AND il.remaining_grams > 0
        WHERE i.id = ?
        GROUP BY i.id
        """,
      arguments: [101],
      sourceFile: "InventoryRepository.swift",
      matchFragment: "LEFT JOIN inventory_lots il\n          ON il.ingredient_id = i.id AND il.remaining_grams > 0"),
    MirroredQuery(
      name: "inventory_has_event",
      sql: """
        SELECT EXISTS(
          SELECT 1
          FROM inventory_events
          WHERE event_type = ?
            AND source_ref = ?
          LIMIT 1
        )
        """,
      arguments: ["consume", "seed-no-such-ref"],
      sourceFile: "InventoryRepository.swift",
      matchFragment: "WHERE event_type = ?\n          AND source_ref = ?"),
    MirroredQuery(
      name: "journal_page_200",
      sql: """
        SELECT ch.id AS history_id, ch.cooked_at, ch.rating, ch.image_path,
               ch.servings_consumed, ch.portion_multiplier,
               r.id AS recipe_id, r.title, r.time_minutes, r.servings,
               r.instructions, r.tags, r.source, r.created_at
        FROM cooking_history ch
        JOIN recipes r ON r.id = ch.recipe_id
        ORDER BY ch.cooked_at DESC
        LIMIT 200
        """,
      arguments: [],
      sourceFile: "UserDataRepository.swift",
      matchFragment: "FROM cooking_history ch\n          JOIN recipes r ON r.id = ch.recipe_id"),
    MirroredQuery(
      name: "journal_frozen_servings",
      sql: """
        SELECT recipe_servings, snapshot_version
        FROM cooking_history_nutrition_snapshots
        WHERE history_id = ?
        """,
      arguments: [1],
      sourceFile: "NutritionSnapshotService.swift",
      matchFragment: "SELECT recipe_servings, snapshot_version"),
    MirroredQuery(
      name: "journal_consumed_totals",
      sql: """
        SELECT
          COALESCE(SUM(calories / 100.0 * quantity_grams * swap_ratio), 0) AS total_cal,
          COALESCE(SUM(protein / 100.0 * quantity_grams * swap_ratio), 0) AS total_pro,
          COALESCE(SUM(carbs / 100.0 * quantity_grams * swap_ratio), 0) AS total_carb,
          COALESCE(SUM(fat / 100.0 * quantity_grams * swap_ratio), 0) AS total_fat
        FROM cooking_history_nutrition_lines
        WHERE history_id = ?
        """,
      arguments: [1],
      sourceFile: "NutritionSnapshotService.swift",
      matchFragment: "COALESCE(SUM(calories / 100.0 * quantity_grams * swap_ratio), 0) AS total_cal"),
    MirroredQuery(
      name: "macros_daily_30",
      sql: """
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
        WHERE datetime(ch.cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?))
        GROUP BY day
        ORDER BY day ASC
        """,
      arguments: ["-29 days"],
      sourceFile: "UserDataRepository.swift",
      matchFragment: "JOIN cooking_history_nutrition_lines l ON l.history_id = ch.id"),
    MirroredQuery(
      name: "macros_today",
      sql: """
        SELECT
          COALESCE(SUM(
            (l.calories / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
            * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
          ), 0) AS total_cal,
          COALESCE(SUM(
            (l.protein / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
            * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
          ), 0) AS total_pro,
          COALESCE(SUM(
            (l.carbs / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
            * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
          ), 0) AS total_carb,
          COALESCE(SUM(
            (l.fat / 100.0 * l.quantity_grams * l.swap_ratio / s.recipe_servings)
            * COALESCE(ch.servings_consumed, s.recipe_servings) * ch.portion_multiplier
          ), 0) AS total_fat
        FROM cooking_history ch
        JOIN recipes r ON r.id = ch.recipe_id
        JOIN cooking_history_nutrition_snapshots s
          ON s.history_id = ch.id AND s.snapshot_version = 1
        JOIN cooking_history_nutrition_lines l ON l.history_id = ch.id
        WHERE date(ch.cooked_at, 'localtime') = date('now', 'localtime')
        """,
      arguments: [],
      sourceFile: "UserDataRepository.swift",
      matchFragment: "WHERE date(ch.cooked_at, 'localtime') = date('now', 'localtime')"),
    MirroredQuery(
      name: "snapshot_guard",
      sql: """
        SELECT ch.id
        FROM cooking_history ch
        WHERE (datetime(ch.cooked_at, 'localtime') >= datetime(date('now', 'localtime', ?)))
          AND NOT EXISTS (
            SELECT 1 FROM cooking_history_nutrition_snapshots s
            WHERE s.history_id = ch.id AND s.snapshot_version = 1
          )
        LIMIT 1
        """,
      arguments: ["-29 days"],
      sourceFile: "NutritionSnapshotService.swift",
      matchFragment: "AND NOT EXISTS ("),
  ]
  }
}
