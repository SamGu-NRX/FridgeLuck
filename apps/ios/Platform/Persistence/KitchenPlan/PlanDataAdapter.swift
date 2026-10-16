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
      // The household is read on the snapshot's own connection: no repository re-entry
      // inside the read.
      let profile = try HouseholdSafetyBoundary.storedScreeningProfile(in: db)
      let boundary = try HouseholdSafetyBoundary.load(profile: profile, in: db)
      let allergenIDs = Set(profile.parsedAllergenIds)
      let dietaryRestrictions = Set(profile.parsedDietaryRestrictions)
      let lots = try loadLots(db)
      let hasAnyStockLots = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM inventory_lots"
      ).map { $0 > 0 } ?? false

      // Legacy candidates: every `recipes` row with its (deduplicated-by-PK) ingredient bill.
      let rows = try Row.fetchAll(
        db, sql: """
          SELECT r.id AS recipe_id, r.title, r.time_minutes, r.servings, r.tags,
                 ri.ingredient_id, i.name AS ingredient_name,
                 ri.is_required, ri.quantity_grams
          FROM recipes r
          JOIN recipe_ingredients ri ON ri.recipe_id = r.id
          JOIN ingredients i ON i.id = ri.ingredient_id
          ORDER BY r.id, ri.ingredient_id
          """)
      var legacy:
        [Int64: (title: String, time: Int?, servings: Int, tags: Int, lines: [PlanCandidateLine])] =
          [:]
      for row in rows {
        let recipeID: Int64 = row["recipe_id"]
        if legacy[recipeID] == nil {
          legacy[recipeID] = (
            title: row["title"], time: row["time_minutes"], servings: row["servings"] ?? 1,
            tags: row["tags"] ?? 0, []
          )
        }
        let grams: Double = row["quantity_grams"]
        let required: Bool = row["is_required"]
        legacy[recipeID]!.lines.append(
          PlanCandidateLine(
            ingredientID: row["ingredient_id"],
            name: row["ingredient_name"], grams: grams, isRequired: required))
      }
      // The legacy pool goes through the household boundary recommendations use. A plan lists
      // only the lines it keeps, so an optional line the household may not have is dropped
      // and the recipe stays without it (the guest planner's contract; recommendations, which
      // show every line, drop such a recipe instead). What remains must pass as a whole.
      let legacyCandidates = legacy
        .sorted { $0.key < $1.key }
        .compactMap { id, entry -> PlanCandidate? in
          let kept = entry.lines.filter { line in
            line.isRequired
              || boundary.legacyRecipeVerdict(ingredientIDs: [line.ingredientID], tags: entry.tags)
                .isAllowed
          }
          guard
            boundary.legacyRecipeVerdict(ingredientIDs: kept.map(\.ingredientID), tags: entry.tags)
              .isAllowed
          else { return nil }
          // Catalog rows carry no revision column; revision 1 marks the unversioned baseline.
          return PlanCandidate(
            databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1),
            title: entry.title,
            timeMinutes: entry.time, baseServings: max(1, entry.servings),
            lines: kept)
        }

      // Catalog candidates ride the canonical-key → app-ingredient bridge (PR #151); an
      // unresolved key is unknown quantity, never a name match. A catalog successor of a
      // still-usable legacy recipe yields to it — the recommend path's dedupe policy.
      let catalog = try loadCatalogCandidates(
        db, household: boundary.household, dietID: boundary.dietID,
        excludedIDs: boundary.excludedIDs, classesByKey: boundary.classesByKey)
      let eligibleLegacyIDs = Set(legacyCandidates.map(\.databaseID))
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
      let tierRows = try Row.fetchAll(db, sql: "SELECT ingredient_id, tier FROM pantry_assumptions")
      let staples = Set(
        tierRows.compactMap { row -> Int64? in
          let tier: String = row["tier"]
          let id: Int64 = row["ingredient_id"]
          return stapleTiers.contains(tier) ? id : nil
        })
      // The household's explicit tier outranks the catalog default: an ingredient the household
      // marked only_if_confirmed is never re-assumed just because a catalog line says otherwise.
      let householdTiered = Set(tierRows.compactMap { row -> Int64? in row["ingredient_id"] })
      let allStaples = staples.union(catalog.stapleIngredientIDs.subtracting(householdTiered))

      let pool = StockPool(
        lots: lots, reservations: try loadReservedGrams(db, boundary: boundary), now: now,
        useSoonHorizonDays: useSoonHorizonDays)

      // Eaters come from the household health profile; each allergen set is a hard filter.
      let eaters = allergenIDs.isEmpty ? [] : [PlanEater(id: "household", blockedIngredientIDs: allergenIDs)]

      // Reviewed swaps (§14) for every mapped ingredient in any bill, screened by the same
      // boundary — unknown composition fails closed, and a substitute that is (or shares a
      // vocabulary key with) a flagged ingredient is never offered. Unmapped sentinel ids
      // have no app identity and are skipped.
      let mappedIDs = Set(
        planCandidates.flatMap { candidate in
          candidate.lines.map(\.ingredientID).filter { $0 > 0 }
        })
      var substitutions: [PlanSubstitution] = []
      for ingredientID in mappedIDs.sorted() {
        for swap in substitutionService.substitutions(
          for: ingredientID, dietaryRestrictions: dietaryRestrictions, screenedBy: boundary) {
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
  func loadCatalogCandidates(
    _ db: Database, household: HouseholdSafetyProfile, dietID: String?,
    excludedIDs: Set<Int64>, classesByKey: [String: [String]]
  ) throws -> CatalogCandidates {
    // Every app-ingredient id each canonical key bridges to. Admission screens a recipe's
    // keys against the whole set, and each line carries its key's set so the allocator's
    // hard filter does too: the LIMIT-1 resolution below decides grams and naming, never
    // safety identity.
    var bridgedIDsByKey: [String: Set<Int64>] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT ingredient_key, ingredient_id FROM recipes_catalog_ingredient_bridge")
    {
      guard let key: String = row["ingredient_key"], let id: Int64 = row["ingredient_id"]
      else { continue }
      bridgedIDsByKey[key, default: []].insert(id)
    }
    let rows = try Row.fetchAll(
      db, sql: """
        SELECT r.catalog_id, r.revision, r.title, r.minutes, r.servings, r.legacy_recipe_id,
               r.claims,
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
      var claimsJSON: String?
      var lines: [PlanCandidateLine]
      var lineKeys: [String]
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
            claimsJSON: row["claims"], lines: [], lineKeys: []))
      }
      ordered[index].lineKeys.append(row["ingredient_key"] ?? "")

      let assumedStaple: Bool = row["assumed_staple"]
      if let bridgedID: Int64 = row["bridged_id"] {
        if assumedStaple { staples.insert(bridgedID) }
        let grams: Double = row["quantity_grams"] ?? 0
        let name: String = row["vocabulary_name"] ?? catalogID
        ordered[index].lines.append(
          PlanCandidateLine(
            ingredientID: bridgedID, name: name, grams: grams,
            isRequired: row["is_required"] ?? true,
            bridgedIngredientIDs: bridgedIDsByKey[row["ingredient_key"] ?? ""] ?? [bridgedID]))
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

    let candidates = ordered.compactMap { recipe -> (candidate: PlanCandidate, legacyRecipeID: Int64?)? in
      // The admission rule recommendations use: a candidate the household may not be
      // offered never reaches the allocator. A line whose key never resolved to
      // vocabulary classes fails closed for any household that restricts something;
      // unresolved lines are unknown composition here, not assumed-safe attention items.
      guard
        HouseholdSafetyProfileResolver.admitsCatalogRecipe(
          household: household, dietID: dietID, lineKeys: recipe.lineKeys,
          claimsJSON: recipe.claimsJSON, classesByKey: classesByKey,
          bridgedIDsByKey: bridgedIDsByKey, excludedIDs: excludedIDs)
      else { return nil }
      return (
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
  /// by definition, and stale/unknown lines reserve nothing: their stock is not confirmed. A
  /// dinner the household may no longer eat (`admittedSavedDinnerIDs`) reserves nothing either.
  private func loadReservedGrams(
    _ db: Database, boundary: HouseholdSafetyBoundary
  ) throws -> [Int64: Double] {
    let rows = try Row.fetchAll(
      db, sql: """
        SELECT l.dinner_id, l.ingredient_id, l.line_state, l.required_quantity, l.short_quantity,
               l.swap
        FROM cook_plan_line l
        JOIN cook_plan_dinner d ON d.id = l.dinner_id
        JOIN cook_plan p ON p.id = d.plan_id
        WHERE p.state != 'superseded'
        """)
    let admitted = try Self.admittedSavedDinnerIDs(
      db, boundary: boundary,
      dinnerSQL: """
        SELECT d.id, d.recipe_ref, d.leftover_of_dinner_id FROM cook_plan_dinner d
        JOIN cook_plan p ON p.id = d.plan_id
        WHERE p.state != 'superseded'
        """,
      arguments: [])
    var reserved: [Int64: Double] = [:]
    for row in rows {
      let dinnerID: String = row["dinner_id"]
      guard admitted.contains(dinnerID) else { continue }
      let state: String = row["line_state"]
      guard state == "sufficient" || state == "short" else { continue }
      guard let required = try Self.quantity(fromJSON: row["required_quantity"]) else { continue }
      let shortfall = try Self.quantity(fromJSON: row["short_quantity"])?.value ?? 0
      // A swap-covered line consumes grams from two ingredients (review finding 5): the
      // original's covered share and the substitute's shortfall cover. Rows saved before the
      // split existed decode as nil and fall back to the legacy full-requirement math.
      let swap = try Self.swap(fromJSON: row["swap"])
      reserved[row["ingredient_id"], default: 0] +=
        swap?.originalGrams ?? max(0, required.value - shortfall)
      if let swap, let substituteGrams = swap.substituteGrams {
        reserved[swap.substituteID, default: 0] += substituteGrams
      }
    }
    return reserved
  }

  /// The saved dinners (selected by `dinnerSQL`, which returns `id`, `recipe_ref` and
  /// `leftover_of_dinner_id`) the
  /// household may still eat under today's profile. A plan is a frozen record, but the
  /// household can add an allergy or change diet after saving it, so every read of a saved
  /// dinner re-screens it with the boundary the snapshot uses:
  /// - a legacy recipe on the dinner's stored lines plus any swapped-in substitutes, with the
  ///   recipe's diet tag;
  /// - a catalog recipe by its bundle lines and claims, plus each swapped-in substitute;
  /// - a ref that resolves to neither, on its stored lines alone with no diet tag, so a
  ///   restricted household refuses what it cannot check;
  /// - a leftover night, which stores no lines of its own, with the dinner it came from.
  private static func admittedSavedDinnerIDs(
    _ db: Database, boundary: HouseholdSafetyBoundary, dinnerSQL: String,
    arguments: StatementArguments
  ) throws -> Set<String> {
    var linesByDinner: [String: [(ingredientID: Int64, substituteID: Int64?)]] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT dinner_id, ingredient_id, swap FROM cook_plan_line") {
      let dinnerID: String = row["dinner_id"]
      let ingredientID: Int64 = row["ingredient_id"]
      linesByDinner[dinnerID, default: []].append(
        (ingredientID, try Self.swap(fromJSON: row["swap"])?.substituteID))
    }

    var admitted = Set<String>()
    var leftoverSource: [String: String] = [:]
    for row in try Row.fetchAll(db, sql: dinnerSQL, arguments: arguments) {
      let dinnerID: String = row["id"]
      if let sourceID: String = row["leftover_of_dinner_id"] {
        leftoverSource[dinnerID] = sourceID
        continue
      }
      let lines = linesByDinner[dinnerID] ?? []
      let substitutes = lines.compactMap { $0.substituteID }
      guard substitutes.allSatisfy({ boundary.ingredientVerdict($0).isAllowed }) else { continue }
      let storedIDs = lines.map { $0.ingredientID }.filter { $0 > 0 }
      let refJSON: String = row["recipe_ref"]
      let ref = try? JSONDecoder().decode(RecipeRef.self, from: Data(refJSON.utf8))

      let passes: Bool
      if let ref, let legacyID = Int64(ref.id), legacyID > 0,
        let tags = try Int.fetchOne(
          db, sql: "SELECT COALESCE(tags, 0) FROM recipes WHERE id = ?", arguments: [legacyID])
      {
        passes = boundary.legacyRecipeVerdict(ingredientIDs: storedIDs, tags: tags).isAllowed
      } else if let ref,
        let claims = try String.fetchOne(
          db, sql: "SELECT claims FROM recipes_catalog WHERE catalog_id = ?", arguments: [ref.id])
      {
        let keys = try String.fetchAll(
          db,
          sql: """
            SELECT COALESCE(ingredient_key, '') FROM recipes_catalog_lines
            WHERE catalog_id = ? ORDER BY position
            """,
          arguments: [ref.id])
        passes = boundary.admitsCatalogRecipe(lineKeys: keys, claimsJSON: claims)
      } else {
        passes = boundary.legacyRecipeVerdict(ingredientIDs: storedIDs, tags: 0).isAllowed
      }
      if passes { admitted.insert(dinnerID) }
    }
    for (leftoverID, sourceID) in leftoverSource where admitted.contains(sourceID) {
      admitted.insert(leftoverID)
    }
    return admitted
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

  /// Reads a saved plan back (round-trip verification and plan-restore flows), keeping only
  /// the dinners the household may still eat under today's profile (`admittedSavedDinnerIDs`).
  /// A dropped dinner also drops out of the derived shopping list; the stored record is not
  /// rewritten, so the dinner returns if the profile changes back. When the household cannot
  /// be read (no `health_profile` table, or a failed read) this throws instead of returning
  /// the plan unscreened, as `loadSnapshot` does; a missing profile row is the unrestricted
  /// default, per `HouseholdSafetyBoundary.loadStored`.
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
      let admitted = try Self.admittedSavedDinnerIDs(
        db, boundary: try HouseholdSafetyBoundary.loadStored(in: db),
        dinnerSQL: """
          SELECT id, recipe_ref, leftover_of_dinner_id FROM cook_plan_dinner WHERE plan_id = ?
          """,
        arguments: [planID])

      var dinners: [PlannedDinner] = []
      for dinnerRow in dinnerRows {
        let dinnerID: String = dinnerRow["id"]
        guard admitted.contains(dinnerID) else { continue }
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
        // RecipeRef.id is the identity string. Legacy refs carry the positive recipes.id; a
        // bundle-catalog ref carries "rcp-…" whose numeric identity is the negative digit tail
        // (same convention the snapshot uses). Reconstructing both keeps replacement and
        // exclusion working after a reload — a catalog dinner that reloads as 0 loses both.
        let databaseID: Int64
        if let legacy = Int64(recipe.id), legacy > 0 {
          databaseID = legacy
        } else {
          databaseID = Self.catalogDatabaseID(recipe.id)
        }
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
          SELECT l.dinner_id, l.ingredient_id, l.name, l.line_state, l.required_quantity,
                 l.short_quantity
          FROM cook_plan_line l
          JOIN cook_plan_dinner d ON d.id = l.dinner_id
          WHERE d.plan_id = ? ORDER BY l.ingredient_id
          """, arguments: [planID])
      var merged: [Int64: (grams: Double, stapleGrams: Double, name: String)] = [:]
      for row in mergedRows {
        let dinnerID: String = row["dinner_id"]
        guard admitted.contains(dinnerID) else { continue }
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
