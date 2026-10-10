import Foundation
import GRDB

// MARK: - Workload profiles
//
// Household activity is modeled per active day: lots acquired, events logged,
// meals cooked (each with a frozen v20 nutrition snapshot), and confidence
// signals recorded. Profiles differ in how long the household has used the
// app; the scale factor multiplies the SAME daily activity (a bigger household
// / heavier user), so month=fresh install, year=settled user, five_year=the
// long-lived case the task is measuring.

public enum WorkloadProfile: String, CaseIterable {
  case month
  case year
  case fiveYear = "five_year"

  var days: Int {
    switch self {
    case .month: return 30
    case .year: return 365
    case .fiveYear: return 1825
    }
  }

  public var label: String { rawValue }
}

public let workloadScales: [Int] = [1, 2, 4, 8, 16]

/// Fixed calendar anchor: 2026-10-10 12:00:00 UTC (the pinned run date, so a
/// rerun of the pinned seed reproduces the pinned data regardless of clock).
let workloadAnchorEpoch: Double = 1781112000  // 2026-10-10T12:00:00Z

// Catalog sizing at 1x: matches the order of magnitude of the bundled catalog
// (not its exact content — no bundled data is copied).
let catalogIngredientCount = 280
let catalogRecipeCount = 120

// MARK: - Seeded database

struct SeededDatabase {
  let path: String
  let dbQueue: DatabaseQueue
  let counts: StateCounts
  let fileSizeBytes: Int64
  let walSizeBytes: Int64
  let seedDurationSeconds: Double
}

struct StateCounts: Equatable {
  var inventoryEvents: Int
  var inventoryLots: Int
  var meals: Int
  var swaps: Int
  var signals: Int
  var snapshots: Int
  var snapshotLines: Int
  var inventoryItems: Int
  var ingredients: Int
  var recipes: Int
  var recipeIngredients: Int
}

// MARK: - Seeder

enum WorkloadSeeder {
  /// Creates a seeded database through the REAL migrations at the pinned head.
  ///
  /// - deterministic: identical (seed, profile, scale) always yields the same
  ///   rows, counts, and state.
  static func makeSeeded(
    profile: WorkloadProfile, scale: Int, seed: UInt64, directory: String,
    name: String
  ) throws -> SeededDatabase {
    precondition(workloadScales.contains(scale))
    let fileManager = FileManager.default
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = directory + "/" + name + ".sqlite"
    try? fileManager.removeItem(atPath: path)
    for suffix in ["-wal", "-shm"] {
      try? fileManager.removeItem(atPath: path + suffix)
    }

    let clock = ContinuousClock()
    let seedStart = clock.now
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true  // matches AppDatabase.setup()
    let dbQueue = try DatabaseQueue(path: path, configuration: configuration)
    try DatabaseMigrations.migrate(dbQueue)  // REAL production migrations, pinned head

    let streamSeed =
      seed ^ fnv1a("\(profile.label)_x\(scale)")
    var rng = SplitMix64(seed: streamSeed)

    let catalog = try seedCatalog(dbQueue: dbQueue, rng: &rng)
    let counts = try seedActivity(
      dbQueue: dbQueue, rng: &rng, profile: profile, scale: scale, catalog: catalog)
    let seedDuration = clock.now - seedStart

    return SeededDatabase(
      path: path,
      dbQueue: dbQueue,
      counts: counts,
      fileSizeBytes: fileSize(path),
      walSizeBytes: fileSize(path + "-wal"),
      seedDurationSeconds: Double(seedDuration.components.seconds)
        + Double(seedDuration.components.attoseconds) / 1e18
    )
  }

  static func fileSize(_ path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.size] as? Int64 ?? 0
  }

  // MARK: Catalog

  private struct Catalog {
    struct RecipeRow {
      var id: Int64
      var servings: Int
      var requiredIngredientIds: [Int64]  // ascending original ids == v20 line order
      var requiredQuantities: [Double]
    }

    var ingredientNutrients: [(calories: Double, protein: Double, carbs: Double, fat: Double, fiber: Double, sugar: Double, sodium: Double)] = []
    var ingredientIds: [Int64] = []  // insertion order == v20 line order
    var recipes: [RecipeRow] = []
  }

  private static func seedCatalog(
    dbQueue: DatabaseQueue, rng: inout SplitMix64
  ) throws -> Catalog {
    var catalog = Catalog()
    try dbQueue.write { db in
      // dbQueue.write already wraps the block in a transaction.
      var ingredientIds: [Int64] = []
        for index in 0..<catalogIngredientCount {
          let nutrients = (
            calories: (20 + rng.unit() * 330).rounded(.toNearestOrEven),
            protein: (rng.unit() * 25),
            carbs: (rng.unit() * 70),
            fat: (rng.unit() * 25),
            fiber: (rng.unit() * 8),
            sugar: (rng.unit() * 25),
            sodium: (rng.unit() * 900)
          )
          catalog.ingredientNutrients.append(nutrients)
          try db.execute(
            sql: """
              INSERT INTO ingredients
                (name, calories, protein, carbs, fat, fiber, sugar, sodium,
                 typical_unit, storage_tip, pairs_with, notes,
                 description, category_label, sprite_group, sprite_key)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """,
              arguments: [
                "ingredient_\(String(format: "%03d", index))",
                nutrients.calories, nutrients.protein, nutrients.carbs, nutrients.fat,
                nutrients.fiber, nutrients.sugar, nutrients.sodium,
                "g", "keep cold", nil, nil, "", "produce", "produce",
                "ingredient_\(String(format: "%03d", index))",
              ]
          )
          let id = db.lastInsertedRowID
          ingredientIds.append(id)
          catalog.ingredientIds.append(id)
        }

        for recipeIndex in 0..<catalogRecipeCount {
          let servings = 1 + rng.int(6)
          let timeMinutes = 5 + rng.int(86)
          try db.execute(
            sql: """
              INSERT INTO recipes (title, time_minutes, servings, instructions, tags, source, created_at)
              VALUES (?, ?, ?, ?, ?, 'bundled', ?)
              """,
            arguments: [
              "recipe_\(String(format: "%03d", recipeIndex))",
              timeMinutes, servings,
              "Seed instructions for recipe \(recipeIndex). No user data.",
              0,
              Date(timeIntervalSince1970: workloadAnchorEpoch),
            ]
          )
          let recipeId = db.lastInsertedRowID

          // 6..10 required lines, ascending ingredient id (v20 line order at
          // capture is ascending original ingredient id; required ingredients
          // are inserted in ascending id order here so both orders agree).
          let requiredCount = 6 + rng.int(5)
          var chosen = Set<Int>()
          while chosen.count < requiredCount {
            chosen.insert(rng.int(catalogIngredientCount))
          }
          var requiredIds: [Int64] = []
          var requiredQuantities: [Double] = []
          for index in chosen.sorted() {
            let quantity = (10 + rng.unit() * 390).rounded(.toNearestOrEven)
            let ingredientId = ingredientIds[index]
            try db.execute(
              sql: """
                INSERT INTO recipe_ingredients
                  (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
                VALUES (?, ?, 1, ?, ?)
                """,
              arguments: [recipeId, ingredientId, quantity, "\(Int(quantity)) g"]
            )
            requiredIds.append(ingredientId)
            requiredQuantities.append(quantity)
          }
          // A couple of optional lines exercise is_required = 0 filtering.
          // Indices that collide with a required line are skipped — the
          // (recipe_id, ingredient_id) unique key would reject them.
          let optionalCount = rng.int(2)
          var insertedOptional = 0
          while insertedOptional < optionalCount {
            let index = rng.int(catalogIngredientCount)
            guard !chosen.contains(index) else { continue }
            chosen.insert(index)
            insertedOptional += 1
            try db.execute(
              sql: """
                INSERT INTO recipe_ingredients
                  (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
                VALUES (?, ?, 0, ?, ?)
                """,
              arguments: [
                recipeId, ingredientIds[index],
                (10 + rng.unit() * 100).rounded(.toNearestOrEven), "to taste",
              ]
            )
          }

          catalog.recipes.append(
            Catalog.RecipeRow(
              id: recipeId, servings: servings,
              requiredIngredientIds: requiredIds,
              requiredQuantities: requiredQuantities))
        }
    }
    return catalog
  }

  // MARK: Activity

  private static func seedActivity(
    dbQueue: DatabaseQueue, rng: inout SplitMix64, profile: WorkloadProfile,
    scale: Int, catalog: Catalog
  ) throws -> StateCounts {
    var counts = StateCounts(
      inventoryEvents: 0, inventoryLots: 0, meals: 0, swaps: 0, signals: 0,
      snapshots: 0, snapshotLines: 0, inventoryItems: 0,
      ingredients: catalogIngredientCount, recipes: catalogRecipeCount,
      recipeIngredients: 0)

    let ingredientCount = Int64(catalogIngredientCount)

    try dbQueue.write { db in
      // dbQueue.write already wraps the block in a transaction.
      // Prepared statements — the sweep inserts hundreds of thousands of rows.
      let insertLot = try db.makeStatement(
          sql: """
            INSERT INTO inventory_lots
              (ingredient_id, quantity_grams, remaining_grams, storage_location,
               confidence_score, source, acquired_at, expires_at,
               created_at, updated_at, quantity_is_estimate)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let insertEvent = try db.makeStatement(
          sql: """
            INSERT INTO inventory_events
              (ingredient_id, lot_id, event_type, quantity_delta_grams,
               confidence_score, reason, source_ref, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let insertHistory = try db.makeStatement(
          sql: """
            INSERT INTO cooking_history
              (recipe_id, cooked_at, rating, image_path, servings_consumed,
               portion_multiplier, is_saved_winner)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        let insertSwap = try db.makeStatement(
          sql: """
            INSERT INTO cooking_history_swaps
              (history_id, original_ingredient_id, substitute_ingredient_id, ratio)
            VALUES (?, ?, ?, ?)
            """)
        let insertSignal = try db.makeStatement(
          sql: """
            INSERT INTO confidence_signal_events
              (signal_key, context_key, raw_score, outcome_reward, note, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """)

        // Live lot bookkeeping. `remaining` is updated by += delta in event
        // order, so the recorded event stream reconstructs remaining_grams
        // exactly. Lot ids only ever append, so array indices are stable and
        // the id→index map stays valid without maintenance.
        var liveLots: [(id: Int64, ingredient: Int64, remaining: Double, acquired: Double)] = []
        var lotIndexById: [Int64: Int] = [:]

        let days = profile.days
        for day in 0..<days {
          let dayStart = workloadAnchorEpoch - Double(days - 1 - day) * 86400

          func stamp(_ hour: Double) -> Date {
            Date(timeIntervalSince1970: dayStart + hour * 3600)
          }

          // --- Lots acquired today (2..5 per active day at 1x) ---
          let lotsToday = (2 + rng.int(4)) * scale
          for _ in 0..<lotsToday {
            let ingredientId = catalog.ingredientIds[rng.int(catalogIngredientCount)]
            let quantity = (100 + rng.unit() * 1400).rounded(.toNearestOrEven)
            let location = ["fridge", "pantry", "freezer"][rng.int(3)]
            let confidence = 0.55 + rng.unit() * 0.45
            let source = ["manual", "scan", "reverse_scan", "system"][rng.int(4)]
            let acquiredHour = Double(rng.int(14)) + 7
            let acquired = stamp(acquiredHour)
            let expires = Date(
              timeIntervalSince1970: dayStart + acquiredHour * 3600 + Double(2 + rng.int(20)) * 86400)
            let isEstimate = rng.int(3) == 0

            try insertLot.execute(arguments: [
              ingredientId, quantity, quantity, location, confidence, source,
              acquired, expires, acquired, acquired, isEstimate,
            ])
            let lotId = db.lastInsertedRowID
            try insertEvent.execute(arguments: [
              ingredientId, lotId, "add", quantity, confidence,
              "Seed inventory intake", "seed_\(profile.label)_d\(day)_l\(lotId)",
              acquired,
            ])
            counts.inventoryEvents += 1
            counts.inventoryLots += 1
            lotIndexById[lotId] = liveLots.count
            liveLots.append((lotId, ingredientId, quantity, acquired.timeIntervalSince1970))
          }

          // --- Consume/adjust/discard against lots from the recent window ---
          let recent = Array(liveLots.suffix(40))

          func pickRecentLot() -> Int64? {
            guard !recent.isEmpty else { return nil }
            for _ in 0..<4 {
              let candidate = recent[rng.int(recent.count)]
              return candidate.id
            }
            return nil
          }

          func lotIndex(_ lotId: Int64) -> Int? {
            // O(1) dictionary lookup; the array only appends, so indices held
            // by the map never move.
            lotIndexById[lotId]
          }

          func applyEvent(
            _ type: String, grams: Double, day: Int, lotId: Int64
          ) throws {
            guard let index = lotIndex(lotId) else { return }
            var lot = liveLots[index]
            let updated = lot.remaining + grams
            guard updated >= 0 else { return }
            let at = stamp(Double(rng.int(14)) + 7)
            lot.remaining = updated
            liveLots[index] = lot
            try insertEvent.execute(arguments: [
              lot.ingredient, lot.id, type, grams,
              0.8 + rng.unit() * 0.2, "Seed \(type)",
              "seed_\(profile.label)_d\(day)_e\(counts.inventoryEvents)", at,
            ])
            counts.inventoryEvents += 1
          }

          let consumes = (1 + rng.int(3)) * scale
          for _ in 0..<consumes {
            guard let lotId = pickRecentLot(),
              let index = lotIndex(lotId), liveLots[index].remaining > 0
            else { continue }
            let grams = min(
              liveLots[index].remaining, (10 + rng.unit() * 300).rounded(.toNearestOrEven))
            try applyEvent("consume", grams: -grams, day: day, lotId: lotId)
          }

          let adjusts = rng.int(2) * scale
          for _ in 0..<adjusts {
            guard let lotId = pickRecentLot(), let index = lotIndex(lotId) else { continue }
            let grams = (5 + rng.unit() * 35).rounded(.toNearestOrEven)
            let signed = rng.int(2) == 0 ? grams : -grams
            try applyEvent("adjust", grams: signed, day: day, lotId: lotId)
          }

          let discards = rng.int(2) * scale
          for _ in 0..<discards {
            guard let lotId = pickRecentLot(),
              let index = lotIndex(lotId), liveLots[index].remaining > 0
            else { continue }
            let grams = liveLots[index].remaining * 0.5
            try applyEvent("discard", grams: -grams, day: day, lotId: lotId)
          }

          // --- Meals (2..3 per active day at 1x), each with a frozen v20 snapshot ---
          let mealsToday = (2 + rng.int(2)) * scale
          for _ in 0..<mealsToday {
            let recipe = catalog.recipes[rng.int(catalogRecipeCount)]
            let cookedAt = stamp(Double(rng.int(5)) + 11)
            let servingsConsumed = 1 + rng.int(4)
            let portionMultiplier = [0.7, 1.0, 1.4][rng.int(3)]
            let rating: Int? = rng.int(3) == 0 ? 3 + rng.int(3) : nil
            let savedWinner = rng.int(7) == 0

            try insertHistory.execute(arguments: [
              recipe.id, cookedAt, rating, nil, servingsConsumed,
              portionMultiplier, savedWinner,
            ])
            let historyId = db.lastInsertedRowID
            counts.meals += 1

            try db.execute(
              sql: """
                INSERT INTO cooking_history_nutrition_snapshots
                  (history_id, recipe_servings, snapshot_version, provenance)
                VALUES (?, ?, 1, 'logged_at_capture')
                """,
              arguments: [historyId, recipe.servings]
            )
            counts.snapshots += 1

            // Swap: one in four meals swaps one required ingredient.
            var swappedOriginal: Int64?
            var swapRatio = 1.0
            if rng.int(4) == 0 {
              let lineIndex = rng.int(recipe.requiredIngredientIds.count)
              let original = recipe.requiredIngredientIds[lineIndex]
              // Ids are 1-based rowids; substitute wraps 280 -> 1.
              let substitute = (original % ingredientCount) + 1
              if substitute != original {
                let ratio = [0.5, 0.75, 1.0, 1.25][rng.int(4)]
                try insertSwap.execute(arguments: [historyId, original, substitute, ratio])
                counts.swaps += 1
                swappedOriginal = original
                swapRatio = ratio
              }
            }

            // Lines: required ingredients in ascending original id (v20 capture
            // order); effective nutrients come from the substitute when swapped.
            for (lineIndex, originalId) in recipe.requiredIngredientIds.enumerated() {
              let isSwapped = swappedOriginal == originalId
              // Ids are 1-based rowids; substitute wraps 280 -> 1.
              let effectiveId = isSwapped ? (originalId % ingredientCount) + 1 : originalId
              let n = catalog.ingredientNutrients[Int(effectiveId) - 1]
              try db.execute(
                sql: """
                  INSERT INTO cooking_history_nutrition_lines
                    (history_id, line_index, original_ingredient_id, substitute_ingredient_id,
                     swap_ratio, quantity_grams, calories, protein, carbs, fat, fiber, sugar, sodium)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                  """,
                arguments: [
                  historyId, lineIndex, originalId,
                  isSwapped ? effectiveId : nil,
                  isSwapped ? swapRatio : 1.0,
                  recipe.requiredQuantities[lineIndex],
                  n.calories, n.protein, n.carbs, n.fat, n.fiber, n.sugar, n.sodium,
                ]
              )
              counts.snapshotLines += 1
            }
          }

          // --- Confidence signals (3..5 per active day at 1x) ---
          let signalsToday = (3 + rng.int(3)) * scale
          for _ in 0..<signalsToday {
            try insertSignal.execute(arguments: [
              "signal_\(rng.int(20))", "context_\(rng.int(8))",
              rng.unit(), rng.unit(), nil, stamp(Double(rng.int(16))),
            ])
            counts.signals += 1
          }
        }

        // --- inventory_items aggregate, computed with the same SQL shape the
        // production refreshInventoryItem helper uses ---
        try db.execute(
          sql: """
            INSERT INTO inventory_items
              (ingredient_id, total_remaining_grams, average_confidence_score, last_updated_at)
            SELECT
              ingredient_id,
              SUM(remaining_grams),
              AVG(confidence_score),
              MAX(updated_at)
            FROM inventory_lots
            WHERE remaining_grams > 0
            GROUP BY ingredient_id
            """
        )
        counts.inventoryItems = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM inventory_items") ?? 0
        counts.recipeIngredients = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM recipe_ingredients") ?? 0
    }
    return counts
  }
}

