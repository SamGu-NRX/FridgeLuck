import FLFeatureLogic
import GRDB
import XCTest

@testable import FridgeLuck

/// A meal made from a catalog recipe must reach Apple Health with the numbers Progress shows,
/// and cooking it must take its lines out of the Kitchen. Before this, the Health export read
/// the legacy ingredient math for the catalog meal's ingredientless `recipes` row and wrote
/// zeros, and the meal log's consumption read the same empty row and took nothing.
@MainActor
final class CatalogMealEffectsTests: XCTestCase {
  // MARK: - Fixture

  private static let catalogId = "rcp-900101"

  private enum ID {
    static let egg: Int64 = 901
    static let scallion: Int64 = 902
    /// A second app ingredient the green-onion line bridges to.
    static let greenOnionTops: Int64 = 903
    static let butter: Int64 = 904
    static let rice: Int64 = 905
  }

  /// Serves 2. Egg, green onion and rice are required and bridged by legacy id. Saffron is
  /// required with no app ingredient behind it. Butter is optional.
  private static let bundleJSON = """
    {
      "schema": "https://fridgeluck.app/schemas/recipe-bundle-v2.schema.json",
      "bundle_version": 2,
      "generated_at": "2026-10-16T00:00:00Z",
      "cuisines": ["american", "asian", "indian", "italian", "mediterranean", "mexican"],
      "ingredients": [
        {"key": "egg", "fdc_id": null, "legacy_id": 901, "display_name": "Egg",
         "category": "dairy_egg", "per_100g": null, "aliases": []},
        {"key": "green_onion", "fdc_id": null, "legacy_id": 902, "display_name": "Green onion",
         "category": "vegetable", "per_100g": null, "aliases": []},
        {"key": "rice", "fdc_id": null, "legacy_id": 905, "display_name": "Cooked rice",
         "category": "grain", "per_100g": null, "aliases": []},
        {"key": "saffron", "fdc_id": null, "legacy_id": null, "display_name": "Saffron",
         "category": "spice", "per_100g": null, "aliases": []},
        {"key": "butter", "fdc_id": null, "legacy_id": 904, "display_name": "Butter",
         "category": "dairy_egg", "per_100g": null, "aliases": []}
      ],
      "recipes": [
        {
          "catalog_id": "rcp-900101",
          "revision": 3,
          "title": "Saffron Scallion Egg Rice",
          "cuisine": "asian",
          "meal_slots": ["dinner"],
          "collections": ["quick"],
          "minutes": 20,
          "servings": 2,
          "equipment": [],
          "ingredients": [
            {"key": "egg", "quantity": {"kind": "count", "amount": 2, "unit": "large", "grams": 100},
             "required": true, "assumed_staple": false, "note": null},
            {"key": "green_onion", "quantity": {"kind": "grams", "grams": 20},
             "required": true, "assumed_staple": false, "note": null},
            {"key": "rice", "quantity": {"kind": "grams", "grams": 300},
             "required": true, "assumed_staple": false, "note": null},
            {"key": "saffron", "quantity": {"kind": "grams", "grams": 1},
             "required": true, "assumed_staple": false, "note": null},
            {"key": "butter", "quantity": {"kind": "household", "amount": 1, "unit": "tbsp", "grams": 14},
             "required": false, "assumed_staple": false, "note": null}
          ],
          "steps": [
            {"text": "Scramble the eggs.", "uses": [0], "timer_seconds": null, "thermometer": null},
            {"text": "Fold in the rice, saffron and green onion.", "uses": [1, 2, 3],
             "timer_seconds": null, "thermometer": null}
          ],
          "claims": {"vegetarian": true, "vegan": false, "gluten_free": true, "dairy_free": false},
          "nutrition_per_serving": {
            "kcal": 410, "protein_g": 16, "carbs_g": 58, "fat_g": 11, "fiber_g": 2,
            "sodium_mg": 380, "coverage": "estimated", "basis": "test fixture"
          },
          "rights": {"status": "original", "evidence": "test fixture: original wording"},
          "keywords": []
        }
      ]
    }
    """

  private struct Stack {
    let db: DatabaseQueue
    let repository: RecipeRepository
    let inventory: InventoryRepository
    let mealLog: MealLogService
  }

  private func makeStack() throws -> Stack {
    let db = try DatabaseQueue()
    try DatabaseMigrations.migrate(db)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
            (901, 'egg', 155, 13, 1.1, 11),
            (902, 'scallion', 32, 1.8, 7, 0.2),
            (903, 'young_green_onion_tops', 27, 1.6, 5.7, 0.3),
            (904, 'butter', 717, 0.9, 0.1, 81),
            (905, 'cooked_rice', 130, 2.7, 28, 0.3);
          """)
      let bundle = try RecipeBundleV2.decode(from: Data(Self.bundleJSON.utf8))
      try RecipeBundleV2Loader.apply(bundle: bundle, marker: "catalog-meal-effects-tests", db: db)
      // The hydration bridge resolves green_onion by legacy id only here. Shipped keys such as
      // green_onion also bridge to USDA rows (PR #212), so add the second row the same way.
      try db.execute(
        sql: """
          INSERT INTO recipes_catalog_ingredient_bridge (ingredient_key, ingredient_id, resolved_by)
          VALUES ('green_onion', 903, 'fdc_id')
          """)
    }
    let nutrition = NutritionService(db: db)
    let personalization = PersonalizationService(db: db)
    let repository = RecipeRepository(
      db: db,
      nutritionService: nutrition,
      healthScoringService: HealthScoringService(nutritionService: nutrition, db: db),
      personalizationService: personalization)
    let inventory = InventoryRepository(db: db)
    let mealLog = MealLogService(
      db: db, recipeRepository: repository, personalizationService: personalization,
      inventoryRepository: inventory, imageStorageService: ImageStorageService())
    return Stack(db: db, repository: repository, inventory: inventory, mealLog: mealLog)
  }

  /// The recipe the cook guide hands the celebration for a catalog recipe: no persisted id.
  private let cookedRecipe = Recipe(
    id: nil, title: "Saffron Scallion Egg Rice", timeMinutes: 20, servings: 2, instructions: "",
    tags: 0, source: .bundled)

  @discardableResult
  private func addLot(
    _ stack: Stack, _ ingredientId: Int64, grams: Double, expiresInDays: Int = 7
  ) throws -> Int64 {
    try stack.inventory.addLot(
      ingredientId: ingredientId, quantityGrams: grams, location: .fridge, confidenceScore: 1,
      source: .manual, expiresAt: Date().addingTimeInterval(Double(expiresInDays) * 86_400))
  }

  private func remaining(_ stack: Stack, lot: Int64) throws -> Double {
    try stack.db.read {
      try Double.fetchOne(
        $0, sql: "SELECT remaining_grams FROM inventory_lots WHERE id = ?", arguments: [lot]) ?? -1
    }
  }

  private func lotCount(_ stack: Stack) throws -> Int {
    try stack.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM inventory_lots") ?? 0 }
  }

  /// The call `CookingCelebrationView` makes when a catalog cook finishes.
  private func logCookFromHome(_ stack: Stack, servings: Int) throws -> MealLogService.Outcome {
    try stack.mealLog.logMeal(
      recipe: cookedRecipe,
      rating: nil,
      capturedImage: nil,
      servingsConsumed: servings,
      swaps: [],
      sourceRefPrefix: "cooking_celebration",
      catalogId: Self.catalogId,
      catalogRevision: 3)
  }

  /// The call `ReverseScanMealView.logMeal` makes for a catalog recipe chosen in the picker.
  private func logPickFromMealPhoto(
    _ stack: Stack, servings: Int, portion: MealPortionSize
  ) throws -> (pick: MealLogPick, outcome: MealLogService.Outcome) {
    let pick = try stack.repository.catalogMealLogPick(.catalog(id: Self.catalogId, revision: 3))
    let ref = try XCTUnwrap(pick.catalogRef)
    let outcome = try stack.mealLog.logMeal(
      recipe: pick.recipe,
      rating: nil,
      capturedImage: nil,
      servingsConsumed: servings,
      portionMultiplier: portion.multiplier,
      sourceRefPrefix: "reverse_scan",
      catalogId: ref.id,
      catalogRevision: ref.revision)
    return (pick, outcome)
  }

  // MARK: - Kitchen

  func testCookingACatalogRecipeTakesTheScaledGramsFromTheHeldLots() throws {
    let stack = try makeStack()
    let soonEgg = try addLot(stack, ID.egg, grams: 60, expiresInDays: 2)
    let laterEgg = try addLot(stack, ID.egg, grams: 200, expiresInDays: 10)
    let rice = try addLot(stack, ID.rice, grams: 500)
    let scallion = try addLot(stack, ID.scallion, grams: 50)
    let butter = try addLot(stack, ID.butter, grams: 100)

    _ = try logCookFromHome(stack, servings: 3)

    XCTAssertEqual(try remaining(stack, lot: soonEgg), 0, accuracy: 0.001, "the soonest lot goes first")
    XCTAssertEqual(try remaining(stack, lot: laterEgg), 110, accuracy: 0.001, "150 g egg in all")
    XCTAssertEqual(try remaining(stack, lot: rice), 50, accuracy: 0.001, "450 g rice")
    XCTAssertEqual(try remaining(stack, lot: scallion), 20, accuracy: 0.001, "30 g green onion")
    XCTAssertEqual(try remaining(stack, lot: butter), 100, accuracy: 0.001, "optional lines stay")
  }

  func testMultiBridgeLineDrawsFromTheIngredientTheKitchenHolds() throws {
    let stack = try makeStack()
    let tops = try addLot(stack, ID.greenOnionTops, grams: 40)
    let lotsBefore = try lotCount(stack)

    _ = try logCookFromHome(stack, servings: 2)

    XCTAssertEqual(try remaining(stack, lot: tops), 20, accuracy: 0.001)
    XCTAssertEqual(try lotCount(stack), lotsBefore)
  }

  func testShortLineTakesOnlyWhatIsHeld() throws {
    let stack = try makeStack()
    let rice = try addLot(stack, ID.rice, grams: 100)

    _ = try logCookFromHome(stack, servings: 2)

    XCTAssertEqual(try remaining(stack, lot: rice), 0, accuracy: 0.001)
  }

  func testMealPhotoCatalogPickLeavesTheKitchenAlone() throws {
    let stack = try makeStack()
    let egg = try addLot(stack, ID.egg, grams: 200)
    let rice = try addLot(stack, ID.rice, grams: 500)

    let (_, outcome) = try logPickFromMealPhoto(stack, servings: 2, portion: .normal)

    XCTAssertEqual(try remaining(stack, lot: egg), 200, accuracy: 0.001)
    XCTAssertEqual(try remaining(stack, lot: rice), 500, accuracy: 0.001)
    XCTAssertTrue(outcome.inventoryConsumption.isEmpty)
  }

  // MARK: - Apple Health

  func testCatalogPickExportsTheNutritionProgressShows() async throws {
    let stack = try makeStack()
    let health = RecordingAppleHealth()
    let coordinator = MealLogSyncCoordinator(
      appleHealthService: health, nutritionService: NutritionService(db: stack.db))

    let (pick, outcome) = try logPickFromMealPhoto(stack, servings: 2, portion: .large)
    await coordinator.syncLoggedMeal(
      historyId: outcome.historyId, recipeId: outcome.recipeId, mealTitle: pick.recipe.title,
      servingsConsumed: 2, portionMultiplier: MealPortionSize.large.multiplier)

    try assertExportMatchesProgress(stack, health: health, historyId: outcome.historyId, factor: 2 * 1.4)
  }

  func testCatalogCookFromHomeExportsTheNutritionProgressShows() async throws {
    let stack = try makeStack()
    let health = RecordingAppleHealth()
    let coordinator = MealLogSyncCoordinator(
      appleHealthService: health, nutritionService: NutritionService(db: stack.db))

    let outcome = try logCookFromHome(stack, servings: 3)
    await coordinator.syncLoggedMeal(
      historyId: outcome.historyId, recipeId: outcome.recipeId, mealTitle: cookedRecipe.title,
      servingsConsumed: 3, swaps: [])

    try assertExportMatchesProgress(stack, health: health, historyId: outcome.historyId, factor: 3)
  }

  private func assertExportMatchesProgress(
    _ stack: Stack, health: RecordingAppleHealth, historyId: Int64, factor: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let record = try XCTUnwrap(health.records.first, "the meal was written", file: file, line: line)
    XCTAssertEqual(health.records.count, 1, file: file, line: line)
    let progress = try XCTUnwrap(
      try UserDataRepository(db: stack.db).cookingJournal().first { $0.id == historyId },
      file: file, line: line
    ).macrosConsumed

    XCTAssertGreaterThan(record.calories, 0, file: file, line: line)
    XCTAssertEqual(record.calories, progress.calories, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(record.proteinGrams, progress.protein, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(record.carbsGrams, progress.carbs, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(record.fatGrams, progress.fat, accuracy: 0.001, file: file, line: line)
    // Progress shows no fiber or sodium; they come from the same per-serving snapshot.
    XCTAssertEqual(record.calories, 410 * factor, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(record.fiberGrams, 2 * factor, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(record.sodiumMilligrams, 380 * factor, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(record.sugarGrams, 0, "the snapshot has no sugar to report", file: file, line: line)
  }

  // MARK: - Meal screen breakdown

  func testMealScreenBreakdownListsACatalogPicksWeighedRequiredLines() throws {
    let stack = try makeStack()
    let pick = try stack.repository.catalogMealLogPick(.catalog(id: Self.catalogId, revision: 3))
    let content = MealBreakdownContent.make(
      recipe: pick.recipe, loadedIngredients: nil, servingsConsumed: 1, portionMultiplier: 1.4)
    guard case .ingredients = content else {
      return XCTFail("expected ingredient rows, got \(content)")
    }
  }
}

/// Authorized Apple Health that keeps what it was asked to write.
private final class RecordingAppleHealth: AppleHealthServicing, @unchecked Sendable {
  private let lock = NSLock()
  private var written: [AppleHealthMealRecord] = []

  var records: [AppleHealthMealRecord] { lock.withLock { written } }

  func authorizationStatus() -> PermissionStatus { .authorized }
  func authorizationRequestStatus() async -> AppleHealthAuthorizationRequestStatus { .unnecessary }
  func writeMeal(_ record: AppleHealthMealRecord) async throws {
    lock.withLock { written.append(record) }
  }
  func fetchNutritionTotals(in interval: DateInterval) async throws -> AppleHealthNutritionTotals? {
    nil
  }
  func fetchDailyNutritionTotals(lastDays: Int, endingOn endDate: Date) async throws
    -> [AppleHealthNutritionDay]
  {
    []
  }
}
