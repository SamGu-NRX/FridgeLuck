import Foundation
import GRDB

import FLFeatureLogic

/// Reads everything one plan allocation needs in a single database snapshot, and saves computed
/// plans back to the `cook_plan*` tables (SPEC.md §7, §11).
///
/// The live pantry stays owned by the inventory subsystem: this adapter reads `inventory_lots`
/// and never writes it. Recognition confidence does not confirm quantity — low-confidence lots
/// are treated as estimates and surface `needs_reconfirming` on lines they cover.
struct PlanDataAdapter {
  /// Lots recorded below this recognition confidence are quantity estimates (the photo said
  /// "roughly two onions", not "two onions"). Not a safety claim — a display-honesty threshold.
  static let estimateConfidenceThreshold = 0.7

  let dbQueue: DatabaseQueue
  /// Frozen clock for the snapshot: expiry filtering and the use-soon horizon key off this.
  let now: Date
  let useSoonHorizonDays: Int

  init(dbQueue: DatabaseQueue, now: Date = Date(), useSoonHorizonDays: Int = 3) {
    self.dbQueue = dbQueue
    self.now = now
    self.useSoonHorizonDays = useSoonHorizonDays
  }

  // MARK: - Snapshot read

  /// One read-only transaction: recipes with their bills, stock lots, staples, allergens.
  func loadSnapshot() throws -> PlanSheetData {
    try dbQueue.read { db in
      let allergenIDs = try loadAllergenIngredientIDs(db)
      let lots = try loadLots(db)
      let hasAnyStockLots = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM inventory_lots"
      ).map { $0 > 0 } ?? false

      // Candidates: every recipe with its (deduplicated-by-PK) ingredient bill.
      let rows = try Row.fetchAll(
        db, sql: """
          SELECT r.id AS recipe_id, r.title, r.time_minutes, r.servings,
                 ri.ingredient_id, i.name AS ingredient_name,
                 ri.is_required, ri.quantity_grams
          FROM recipes r
          JOIN recipe_ingredients ri ON ri.recipe_id = r.id
          JOIN ingredients i ON i.id = ri.ingredient_id
          ORDER BY r.id, ri.ingredient_id
          """)
      var candidates: [Int64: (title: String, time: Int?, servings: Int, lines: [PlanCandidateLine])] = [:]
      for row in rows {
        let recipeID: Int64 = row["recipe_id"]
        if candidates[recipeID] == nil {
          candidates[recipeID] = (
            title: row["title"], time: row["time_minutes"], servings: row["servings"] ?? 1, []
          )
        }
        let grams: Double = row["quantity_grams"]
        let required: Bool = row["is_required"]
        candidates[recipeID]!.lines.append(
          PlanCandidateLine(
            ingredientID: row["ingredient_id"],
            name: row["ingredient_name"], grams: grams, isRequired: required))
      }
      let planCandidates = candidates
        .sorted { $0.key < $1.key }
        .map { id, entry in
          // Catalog rows carry no revision column; revision 1 marks the unversioned baseline.
          PlanCandidate(
            databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1),
            title: entry.title,
            timeMinutes: entry.time, baseServings: max(1, entry.servings), lines: entry.lines)
        }

      // Staples: always/usually-on-hand tiers make a missing ingredient an assumed staple;
      // `only_if_confirmed` is not an assumption.
      let stapleTiers: Set<String> = ["always_have", "usually_have"]
      let staples = try Set(
        Row.fetchAll(db, sql: "SELECT ingredient_id, tier FROM pantry_assumptions")
          .compactMap { row -> Int64? in
            let tier: String = row["tier"]
            let id: Int64 = row["ingredient_id"]
            return stapleTiers.contains(tier) ? id : nil
          })

      let pool = StockPool(
        lots: lots, now: now, useSoonHorizonDays: useSoonHorizonDays)

      // Eaters come from the household health profile; each allergen set is a hard filter.
      let eaters = allergenIDs.isEmpty ? [] : [PlanEater(id: "household", blockedIngredientIDs: allergenIDs)]

      return PlanSheetData(
        candidates: planCandidates, eaters: eaters, substitutions: [],
        stapleIngredientIDs: staples, pool: pool, hasAnyStockLots: hasAnyStockLots)
    }
  }

  private func loadAllergenIngredientIDs(_ db: Database) throws -> Set<Int64> {
    let raw = try String.fetchOne(
      db, sql: "SELECT allergen_ingredient_ids FROM health_profile WHERE id = 1")
    guard let raw, let data = raw.data(using: .utf8),
      let ids = try? JSONDecoder().decode([Int64].self, from: data)
    else { return [] }
    return Set(ids)
  }

  private func loadLots(_ db: Database) throws -> [PlanLot] {
    // Only lots with remaining stock; expired lots are filtered downstream by StockPool.
    let rows = try Row.fetchAll(
      db, sql: """
        SELECT ingredient_id, remaining_grams, confidence_score, expires_at
        FROM inventory_lots
        WHERE remaining_grams > 0
        ORDER BY ingredient_id, expires_at IS NULL, expires_at, id
        """)
    return rows.map { row in
      let confidence: Double = row["confidence_score"]
      return PlanLot(
        ingredientID: row["ingredient_id"], grams: row["remaining_grams"],
        expiresAt: row["expires_at"],
        quantityIsEstimate: confidence < Self.estimateConfidenceThreshold)
    }
  }

  // MARK: - Plan persistence

  /// Writes a computed plan as a frozen decision record. Idempotent per plan ID: an existing
  /// record is replaced wholesale.
  func save(_ plan: LeChefPlan) throws {
    try dbQueue.write { db in
      try Self.save(plan, in: db)
    }
  }

  /// Transaction body, also used by callers that already hold a write transaction.
  static func save(_ plan: LeChefPlan, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM cook_plan WHERE id = ?", arguments: [plan.planID])
    try db.execute(
      sql: """
        INSERT INTO cook_plan (id, created_at, horizon_dinners, state, fit_summary)
        VALUES (?, ?, ?, 'draft', ?)
        """,
      arguments: [
        plan.planID, plan.createdAt, plan.dinners.count,
        String(data: try JSONEncoder().encode(plan.fitSummary), encoding: .utf8) ?? "{}",
      ])

    for dinner in plan.dinners {
      try db.execute(
        sql: """
          INSERT INTO cook_plan_dinner (id, plan_id, position, recipe_ref, servings, state, cooked_session_id)
          VALUES (?, ?, ?, ?, ?, 'planned', NULL)
          """,
        arguments: [
          dinner.dinnerID, plan.planID, dinner.position,
          String(data: try JSONEncoder().encode(dinner.recipe), encoding: .utf8) ?? "{}",
          dinner.servings,
        ])

      for (index, line) in dinner.lines.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO cook_plan_line
              (id, dinner_id, ingredient_id, name, is_required, required_quantity, line_state, short_quantity, swap)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            "\(dinner.dinnerID)-l\(index)", dinner.dinnerID, line.ingredientID, line.name,
            line.isRequired,
            try Self.quantityJSON(line.required), Self.stateString(line.lineState),
            try Self.quantityJSON(line.short),
            try Self.swapJSON(line.swap),
          ])
      }
    }
  }

  /// Reads a saved plan back (round-trip verification and plan-restore flows).
  func load(planID: String) throws -> LeChefPlan? {
    try dbQueue.read { db in
      guard let planRow = try Row.fetchOne(
        db, sql: "SELECT id, created_at, horizon_dinners FROM cook_plan WHERE id = ?",
        arguments: [planID])
      else { return nil }

      let dinnerRows = try Row.fetchAll(
        db, sql: """
          SELECT id, position, recipe_ref, servings
          FROM cook_plan_dinner WHERE plan_id = ? ORDER BY position
          """, arguments: [planID])

      var dinners: [PlannedDinner] = []
      for dinnerRow in dinnerRows {
        let dinnerID: String = dinnerRow["id"]
        let lineRows = try Row.fetchAll(
          db, sql: """
            SELECT ingredient_id, name, is_required, required_quantity, line_state, short_quantity, swap
            FROM cook_plan_line WHERE dinner_id = ? ORDER BY id
            """, arguments: [dinnerID])
        let lines = try lineRows.map { row -> PlanLine in
          let requiredJSON: String? = row["required_quantity"]
          let shortJSON: String? = row["short_quantity"]
          let swapJSON: String? = row["swap"]
          let stateRaw: String = row["line_state"]
          return PlanLine(
            ingredientID: row["ingredient_id"], name: row["name"],
            isRequired: row["is_required"],
            required: try Self.quantity(fromJSON: requiredJSON),
            lineState: Self.lineState(fromString: stateRaw),
            short: try Self.quantity(fromJSON: shortJSON),
            swap: try Self.swap(fromJSON: swapJSON))
        }
        let recipeData = (dinnerRow["recipe_ref"] as String).data(using: .utf8) ?? Data()
        let recipe =
          (try? JSONDecoder().decode(RecipeRef.self, from: recipeData))
          ?? RecipeRef(source: .catalog, id: "0", revision: 1)
        // RecipeRef.id is the identity string; the numeric recipes.id rides in it for catalog rows.
        let databaseID = Int64(recipe.id) ?? 0
        // The frozen dinner record intentionally omits cook time; it lives on the recipe row.
        dinners.append(
          PlannedDinner(
            position: dinnerRow["position"], dinnerID: dinnerID, recipe: recipe,
            recipeDatabaseID: databaseID, title: "", servings: dinnerRow["servings"],
            timeMinutes: nil, lines: lines))
      }

      let fitJSON = try String.fetchOne(
        db, sql: "SELECT fit_summary FROM cook_plan WHERE id = ?", arguments: [planID]) ?? "{}"
      let fitSummary =
        (try? JSONDecoder().decode(PlanFitSummary.self, from: fitJSON.data(using: .utf8) ?? Data()))
        ?? PlanFitSummary(
          sufficientLines: 0, totalLines: 0, swapCount: 0, attention: nil)

      return LeChefPlan(
        planID: planRow["id"], createdAt: planRow["created_at"], dinners: dinners,
        shoppingList: [], fitSummary: fitSummary)
    }
  }

  // MARK: - JSON column codecs

  private static func quantityJSON(_ quantity: PlanQuantity?) throws -> String? {
    guard let quantity else { return nil }
    return String(data: try JSONEncoder().encode(quantity), encoding: .utf8)
  }

  private static func quantity(fromJSON json: String?) throws -> PlanQuantity? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try JSONDecoder().decode(PlanQuantity.self, from: data)
  }

  private static func swapJSON(_ swap: PlanSwap?) throws -> String? {
    guard let swap else { return nil }
    return String(data: try JSONEncoder().encode(swap), encoding: .utf8)
  }

  private static func swap(fromJSON json: String?) throws -> PlanSwap? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try JSONDecoder().decode(PlanSwap.self, from: data)
  }

  private static func stateString(_ state: PlanLineState) -> String {
    switch state {
    case .sufficient: return "sufficient"
    case .short: return "short"
    case .quantityUnknown: return "quantity_unknown"
    case .assumedStaple: return "assumed_staple"
    case .needsReconfirming: return "needs_reconfirming"
    }
  }

  private static func lineState(fromString raw: String) -> PlanLineState {
    switch raw {
    case "short": return .short
    case "quantity_unknown": return .quantityUnknown
    case "assumed_staple": return .assumedStaple
    case "needs_reconfirming": return .needsReconfirming
    default: return .sufficient
    }
  }
}
