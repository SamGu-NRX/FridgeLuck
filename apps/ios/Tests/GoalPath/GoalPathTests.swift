import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// One fridge-to-meal-to-taste walk over the real app construction: a fresh on-disk
/// database, shipped resources, and the real `AppDependencies` — no packet-era mocks.
///
/// The steps exercise exactly the paths the overhaul join wired: the scan-review pantry
/// intake, Home's recommendation source (legacy + catalog pools under the rights gate,
/// with the render exposure logged), the cook guide's session construction, a recorded
/// LeChef proposal approved on that session, the meal-log transaction's catalog identity
/// + frozen nutrition + pantry consumption + taste evidence, the taste profile's
/// cook-citing explanation, the LeChef plan sheet through the production adapter, and
/// the community outbox holding a signed-out share.
@MainActor
final class GoalPathTests: XCTestCase {
  // MARK: - Fixtures

  /// The timer_start fixture's recorded instant is 2026-10-15T18:22:31Z; approving ten
  /// seconds later keeps the proposal inside its five-minute TTL.
  private static let approvedProposalNow = Date(timeIntervalSince1970: 1_792_088_561)

  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("LiveProtocol")
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }

  private func fixtureString(_ name: String) throws -> String {
    try String(decoding: Data(contentsOf: fixtureURL(name)), as: UTF8.self)
  }

  private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
  }

  private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
  }

  /// Synchronous read shell: from an async test method the sync GRDB `read` overload must
  /// be chosen from a sync context, or the compiler picks the async one and demands `await`.
  private func readRows<T>(_ db: DatabaseQueue, _ body: (Database) throws -> T) throws -> T {
    try db.read(body)
  }

  // MARK: - Construction

  /// Fresh on-disk database, production migrations, shipped resources warmed through the
  /// production hydration path, and the app's real dependency container.
  private func makeDependencies() async throws -> (AppDependencies, DatabaseQueue) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("goal-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    let dbQueue = try DatabaseQueue(
      path: root.appendingPathComponent("goal-path.sqlite").path, configuration: config)
    try DatabaseMigrations.migrate(dbQueue)

    let appDatabase = AppDatabase(dbQueue: dbQueue)
    try await appDatabase.warmBundledContentIfNeeded()
    return (AppDependencies(appDatabase: appDatabase), dbQueue)
  }

  // MARK: - The goal path

  func testFridgeToMealToTasteGoalPath() async throws {
    let (deps, dbQueue) = try await makeDependencies()

    // ── Step 1: pantry intake through the scan-review resolution path. The 15
    // ingredients with the widest catalog coverage — picked dynamically from the
    // shipped bridge, the way a real kitchen's staples span the catalog.
    struct Coverage { let id: Int64; let recipes: Int }
    let covered: [Coverage] = try readRows(dbQueue) { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT b.ingredient_id AS id, COUNT(DISTINCT l.catalog_id) AS recipes
          FROM recipes_catalog_ingredient_bridge b
          JOIN recipes_catalog_lines l ON l.ingredient_key = b.ingredient_key
          WHERE b.ingredient_id IS NOT NULL
          GROUP BY b.ingredient_id
          ORDER BY recipes DESC, id ASC
          LIMIT 15
          """
      ).map { Coverage(id: $0["id"], recipes: $0["recipes"]) }
    }
    XCTAssertGreaterThanOrEqual(covered.count, 10, "the shipped catalog bridges enough staples")
    let stapleIds = Set(covered.map(\.id))

    // A real restriction screens every later step: recommendations, the plan. Set
    // through the production user-data path. It is a mid-coverage staple — present in
    // the kitchen, but never the only path to a cookable recipe.
    var profile = try deps.userDataRepository.fetchHealthProfile()
    let allergenId = covered[min(covered.count - 1, 5)].id
    profile.allergenIngredientIds = "[\(allergenId)]"
    try deps.userDataRepository.saveHealthProfile(profile)

    let names: [Int64: String] = try readRows(dbQueue) { db in
      var result: [Int64: String] = [:]
      for row in try Row.fetchAll(
        db,
        sql: "SELECT id, name FROM ingredients WHERE id IN (\(stapleIds.map(String.init).joined(separator: ",")))"
      ) {
        result[row["id"]] = row["name"]
      }
      return result
    }
    let detections = stapleIds.map { id in
      Detection(
        ingredientId: id,
        label: names[id] ?? "staple",
        confidence: 0.9,
        source: .vision,
        originalVisionLabel: names[id] ?? "staple")
    }
    _ = try deps.inventoryIntakeService.ingestConfirmedScan(
      detections: detections,
      confirmedIngredientIDs: stapleIds,
      selectedIngredientByDetection: [:],
      sourceRef: "goal-path-scan",
      location: .inferredFromIngredient,
      preserving: [])
    let pannedIds = try readRows(dbQueue) { db in
      try Int64.fetchAll(db, sql: "SELECT DISTINCT ingredient_id FROM inventory_lots")
    }
    XCTAssertEqual(
      Set(pannedIds), stapleIds,
      "the review resolution lands every confirmed staple in the pantry")

    // ── Step 2: Home's recommendation source — the exact two calls the dashboard makes,
    // then the render path that logs the exposure (with the learned residual at its
    // committed default: off, so the rule order passes through unchanged).
    XCTAssertFalse(TasteResidualSettings.isEnabled, "the taste residual keeps its off default")
    let activeLots = try deps.inventoryRepository.fetchAllActiveItems()
    let effectiveIds = RecommendationPolicy.effectiveIngredientIDs(
      from: Set(activeLots.map(\.ingredientId)))
    let currentProfile = try deps.userDataRepository.fetchHealthProfile()
    let exact = try deps.recipeRepository.findMakeable(
      with: effectiveIds, profile: currentProfile, limit: 5)
    let near =
      exact.isEmpty
      ? try deps.recipeRepository.findNearMatch(
        with: effectiveIds, profile: currentProfile, maxMissingRequired: 1, limit: 5)
      : []
    let pool = try deps.tasteResidualRanking.apply(
      to: exact + near,
      surface: TasteSurface.homeTonight,
      shownCount: 4,
      now: Date())
    XCTAssertEqual(
      pool.map(\.id), (exact + near).map(\.id),
      "with the residual off, the render passes the rule order through unchanged")
    XCTAssertFalse(pool.isEmpty, "the pool is cookable from a stocked pantry")
    // The rights gate: no rewritten recipe is installed, so none can reach the pool.
    XCTAssertEqual(
      try count(dbQueue, "SELECT COUNT(*) FROM recipes_catalog WHERE rights_status != 'original'"),
      0, "no rewritten recipe ever reaches the recommendation pool")
    let exactCatalogEntries = pool.filter { $0.catalog != nil && $0.matchTier == .exact }
    XCTAssertFalse(
      exactCatalogEntries.isEmpty,
      "the catalog pool surfaces exact matches over the shipped staples")
    // Allergen-safe: no pool entry requires the screened ingredient.
    for entry in pool {
      if let catalogId = entry.catalog?.ref.id {
        let requiresAllergen: Int = try readRows(dbQueue) { db in
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*)
              FROM recipes_catalog_ingredient_bridge b
              JOIN recipes_catalog_lines l
                ON l.ingredient_key = b.ingredient_key
              WHERE l.catalog_id = ? AND b.ingredient_id = ? AND l.is_required = 1
              """,
            arguments: [catalogId, allergenId]) ?? 0
        }
        XCTAssertEqual(requiresAllergen, 0, "the pool screens allergens out of required lines")
      }
    }

    // The cook target: the top exact catalog entry whose structured steps carry both a
    // stated timer and a thermometer check — the two step features the cook surface shows.
    guard let target = exactCatalogEntries.first(where: { entry in
      guard let packet = try? deps.recipeRepository.catalogCookPacket(
        catalogId: entry.catalog!.ref.id)
      else { return false }
      return packet.steps.contains { $0.timerSeconds != nil }
        && packet.steps.contains { $0.thermometer != nil }
    }) else {
      return XCTFail("no exact catalog match with a timer step and a thermometer check")
    }
    let catalogId = target.catalog!.ref.id
    let revision = target.catalog!.ref.revision
    let packet = try XCTUnwrap(deps.recipeRepository.catalogCookPacket(catalogId: catalogId))

    // ── Step 3: start the cook exactly the way the guide's startOrResumeSession
    // constructs the session — real store, real substitution service, real gate.
    var cookDeps = CookModeViewModel.Dependencies.ephemeral(now: { Self.approvedProposalNow })
    cookDeps.store = CookSessionStore(db: dbQueue)
    cookDeps.substitutionOptions = { [deps] ingredientId in
      deps.substitutionService.substitutions(for: ingredientId)
    }
    cookDeps.substituteIsAllergen = { [deps] id in
      deps.substitutionService.substituteIsAllergen(for: id)
    }
    let session = CookModeViewModel(
      recipe: target.recipe,
      logsMeal: false,
      dependencies: cookDeps,
      catalog: CatalogCookContent(
        catalogId: catalogId, revision: revision, steps: packet.steps))
    session.startOrResume()
    XCTAssertEqual(session.phase, .cooking)
    XCTAssertEqual(
      session.state.totalSteps, packet.steps.count,
      "the session runs the structured catalog steps")
    XCTAssertTrue(
      packet.steps.contains { $0.thermometer != nil },
      "the structured steps carry the checkable thermometer test")
    let sessionTimers = try count(dbQueue, "SELECT COUNT(*) FROM cook_timer")
    session.startSuggestedTimer()
    XCTAssertEqual(
      try count(dbQueue, "SELECT COUNT(*) FROM cook_timer"), sessionTimers + 1,
      "the step's stated timer starts from timer_seconds and persists")
    XCTAssertEqual(
      try count(dbQueue, "SELECT COUNT(*) FROM cook_session WHERE state = 'cooking'"), 1)

    // ── Step 4: approve the recorded timer proposal on that same session — the chat
    // surface's exact call. Approval ten seconds after the fixture's recorded instant.
    let proposal = try XCTUnwrap(
      LiveProposalFrames.proposal(fromEnvelopeJSON: try fixtureData("proposal-timer_start.json")),
      "the recorded fixture decodes into the wire proposal")
    let receipt = session.process(proposal: proposal, decision: .approve, deviceEvents: [])
    XCTAssertEqual(receipt.state, .executed, "the proposal executes inside its TTL")
    XCTAssertEqual(receipt.proposalID, proposal.proposalID)
    XCTAssertEqual(receipt.payloadHash, proposal.payloadHash)
    XCTAssertEqual(
      try count(dbQueue, "SELECT COUNT(*) FROM cook_timer WHERE label = 'Noodles'"), 1,
      "the approved timer_start lands in the session's persisted timers")

    // ── Step 5: finish. The session completes; the celebration logs the meal (the only
    // meal-log writer in the app) with the exact cooked identity.
    while session.phase == .cooking { session.advance() }
    let pantryBefore: Int = try count(
      dbQueue, "SELECT COALESCE(SUM(remaining_grams), 0) FROM inventory_lots")
    let mealOutcome = try deps.mealLogService.logMeal(
      recipe: target.recipe,
      rating: 4,
      capturedImage: nil,
      servingsConsumed: 2,
      swaps: [],
      sourceRefPrefix: "cooking_celebration",
      catalogId: catalogId,
      catalogRevision: revision)
    session.saveRemember(rating: 4, note: nil)
    XCTAssertEqual(session.phase, .remembered)
    XCTAssertGreaterThan(mealOutcome.historyId, 0)

    XCTAssertEqual(try count(dbQueue, "SELECT COUNT(*) FROM cooking_history"), 1)
    let link = try readRows(dbQueue) {
      try Row.fetchOne(
        $0,
        sql: "SELECT catalog_id, revision FROM recipes_cooking_catalog_refs WHERE history_id = ?",
        arguments: [mealOutcome.historyId])
    }
    let linkCatalogId: String? = link?["catalog_id"]
    let linkRevision: Int? = link?["revision"]
    XCTAssertEqual(linkCatalogId, catalogId, "the meal remembers the catalog id cooked")
    XCTAssertEqual(linkRevision, revision, "the meal remembers the revision cooked")

    let logged = try XCTUnwrap(
      deps.recipeRepository.catalogNutrition(forHistoryID: mealOutcome.historyId))
    let frozen = try XCTUnwrap(
      deps.recipeRepository.catalogNutrition(catalogId: catalogId, revision: revision))
    XCTAssertEqual(logged, frozen, "the meal's nutrition reads the frozen revision snapshot")

    let pantryAfter: Int = try count(
      dbQueue, "SELECT COALESCE(SUM(remaining_grams), 0) FROM inventory_lots")
    XCTAssertLessThan(pantryAfter, pantryBefore, "logging the meal consumed pantry stock")

    let events = try TasteEventStore(db: dbQueue).events()
    let cooked = try XCTUnwrap(events.first { $0.kind == .recipeCooked })
    XCTAssertEqual(cooked.event.recipe?.id, catalogId, "the cooked event carries the catalog ref")
    XCTAssertEqual(cooked.event.recipe?.revision, revision)
    XCTAssertEqual(cooked.event.recipe?.source, "catalog")
    guard case .cooked(let cookedPayload) = cooked.payload else {
      return XCTFail("the cooked event carries a cooked payload")
    }
    XCTAssertEqual(cookedPayload.rating, 4, "the rating rides the cook event")
    XCTAssertEqual(
      try count(dbQueue, "SELECT COUNT(*) FROM taste_exposures WHERE surface LIKE 'home.tonight%'"),
      1, "the render logged its exposure")

    // ── Step 6: the rating is already in the cook event. Recomputing the source with
    // the same inputs keeps the rule order (the residual is off), and the profile's
    // learned layer holds the cook's evidence below its render gate.
    let reordered = try deps.tasteResidualRanking.apply(
      to: exact + near,
      surface: TasteSurface.homeTonight,
      shownCount: 4,
      now: Date())
    XCTAssertEqual(
      reordered.map(\.id), pool.map(\.id),
      "with the residual off, a logged cook cannot reorder the rule-ranked pool")
    let profilePage = try await deps.tasteProfileRepository.loadProfile()
    let cookCited = profilePage.hidden.first { $0.denominator >= 1 && $0.numerator >= 1 }
    XCTAssertNotNil(cookCited, "the learned layer holds the cook's evidence below the render gate")
    XCTAssertNil(
      profilePage.statements(layer: .inferred).first,
      "one cook stays below the learned statement's denominator gate")

    // ── Step 7: the LeChef plan sheet through the production adapter — real stock,
    // real catalog + legacy candidates, real allergen screening, real persistence.
    let planVM = deps.makePlanSheetViewModel()
    await planVM.load()
    guard case .ready = planVM.state else {
      return XCTFail("the plan sheet reaches a plan over a stocked kitchen: \(planVM.state)")
    }
    planVM.setDinnerCount(5)
    XCTAssertEqual(planVM.state, .ready)
    let plan = try XCTUnwrap(planVM.plan)
    XCTAssertTrue((5...7).contains(plan.dinners.count), "the weekly horizon allocates 5–7 dinners")
    try PlanDataAdapter(dbQueue: dbQueue).save(plan)
    XCTAssertEqual(try count(dbQueue, "SELECT COUNT(*) FROM cook_plan"), 1)
    XCTAssertEqual(
      try count(dbQueue, "SELECT COUNT(*) FROM cook_plan_dinner"), plan.dinners.count)
    let plannedRefs: [RecipeRef] = try readRows(dbQueue) { db in
      try String.fetchAll(db, sql: "SELECT recipe_ref FROM cook_plan_dinner")
        .compactMap { try? JSONDecoder().decode(RecipeRef.self, from: Data($0.utf8)) }
    }
    XCTAssertEqual(plannedRefs.count, plan.dinners.count)
    for ref in plannedRefs where ref.source == .catalog {
      let usesAllergen: Int = try readRows(dbQueue) { db in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*)
            FROM recipes_catalog_lines l
            JOIN recipes_catalog_ingredient_bridge b ON b.ingredient_key = l.ingredient_key
            WHERE l.catalog_id = ? AND b.ingredient_id = ?
            """,
          arguments: [ref.id, allergenId]) ?? 0
      }
      XCTAssertEqual(usesAllergen, 0, "the plan never assigns an allergen recipe")
    }

    // ── Step 8: a signed-out community share waits in the outbox (local-first, no
    // network). Signed out the 18+ gate holds the share surface; the outbox is the
    // production persistence the write rides once a table is set.
    XCTAssertFalse(deps.communitySessionViewModel.isAdult, "signed out, the 18+ gate holds")
    let shareRequest = CommunityShareCookRequest(
      operationId: UUID().uuidString.lowercased(),
      cook: CommunitySharedCook(
        recipeRef: RecipeRef(source: .catalog, id: catalogId, revision: revision),
        dishName: target.recipe.title,
        servings: 2,
        day: "2026-10-16"))
    let sharePayload = OutboxService.ShareCookOutboxPayload(
      tableId: "goal-path-table", request: shareRequest)
    _ = try deps.communityStore.enqueue(
      .shareCook,
      payload: JSONEncoder().encode(sharePayload),
      recipeId: nil,
      operationId: shareRequest.operationId)
    XCTAssertEqual(
      try deps.communityStore.queuedOutboxCount(), 1, "the share waits in the outbox")
    let outboxState: String? = try readRows(dbQueue) {
      try String.fetchOne($0, sql: "SELECT state FROM community_outbox LIMIT 1")
    }
    let outboxPayload: String? = try readRows(dbQueue) {
      try String.fetchOne($0, sql: "SELECT payload_json FROM community_outbox LIMIT 1")
    }
    XCTAssertEqual(outboxState, "queued")
    XCTAssertTrue(
      (outboxPayload ?? "").contains(catalogId),
      "the queued payload carries the cooked recipe's catalog ref")
  }
}
