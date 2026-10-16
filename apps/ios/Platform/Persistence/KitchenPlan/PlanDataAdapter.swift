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
  /// Reviewed substitution table access (§14): the adapter surfaces reviewed swaps for every
  /// mapped ingredient so the allocator can cover shortfalls with them.
  let substitutionService: SubstitutionService

  init(dbQueue: DatabaseQueue, now: Date = Date(), useSoonHorizonDays: Int = 3) {
    self.dbQueue = dbQueue
    self.now = now
    self.useSoonHorizonDays = useSoonHorizonDays
    self.substitutionService = SubstitutionService(db: dbQueue)
  }

  // MARK: - Snapshot read

  /// One read-only transaction: recipes with their bills (legacy `recipes` rows and catalog
  /// rows merged through the ingredient-identity bridge), stock lots, staples, allergens, and
  /// reviewed substitutions (SPEC.md §7, §11, §14).
  func loadSnapshot() throws -> PlanSheetData {
    try dbQueue.read { db in
      let allergenIDs = try loadAllergenIngredientIDs(db)
      let dietaryRestrictions = try loadDietaryRestrictions(db)
      let lots = try loadLots(db)
      let hasAnyStockLots = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM inventory_lots"
      ).map { $0 > 0 } ?? false

      // Legacy candidates: every `recipes` row with its (deduplicated-by-PK) ingredient bill.
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
      var legacy: [Int64: (title: String, time: Int?, servings: Int, lines: [PlanCandidateLine])] = [:]
      for row in rows {
        let recipeID: Int64 = row["recipe_id"]
        if legacy[recipeID] == nil {
          legacy[recipeID] = (
            title: row["title"], time: row["time_minutes"], servings: row["servings"] ?? 1, []
          )
        }
        let grams: Double = row["quantity_grams"]
        let required: Bool = row["is_required"]
        legacy[recipeID]!.lines.append(
          PlanCandidateLine(
            ingredientID: row["ingredient_id"],
            name: row["ingredient_name"], grams: grams, isRequired: required))
      }
      let legacyCandidates = legacy
        .sorted { $0.key < $1.key }
        .map { id, entry in
          // Catalog rows carry no revision column; revision 1 marks the unversioned baseline.
          PlanCandidate(
            databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1),
            title: entry.title,
            timeMinutes: entry.time, baseServings: max(1, entry.servings), lines: entry.lines)
        }

      // Catalog candidates ride the canonical-key → app-ingredient bridge (PR #151); an
      // unresolved key is unknown quantity, never a name match. A catalog successor of a
      // still-usable legacy recipe yields to it — the recommend path's dedupe policy.
      let catalog = try loadCatalogCandidates(db)
      let eligibleLegacyIDs = Set(
        legacyCandidates
          .filter { candidate in
            !candidate.lines.contains {
              $0.isRequired && allergenIDs.contains($0.ingredientID)
            }
          }
          .map(\.databaseID))
      let dedupedCatalog = catalog.candidates.filter { entry in
        guard let legacyID = entry.legacyRecipeID else { return true }
        return !eligibleLegacyIDs.contains(legacyID)
      }

      let planCandidates = (legacyCandidates + dedupedCatalog.map(\.candidate))
        .sorted { $0.databaseID < $1.databaseID }

      // Staples: always/usually-on-hand tiers make a missing ingredient an assumed staple;
      // `only_if_confirmed` is not an assumption. The catalog bundle's `assumed_staple` flag
      // marks the same household truth for bridged ingredients.
      let stapleTiers: Set<String> = ["always_have", "usually_have"]
      let staples = try Set(
        Row.fetchAll(db, sql: "SELECT ingredient_id, tier FROM pantry_assumptions")
          .compactMap { row -> Int64? in
            let tier: String = row["tier"]
            let id: Int64 = row["ingredient_id"]
            return stapleTiers.contains(tier) ? id : nil
          })
      let allStaples = staples.union(catalog.stapleIngredientIDs)

      let pool = StockPool(
        lots: lots, reservations: try loadReservedGrams(db), now: now,
        useSoonHorizonDays: useSoonHorizonDays)

      // Eaters come from the household health profile; each allergen set is a hard filter.
      let eaters = allergenIDs.isEmpty ? [] : [PlanEater(id: "household", blockedIngredientIDs: allergenIDs)]

      // Reviewed swaps (§14) for every mapped ingredient in any bill, screened for the
      // household's diet — SubstitutionService fails closed on unknown composition. Unmapped
      // sentinel ids have no app identity and are skipped.
      let mappedIDs = Set(
        planCandidates.flatMap { candidate in
          candidate.lines.map(\.ingredientID).filter { $0 > 0 }
        })
      var substitutions: [PlanSubstitution] = []
      // One bridge read on this transaction's handle: the service's own queue
      // read would re-enter the active snapshot read (GRDB fatal), and per-call
      // reads could each see different hydration state.
      let bridged = SubstitutionService.loadBridge(db: db)
      for ingredientID in mappedIDs.sorted() {
        for swap in substitutionService.substitutions(
          for: ingredientID, dietaryRestrictions: dietaryRestrictions, bridged: bridged) {
          guard swap.ratio > 0 else { continue }
          substitutions.append(
            PlanSubstitution(
              originalID: swap.originalId, substituteID: swap.substituteId,
              substituteGramsPerOriginalGram: swap.ratio, note: swap.note, reviewed: true))
        }
      }

      return PlanSheetData(
        candidates: planCandidates, eaters: eaters, substitutions: substitutions,
        stapleIngredientIDs: allStaples, pool: pool, hasAnyStockLots: hasAnyStockLots)
    }
  }

  // MARK: - Catalog candidates

  struct CatalogCandidates {
    var candidates: [(candidate: PlanCandidate, legacyRecipeID: Int64?)]
    /// Bridged app-ingredient ids the bundle marks as household staples.
    var stapleIngredientIDs: Set<Int64>
  }

  /// Catalog recipes joined to their bills and identity bridge. The bridge convention matches
  /// the recommend path: one key resolves to its smallest bridged app-ingredient id. Lines
  /// with an unresolved key keep a stable negative sentinel id and no usable quantity — the
  /// allocator renders `quantity_unknown` attention for them, never a purchase. A resolved
  /// line the bundle flags `assumed_staple` joins the staples set; an unresolved staple line
  /// is dropped outright (households have it; there is no identity to check).
  func loadCatalogCandidates(_ db: Database) throws -> CatalogCandidates {
    let rows = try Row.fetchAll(
      db, sql: """
        SELECT r.catalog_id, r.revision, r.title, r.minutes, r.servings, r.legacy_recipe_id,
               l.ingredient_key, l.quantity_grams,
               l.is_required, l.assumed_staple,
               v.display_name AS vocabulary_name,
               (SELECT b.ingredient_id FROM recipes_catalog_ingredient_bridge b
                 WHERE b.ingredient_key = l.ingredient_key
                 ORDER BY b.ingredient_id LIMIT 1) AS bridged_id
        FROM recipes_catalog r
        JOIN recipes_catalog_lines l ON l.catalog_id = r.catalog_id
        LEFT JOIN recipes_catalog_ingredients v ON v.key = l.ingredient_key
        ORDER BY r.catalog_id ASC, l.position ASC
        """)

    struct Recipe {
      var catalogID: String
      var revision: Int
      var title: String
      var minutes: Int
      var servings: Int
      var legacyRecipeID: Int64?
      var lines: [PlanCandidateLine]
    }
    var ordered: [Recipe] = []
    var byCatalogID: [String: Int] = [:]
    var staples: Set<Int64> = []
    for row in rows {
      let catalogID: String = row["catalog_id"]
      let index: Int
      if let known = byCatalogID[catalogID] {
        index = known
      } else {
        index = ordered.count
        byCatalogID[catalogID] = index
        let legacyRecipeID: Int64? = row["legacy_recipe_id"]
        ordered.append(
          Recipe(
            catalogID: catalogID, revision: row["revision"], title: row["title"],
            minutes: row["minutes"], servings: row["servings"], legacyRecipeID: legacyRecipeID,
            lines: []))
      }

      let assumedStaple: Bool = row["assumed_staple"]
      if let bridgedID: Int64 = row["bridged_id"] {
        if assumedStaple { staples.insert(bridgedID) }
        let grams: Double = row["quantity_grams"] ?? 0
        let name: String = row["vocabulary_name"] ?? catalogID
        ordered[index].lines.append(
          PlanCandidateLine(
            ingredientID: bridgedID, name: name, grams: grams,
            isRequired: row["is_required"] ?? true))
      } else if !assumedStaple {
        // Unresolved key: keep the line visible as unknown-quantity attention under a stable
        // sentinel identity (never collides with real app-ingredient ids, which are positive).
        ordered[index].lines.append(
          PlanCandidateLine(
            ingredientID: Self.sentinelIngredientID(for: row["ingredient_key"] ?? catalogID),
            name: row["vocabulary_name"] ?? catalogID, grams: 0,
            isRequired: row["is_required"] ?? true))
      }
    }

    let candidates = ordered.map { recipe -> (candidate: PlanCandidate, legacyRecipeID: Int64?) in
      (
        PlanCandidate(
          databaseID: Self.catalogDatabaseID(recipe.catalogID),
          ref: RecipeRef(source: .catalog, id: recipe.catalogID, revision: recipe.revision),
          title: recipe.title, timeMinutes: recipe.minutes,
          baseServings: max(1, recipe.servings), lines: recipe.lines),
        recipe.legacyRecipeID
      )
    }
    return CatalogCandidates(candidates: candidates, stapleIngredientIDs: staples)
  }

  /// Catalog recipes need an Int64 identity in the allocator. Legacy recipes own positive ids,
  /// so a catalog recipe takes the negative of its id's digit tail ("rcp-000167" → -167); an
  /// id without a digit tail gets a stable negative hash. Deterministic and disjoint from
  /// legacy identities.
  static func catalogDatabaseID(_ catalogID: String) -> Int64 {
    let digits = catalogID.filter(\.isNumber)
    if let tail = Int64(digits), tail > 0 { return -tail }
    return -Int64(bitPattern: fnv1a64(catalogID) & 0x0000_FFFF_FFFF_FFFF)
  }

  /// Stable negative sentinel id for a line whose canonical key never resolved to an app
  /// ingredient. Two different keys never share a sentinel in practice (48-bit hash space).
  static func sentinelIngredientID(for key: String) -> Int64 {
    -Int64(bitPattern: fnv1a64(key) & 0x0000_FFFF_FFFF_FFFF)
  }

  private static func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100000001b3
    }
    return hash
  }

  /// Grams per ingredient already claimed by stored (non-superseded) plans — the §7 step 1
  /// "already-planned set". A `sufficient` line reserves its full requirement; a `short` line
  /// reserves the covered share (requirement minus shortfall). `assumed_staple` reserves nothing
  /// by definition, and stale/unknown lines reserve nothing: their stock is not confirmed.
  private func loadReservedGrams(_ db: Database) throws -> [Int64: Double] {
    let rows = try Row.fetchAll(
      db, sql: """
        SELECT l.ingredient_id, l.line_state, l.required_quantity, l.short_quantity
        FROM cook_plan_line l
        JOIN cook_plan_dinner d ON d.id = l.dinner_id
        JOIN cook_plan p ON p.id = d.plan_id
        WHERE p.state != 'superseded'
        """)
    var reserved: [Int64: Double] = [:]
    for row in rows {
      let state: String = row["line_state"]
      guard state == "sufficient" || state == "short" else { continue }
      guard let required = try Self.quantity(fromJSON: row["required_quantity"]) else { continue }
      let shortfall = try Self.quantity(fromJSON: row["short_quantity"])?.value ?? 0
      reserved[row["ingredient_id"], default: 0] += max(0, required.value - shortfall)
    }
    return reserved
  }

  private func loadAllergenIngredientIDs(_ db: Database) throws -> Set<Int64> {
    let raw = try String.fetchOne(
      db, sql: "SELECT allergen_ingredient_ids FROM health_profile WHERE id = 1")
    guard let raw, let data = raw.data(using: .utf8),
      let ids = try? JSONDecoder().decode([Int64].self, from: data)
    else { return [] }
    return Set(ids)
  }

  /// Household dietary restrictions (`health_profile.dietary_restrictions`, a JSON string
  /// array) — they screen the reviewed substitution table before a swap is offered.
  private func loadDietaryRestrictions(_ db: Database) throws -> Set<String> {
    let raw = try String.fetchOne(
      db, sql: "SELECT dietary_restrictions FROM health_profile WHERE id = 1")
    guard let raw, let data = raw.data(using: .utf8),
      let names = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return Set(names)
  }

  private func loadLots(_ db: Database) throws -> [PlanLot] {
    // Only lots with remaining stock; expired lots are filtered downstream by StockPool.
    let rows = try Row.fetchAll(
      db, sql: """
        SELECT ingredient_id, remaining_grams, confidence_score, quantity_is_estimate, expires_at
        FROM inventory_lots
        WHERE remaining_grams > 0
        ORDER BY ingredient_id, expires_at IS NULL, expires_at, id
        """)
    return rows.map { row in
      let confidence: Double = row["confidence_score"]
      // The production column is authoritative (v16; written by photo intake, never cleared by
      // confidence). The threshold stays as a display-honesty heuristic for low-confidence rows
      // whose estimate flag is not set — confidence never confirms a quantity.
      let estimateFlag: Bool = row["quantity_is_estimate"]
      return PlanLot(
        ingredientID: row["ingredient_id"], grams: row["remaining_grams"],
        expiresAt: row["expires_at"],
        quantityIsEstimate: estimateFlag || confidence < Self.estimateConfidenceThreshold)
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
          INSERT INTO cook_plan_dinner (id, plan_id, position, recipe_ref, servings, state, cooked_session_id, leftover_of_dinner_id)
          VALUES (?, ?, ?, ?, ?, 'planned', NULL, ?)
          """,
        arguments: [
          dinner.dinnerID, plan.planID, dinner.position,
          String(data: try JSONEncoder().encode(dinner.recipe), encoding: .utf8) ?? "{}",
          dinner.servings,
          dinner.leftoverOfDinnerID,
        ])

      for (index, line) in dinner.lines.enumerated() {
        // Zero-padded suffix: load orders by id, and plain l10 sorts before l2.
        let suffix = index < 1_000 ? String(format: "%03d", index) : "\(index)"
        try db.execute(
          sql: """
            INSERT INTO cook_plan_line
              (id, dinner_id, ingredient_id, name, is_required, required_quantity, line_state, short_quantity, swap)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            "\(dinner.dinnerID)-l\(suffix)", dinner.dinnerID, line.ingredientID, line.name,
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
          SELECT id, position, recipe_ref, servings, leftover_of_dinner_id
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
        // The frozen dinner record omits cook time, but the title joins from the recipe row.
        let title = try String.fetchOne(
          db, sql: "SELECT title FROM recipes WHERE id = ?", arguments: [databaseID]) ?? ""
        dinners.append(
          PlannedDinner(
            position: dinnerRow["position"], dinnerID: dinnerID, recipe: recipe,
            recipeDatabaseID: databaseID, title: title, servings: dinnerRow["servings"],
            timeMinutes: nil, lines: lines,
            leftoverOfDinnerID: dinnerRow["leftover_of_dinner_id"]))
      }

      let fitJSON = try String.fetchOne(
        db, sql: "SELECT fit_summary FROM cook_plan WHERE id = ?", arguments: [planID]) ?? "{}"
      let fitSummary =
        (try? JSONDecoder().decode(PlanFitSummary.self, from: fitJSON.data(using: .utf8) ?? Data()))
        ?? PlanFitSummary(
          sufficientLines: 0, totalLines: 0, swapCount: 0, attention: nil)

      // §7 step 6: the shopping list is derivable from the stored lines — the merged short
      // amounts plus struck-through assumed-staple requirements, per ingredient.
      let mergedRows = try Row.fetchAll(
        db, sql: """
          SELECT l.ingredient_id, l.name, l.line_state, l.required_quantity, l.short_quantity
          FROM cook_plan_line l
          JOIN cook_plan_dinner d ON d.id = l.dinner_id
          WHERE d.plan_id = ? ORDER BY l.ingredient_id
          """, arguments: [planID])
      var merged: [Int64: (grams: Double, stapleGrams: Double, name: String)] = [:]
      for row in mergedRows {
        let state: String = row["line_state"]
        let required = try Self.quantity(fromJSON: row["required_quantity"])
        let short = try Self.quantity(fromJSON: row["short_quantity"])
        let ingredientID: Int64 = row["ingredient_id"]
        let name: String = row["name"]
        // Only short and assumed-staple lines contribute to the list (§7 step 6); sufficient,
        // stale, and unknown-quantity lines add no shortfall, so they add no entry.
        let existing = merged[ingredientID]
        switch state {
        case "short":
          let value = short?.value ?? 0
          guard value > 0 else { continue }
          merged[ingredientID] = (
            grams: (existing?.grams ?? 0) + value, stapleGrams: existing?.stapleGrams ?? 0,
            name: name)
        case "assumed_staple":
          let value = required?.value ?? 0
          guard value > 0 else { continue }
          merged[ingredientID] = (
            grams: (existing?.grams ?? 0) + value,
            stapleGrams: (existing?.stapleGrams ?? 0) + value, name: name)
        default:
          continue
        }
      }
      let shoppingList = merged
        .sorted { $0.key < $1.key }
        .map { ingredientID, entry in
          ShoppingLine(
            ingredientID: ingredientID, name: entry.name,
            amount: PlanQuantity(value: entry.grams),
            assumedStaple: entry.grams > 0 && (entry.grams - entry.stapleGrams) < 1e-6)
        }

      return LeChefPlan(
        planID: planRow["id"], createdAt: planRow["created_at"], dinners: dinners,
        shoppingList: shoppingList, fitSummary: fitSummary)
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
