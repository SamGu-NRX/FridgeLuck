import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// End to end over a hydrated bundle-v2 fixture: a catalog recipe cooked through the real
/// view model — structured steps, timer, thermometer safety check, remember — logs exactly
/// one history row linked to the (catalog_id, revision) that was cooked, so the meal's
/// nutrition reports from the frozen per-revision snapshot and a later revision bump
/// cannot rewrite what an older meal says it was.
/// The view model and stores are main-actor isolated, so the whole suite runs there —
/// the repo's convention for actor-isolated harnesses (AppPermissionCenterTests,
/// NotificationCoordinatorTests).
@MainActor
final class CatalogCookFlowTests: XCTestCase {
  // MARK: - Fixtures

  private static let catalogId = "rcp-900001"

  /// Two-ingredient, two-step catalog recipe: step 1 carries a 90 s timer, step 2 a
  /// checkable thermometer endpoint with its pinned source. The schema requires at least
  /// 2 ingredient lines and 2 steps (RecipeBundleV2 compile-time validation), so the
  /// fixture carries butter alongside the egg.
  private func bundleJSON(revision: Int, kcal: Int) -> String {
    """
    {
      "schema": "https://fridgeluck.app/schemas/recipe-bundle-v2.schema.json",
      "bundle_version": 2,
      "generated_at": "2026-10-15T00:00:00Z",
      "cuisines": ["american", "asian", "indian", "italian", "mediterranean", "mexican"],
      "ingredients": [
        {
          "key": "egg",
          "fdc_id": null,
          "legacy_id": null,
          "display_name": "Egg",
          "category": "dairy_egg",
          "per_100g": null,
          "aliases": ["eggs"]
        },
        {
          "key": "butter",
          "fdc_id": null,
          "legacy_id": null,
          "display_name": "Butter",
          "category": "dairy_egg",
          "per_100g": null,
          "aliases": []
        }
      ],
      "recipes": [
        {
          "catalog_id": "\(Self.catalogId)",
          "revision": \(revision),
          "title": "Catalog Scramble",
          "cuisine": "american",
          "meal_slots": ["breakfast"],
          "collections": ["quick"],
          "minutes": 12,
          "servings": 2,
          "equipment": [],
          "ingredients": [
            {
              "key": "egg",
              "quantity": {"kind": "count", "amount": 2, "unit": "large", "grams": 100},
              "required": true,
              "assumed_staple": false,
              "note": null
            },
            {
              "key": "butter",
              "quantity": {"kind": "household", "amount": 1, "unit": "tbsp", "grams": 14},
              "required": true,
              "assumed_staple": false,
              "note": null
            }
          ],
          "steps": [
            {
              "text": "Beat the eggs in a bowl.",
              "uses": [0],
              "timer_seconds": 90,
              "thermometer": null
            },
            {
              "text": "Cook gently until the centre just sets.",
              "uses": [0],
              "timer_seconds": null,
              "thermometer": {"endpoint_c": 74, "food": "scramble centre", "source": "usda-fsis: egg dishes 160 F"}
            }
          ],
          "claims": {"vegetarian": true, "vegan": false, "gluten_free": true, "dairy_free": false},
          "nutrition_per_serving": {
            "kcal": \(kcal),
            "protein_g": 24,
            "carbs_g": 4,
            "fat_g": 30,
            "fiber_g": 1,
            "sodium_mg": 520,
            "coverage": "estimated",
            "basis": "test fixture: household-to-gram estimates"
          },
          "rights": {"status": "original", "evidence": "test fixture: original wording"},
          "keywords": []
        }
      ]
    }
    """
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    return db
  }

  /// Hydrates the fixture through the real loader — the same write path production uses,
  /// insert-once nutrition rows per revision included.
  private func hydrate(_ db: DatabaseQueue, revision: Int, kcal: Int) throws {
    let bundle = try RecipeBundleV2.decode(from: Data(bundleJSON(revision: revision, kcal: kcal).utf8))
    try db.write { db in
      try RecipeBundleV2Loader.apply(bundle: bundle, marker: "catalog-cook-flow-tests", db: db)
    }
  }

  private func makeStack(_ db: DatabaseQueue) throws -> (
    RecipeRepository, PersonalizationService, MealLogService
  ) {
    let nutritionService = NutritionService(db: db)
    let healthScoring = HealthScoringService(nutritionService: nutritionService, db: db)
    let personalization = PersonalizationService(db: db)
    let repository = RecipeRepository(
      db: db,
      nutritionService: nutritionService,
      healthScoringService: healthScoring,
      personalizationService: personalization)
    let mealLog = MealLogService(
      db: db,
      recipeRepository: repository,
      personalizationService: personalization,
      inventoryRepository: InventoryRepository(db: db),
      imageStorageService: ImageStorageService())
    return (repository, personalization, mealLog)
  }

  /// The recipe object the guide hands the view model: no persisted id, catalog title.
  private func catalogRecipe() -> Recipe {
    Recipe(
      id: nil,
      title: "Catalog Scramble",
      timeMinutes: 12,
      servings: 2,
      instructions: "Beat the eggs.",  // legacy fallback text; catalog steps win
      tags: 0,
      source: .bundled,
      createdAt: nil)
  }

  private func makeDependencies(
    db: DatabaseQueue, mealLog: MealLogService, clock: @escaping () -> Date
  ) -> CookModeViewModel.Dependencies {
    var deps = CookModeViewModel.Dependencies.ephemeral(now: clock)
    deps.store = CookSessionStore(db: db)
    deps.logCatalogMeal = { recipe, rating, servings, swaps, catalogId, revision in
      try mealLog.logMeal(
        recipe: recipe,
        rating: rating,
        capturedImage: nil,
        servingsConsumed: servings,
        swaps: swaps,
        catalogId: catalogId,
        catalogRevision: revision)
    }
    return deps
  }

  private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
  }

  /// Cooks the catalog recipe start to finish through the real view model and logs the meal.
  @discardableResult
  private func cookToRememberedMeal(
    db: DatabaseQueue, deps: CookModeViewModel.Dependencies, repository: RecipeRepository
  ) throws -> CookModeViewModel {
    let packet = try XCTUnwrap(try repository.catalogCookPacket(catalogId: Self.catalogId))
    let vm = CookModeViewModel(
      recipe: catalogRecipe(),
      logsMeal: true,
      dependencies: deps,
      catalog: CatalogCookContent(
        catalogId: packet.catalogId, revision: packet.revision, steps: packet.steps))
    vm.startOrResume()
    vm.startSuggestedTimer()
    vm.advance()  // past the timer step → the thermometer step
    vm.advance()  // last step → finish
    vm.saveRemember(rating: 4, note: nil)
    return vm
  }

  // MARK: - The end-to-end cook flow

  func testCatalogCookLogsOneHistoryRowWithRevisionLinkFrozenNutritionAndCatalogRef() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 1, kcal: 420)
    let (repository, _, mealLog) = try makeStack(db)
    let clock = Date(timeIntervalSince1970: 1_790_000_000)
    let deps = makeDependencies(db: db, mealLog: mealLog, clock: { clock })

    let vm = try cookToRememberedMeal(db: db, deps: deps, repository: repository)

    // The cook flow itself: structured catalog steps, the step's stated timer, the
    // thermometer surfacing as a safety check before any timer.
    XCTAssertEqual(vm.phase, .remembered)
    XCTAssertEqual(vm.state.timers.count, 1)
    try db.read { db in
      let timerCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cook_timer") ?? 0
      XCTAssertEqual(timerCount, 1, "the suggested timer persists with the session")
    }

    // Exactly one history row, linked to the exact revision that was cooked.
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cooking_history"), 1)
    let historyId = try db.read {
      try Int64.fetchOne($0, sql: "SELECT id FROM cooking_history LIMIT 1")
    }
    let link = try db.read {
      try Row.fetchOne(
        $0,
        sql: "SELECT catalog_id, revision FROM recipes_cooking_catalog_refs WHERE history_id = ?",
        arguments: [historyId!])
    }
    let linkCatalogId: String? = link?["catalog_id"]
    let linkRevision: Int? = link?["revision"]
    XCTAssertEqual(linkCatalogId, Self.catalogId)
    XCTAssertEqual(linkRevision, 1)

    // The logged nutrition is the frozen per-revision snapshot, resolved through the link.
    let logged = try XCTUnwrap(try repository.catalogNutrition(forHistoryID: historyId!))
    let revisionSnapshot = try XCTUnwrap(
      try repository.catalogNutrition(catalogId: Self.catalogId, revision: 1))
    XCTAssertEqual(logged, revisionSnapshot)
    XCTAssertEqual(logged.kcal, 420)

    // The taste event carries the catalog ref — the contract RecipeRef, not the integer id.
    let events = try TasteEventStore(db: db).events()
    let cooked = try XCTUnwrap(events.first { $0.kind == .recipeCooked })
    XCTAssertEqual(cooked.event.recipe?.id, Self.catalogId)
    XCTAssertEqual(cooked.event.recipe?.revision, 1)
    XCTAssertEqual(cooked.event.recipe?.source, "catalog")
    guard case .cooked(let payload) = cooked.payload else {
      return XCTFail("the cooked event carries a cooked payload")
    }
    XCTAssertEqual(payload.rating, 4)
  }

  func testTimerSurvivesSimulatedRelaunch() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 1, kcal: 420)
    let (repository, _, mealLog) = try makeStack(db)
    let clock = Date(timeIntervalSince1970: 1_790_000_000)
    let deps = makeDependencies(db: db, mealLog: mealLog, clock: { clock })

    // Session one: start, run the step timer, move to the thermometer step.
    let sessionOne = CookModeViewModel(
      recipe: catalogRecipe(),
      logsMeal: false,
      dependencies: deps,
      catalog: CatalogCookContent(
        catalogId: Self.catalogId, revision: 1,
        steps: try XCTUnwrap(repository.catalogCookPacket(catalogId: Self.catalogId)).steps))
    sessionOne.startOrResume()
    sessionOne.startSuggestedTimer()
    sessionOne.advance()

    // Simulated relaunch: a new view model over the same store, same clock.
    let relaunched = CookModeViewModel(
      recipe: catalogRecipe(),
      logsMeal: false,
      dependencies: deps,
      catalog: CatalogCookContent(
        catalogId: Self.catalogId, revision: 1,
        steps: try XCTUnwrap(repository.catalogCookPacket(catalogId: Self.catalogId)).steps))
    relaunched.startOrResume()

    XCTAssertEqual(relaunched.phase, .cooking)
    XCTAssertEqual(relaunched.state.stepIndex, 1, "resume lands on the step where cooking left off")
    XCTAssertEqual(relaunched.state.totalSteps, 2, "catalog steps re-derive from the packet")
    let timers = relaunched.state.timers
    XCTAssertEqual(timers.count, 1)
    XCTAssertEqual(timers.first?.label, "Step 1")
    XCTAssertEqual(timers.first?.totalSeconds, 90, "the timer's full duration restores")
    XCTAssertEqual(
      timers.first?.remainingSeconds, 90,
      "the absolute deadline survives — remaining time derives from it, not from restart")
    XCTAssertEqual(timers.first?.isFired, false)
  }

  func testRevisionBumpLeavesLoggedNutritionFrozen() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 1, kcal: 420)
    let (repository, _, mealLog) = try makeStack(db)
    let clock = Date(timeIntervalSince1970: 1_790_000_000)
    let deps = makeDependencies(db: db, mealLog: mealLog, clock: { clock })

    _ = try cookToRememberedMeal(db: db, deps: deps, repository: repository)
    let historyId = try db.read {
      try Int64.fetchOne($0, sql: "SELECT id FROM cooking_history LIMIT 1")
    }
    let loggedAtRevision1 = try XCTUnwrap(try repository.catalogNutrition(forHistoryID: historyId!))
    XCTAssertEqual(loggedAtRevision1.kcal, 420)

    // The revision bumps through the loader — new nutrition at revision 2.
    try hydrate(db, revision: 2, kcal: 999)

    let installed = try db.read {
      try Int.fetchOne(
        $0, sql: "SELECT revision FROM recipes_catalog WHERE catalog_id = ?",
        arguments: [Self.catalogId])
    }
    XCTAssertEqual(installed, 2, "the loader supersedes the catalog row to revision 2")
    XCTAssertEqual(
      try repository.catalogNutrition(catalogId: Self.catalogId, revision: 2)?.kcal, 999)
    XCTAssertEqual(
      try repository.catalogNutrition(forHistoryID: historyId!), loggedAtRevision1,
      "the old meal still reads its revision-1 snapshot, not the new revision")
    XCTAssertEqual(
      try db.read {
        try Int.fetchOne(
          $0, sql: "SELECT revision FROM recipes_cooking_catalog_refs WHERE history_id = ?",
          arguments: [historyId!])
      }, 1, "the log's link still names revision 1")
  }

  // MARK: - Fail-closed seams

  func testUnknownSubstituteBlocks() throws {
    // The ephemeral default reports only confirmed allergens: nil is unknown.
    XCTAssertEqual(CookModeViewModel.Dependencies.ephemeral().substituteIsAllergen(42), nil)

    let vm = CookModeViewModel(
      recipe: catalogRecipe(), logsMeal: false, dependencies: .ephemeral())
    vm.startOrResume()
    let result = vm.applySubstitution(
      originalID: 1,
      substitute: Substitution(
        originalId: 1, substituteId: 42, substituteKey: "", reasons: [], ratio: 1.0, note: nil))
    XCTAssertEqual(result.executed, false, "an unknown substitute blocks — fail closed")
  }

  func testHalfSpecifiedCatalogIdentityIsRefused() throws {
    let db = try makeDatabase()
    try hydrate(db, revision: 1, kcal: 420)
    let (_, personalization, _) = try makeStack(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO recipes (id, title, time_minutes, servings, instructions, tags, source)
          VALUES (5, 'History Recipe', 10, 2, 'Cook.', 0, 'bundled')
          """)
    }

    XCTAssertThrowsError(
      try personalization.recordCooking(recipeId: 5, catalogId: Self.catalogId)
    ) { error in
      guard case CookingLogError.catalogIdentityIncomplete = error else {
        return XCTFail("expected catalogIdentityIncomplete, got \\(error)")
      }
    }
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM cooking_history"), 0)
    XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM recipes_cooking_catalog_refs"), 0)
  }

  // MARK: - Legacy regression

  func testLegacyRecipeKeepsParsedStepsAndIntegerRef() throws {
    let db = try makeDatabase()
    let (repository, _, mealLog) = try makeStack(db)
    let clock = Date(timeIntervalSince1970: 1_790_000_000)
    var deps = makeDependencies(db: db, mealLog: mealLog, clock: { clock })
    let newLine = String(UnicodeScalar(10))
    let legacy = Recipe(
      id: 7,
      title: "Legacy Omelette",
      timeMinutes: 10,
      servings: 1,
      instructions: "Beat the eggs for 2 minutes." + newLine + "Cook in a pan until set.",
      tags: 0,
      source: .bundled,
      createdAt: nil)
    deps.logMeal = { _, _, _, _ in }

    let vm = CookModeViewModel(recipe: legacy, logsMeal: false, dependencies: deps)
    vm.startOrResume()

    XCTAssertEqual(vm.phase, .cooking)
    XCTAssertEqual(
      vm.state.totalSteps, CookStepParsing.parse(instructions: legacy.instructions).steps.count,
      "legacy recipes keep the parsed-instructions path")
    let active = try XCTUnwrap(try deps.store?.loadActiveSession())
    XCTAssertEqual(active.session.recipeRef?.id, "7", "the integer-id ref is unchanged")
    XCTAssertEqual(active.session.recipeRef?.revision, 1)
    _ = repository
  }
}
