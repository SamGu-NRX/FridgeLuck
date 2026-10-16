import FLFeatureLogic
import Foundation
import GRDB
import XCTest

@testable import FridgeLuck

@MainActor
final class GuestMealPlanningFlowTests: XCTestCase {
  private let mealDate = Date(timeIntervalSince1970: 2_000_000_000)

  func testRecipeMappingUsesStoredServingsGramsAndOnlyChosenOptionals() throws {
    let stored = recipe()
    let requiredOnly = try XCTUnwrap(GuestMealMapping.recipe(stored, optionalIDs: []).weighed)
    XCTAssertEqual(requiredOnly.recipeID, 10)
    XCTAssertEqual(requiredOnly.baseServings, 2)
    XCTAssertEqual(requiredOnly.ingredients, [.init(ingredientID: 1, grams: 250)])
    let withOptional = try XCTUnwrap(GuestMealMapping.recipe(stored, optionalIDs: [2]).weighed)
    XCTAssertEqual(withOptional.ingredients, [
      .init(ingredientID: 1, grams: 250), .init(ingredientID: 2, grams: 25),
    ])
  }

  func testCatalogLinesWithoutGramsOrKitchenIdentityAreListedNotTotalled() throws {
    let catalog = PlanCandidate(
      databaseID: -167, ref: RecipeRef(source: .catalog, id: "rcp-000167", revision: 1),
      title: "Herb rice", timeMinutes: 20, baseServings: 2,
      lines: [
        .init(ingredientID: 1, name: "Rice", grams: 200, isRequired: true),
        .init(ingredientID: 5, name: "Salt", grams: 0, isRequired: true),
        .init(ingredientID: -9_001, name: "Lovage", grams: 0, isRequired: true),
      ])
    let mapped = GuestMealMapping.recipe(catalog, optionalIDs: [])
    XCTAssertEqual(mapped.weighed?.recipeID, -167)
    XCTAssertEqual(mapped.weighed?.ingredients, [.init(ingredientID: 1, grams: 200)])
    XCTAssertEqual(mapped.uncounted, [
      .init(recipeTitle: "Herb rice", ingredientName: "Salt", reason: .noGrams),
      .init(recipeTitle: "Herb rice", ingredientName: "Lovage", reason: .notTracked),
    ])

    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(.init(
      recipes: [catalog], lots: [lot()], ingredientNames: [1: "Rice"], stapleIngredientIDs: []))
    model.selectRecipe(-167, selected: true)
    XCTAssertEqual(try plan(model).ingredients.map(\.missingGrams), [200])
    XCTAssertEqual(model.uncountedLines.count, 2)
  }

  func testMenuWithOnlyUnweighedLinesSaysSoInsteadOfFailing() throws {
    let unweighed = PlanCandidate(
      databaseID: -3, ref: RecipeRef(source: .catalog, id: "rcp-000003", revision: 1),
      title: "Mystery dish", timeMinutes: 30, baseServings: 2,
      lines: [.init(ingredientID: -77, name: "Mystery root", grams: 0, isRequired: true)])
    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(.init(
      recipes: [unweighed], lots: [], ingredientNames: [:], stapleIngredientIDs: []))
    model.selectRecipe(-3, selected: true)
    guard case .nothingWeighed = model.review else {
      return XCTFail("Expected nothingWeighed, got \(model.review)")
    }
    XCTAssertEqual(model.uncountedLines.map(\.ingredientName), ["Mystery root"])
  }

  func testMissingStaplesSortAfterPurchasesAndStayOffTheBuyList() throws {
    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(.init(
      recipes: [recipe()], lots: [], ingredientNames: [1: "Rice", 2: "Allspice"],
      stapleIngredientIDs: [2]))
    model.selectRecipe(10, selected: true)
    model.selectOptional(2, recipeID: 10, selected: true)
    let current = try plan(model)
    XCTAssertEqual(model.sortedLines(current).map(\.ingredientID), [1, 2])
    XCTAssertEqual(model.purchaseLines(current).map(\.ingredientID), [1])
    XCTAssertEqual(current.shoppingList.map(\.ingredientID), [1, 2])
  }

  func testTwoCatalogLinesBridgedToOneIngredientAddUp() throws {
    let doubled = PlanCandidate(
      databaseID: -4, ref: RecipeRef(source: .catalog, id: "rcp-000004", revision: 1),
      title: "Rice two ways", timeMinutes: 30, baseServings: 2,
      lines: [
        .init(ingredientID: 1, name: "Rice", grams: 100, isRequired: true),
        .init(ingredientID: 1, name: "Rice", grams: 50, isRequired: true),
        .init(ingredientID: 2, name: "Salt", grams: 5, isRequired: false),
        .init(ingredientID: 2, name: "Salt", grams: 5, isRequired: false),
      ])
    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(.init(
      recipes: [doubled], lots: [], ingredientNames: [1: "Rice", 2: "Salt"],
      stapleIngredientIDs: []))
    model.selectRecipe(-4, selected: true)
    XCTAssertEqual(try plan(model).ingredients.map(\.requiredGrams), [150])
    XCTAssertEqual(model.optionalIngredientIDs(of: doubled), [2])
  }

  func testMappingDoesNotConfirmHighConfidenceOrManualLots() throws {
    let stored = lot(grams: 100.5)
    let mapped = try GuestMealMapping.lot(stored, reviewedGrams: nil, name: "Rice")
    XCTAssertEqual(mapped.lotID, 20)
    XCTAssertEqual(mapped.ingredientID, 1)
    XCTAssertEqual(mapped.remainingGrams, 100.5)
    XCTAssertEqual(mapped.expiresAt, stored.expiresAt)
    switch mapped.quantityStatus {
    case .needsConfirmation: break
    case .confirmed: XCTFail("Confidence must not approve the quantity")
    }
    let reviewed = try GuestMealMapping.lot(stored, reviewedGrams: 80.25, name: "Rice")
    XCTAssertEqual(reviewed.remainingGrams, 80.25)
    switch reviewed.quantityStatus {
    case .confirmed: break
    case .needsConfirmation: XCTFail("Explicit host review should count")
    }
  }

  func testMappingRejectsInvalidLotWithNames() throws {
    var badLot = lot()
    badLot.remainingGrams = .infinity
    XCTAssertThrowsError(try GuestMealMapping.lot(badLot, reviewedGrams: nil, name: "Rice")) {
      XCTAssertTrue($0.localizedDescription.contains("Rice, lot 20"))
    }
    let corrected = try GuestMealMapping.lot(badLot, reviewedGrams: 10, name: "Rice")
    XCTAssertEqual(corrected.remainingGrams, 10)
  }

  func testGuestsOptionalsAndRecipeRemovalRecomputeWithoutResettingSelection() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 250)
    model.setGuests(4)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 500)
    model.selectOptional(2, recipeID: 10, selected: true)
    XCTAssertEqual(try plan(model).ingredients.map(\.missingGrams), [500, 50])
    model.selectOptional(2, recipeID: 10, selected: false)
    XCTAssertEqual(try plan(model).ingredients.map(\.missingGrams), [500])
    XCTAssertEqual(model.selectedRecipeIDs, [10])
    model.selectRecipe(10, selected: false)
    guard case .empty = model.review else { return XCTFail("Removing the menu should invite selection") }
  }

  func testConfirmEditAndReconfirmUseCurrentGramsOnly() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 150)
    model.setGrams("60.5", lotID: 20)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 250)
    XCTAssertFalse(model.confirmedLotIDs.contains(20))
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 189.5)
    model.confirmLot(20, confirmed: false)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 250)
  }

  func testEventAtExpiryExcludesConfirmedStockAndEarlierDateRestoresIt() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 150)
    model.setDate(mealDate.addingTimeInterval(3_600))
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 250)
    XCTAssertEqual(try plan(model).ingredients[0].expiresBeforeEventGrams, 100)
    XCTAssertEqual(model.exclusionReason(for: lot()), "Excluded: recorded expiry is at or before the meal.")
    model.setDate(mealDate)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 150)
  }

  func testStockWithoutExpiryCanBeReviewedButMalformedExpiryCannot() throws {
    let model = model()
    var stock = lot()
    stock.expiresAt = nil
    model.replaceSnapshot(.init(recipes: [recipe()], lots: [stock], ingredientNames: [1: "Rice"], stapleIngredientIDs: []))
    model.selectRecipe(10, selected: true)
    XCTAssertTrue(model.canConfirm(stock))
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 150)
    stock.expiresAt = Date(timeIntervalSinceReferenceDate: .infinity)
    model.replaceSnapshot(.init(recipes: [recipe()], lots: [stock], ingredientNames: [1: "Rice"], stapleIngredientIDs: []))
    XCTAssertFalse(model.canConfirm(stock))
    XCTAssertEqual(model.exclusionReason(for: stock), "Excluded: correct the invalid expiry in your fridge, then reload inventory.")
    guard case .invalid(let message) = model.review else { return XCTFail("Malformed expiry must hide totals") }
    XCTAssertTrue(message.contains("Rice, lot 20"))
  }

  func testExactIngredientIDsPreventFormSubstitutionAndSharedStockIsAllocatedOnce() throws {
    let second = recipe(id: 11, grams: 100)
    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(.init(recipes: [recipe(), second], lots: [lot(), lot(id: 21, ingredientID: 3, grams: 1_000)], ingredientNames: [1: "Raw rice", 3: "Cooked rice"], stapleIngredientIDs: []))
    model.selectRecipe(10, selected: true)
    model.selectRecipe(11, selected: true)
    model.confirmLot(20, confirmed: true)
    model.confirmLot(21, confirmed: true)
    XCTAssertEqual(model.relevantLots.compactMap(\.id), [20])
    XCTAssertEqual(try plan(model).ingredients[0].requiredGrams, 350)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 250)
  }

  func testInvalidEditsHideStaleTotalsAndRecoverWithoutLosingMenu() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 250)
    for invalid in ["", "rice", "-1"] {
      model.setGrams(invalid, lotID: 20)
      guard case .invalid(let message) = model.review else { return XCTFail("Invalid grams must hide totals") }
      XCTAssertTrue(message.contains("Rice, lot 20"))
      XCTAssertEqual(model.selectedRecipeIDs, [10])
    }
    model.setGrams("50", lotID: 20)
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 200)
    model.setGuests(0)
    guard case .invalid(let message) = model.review else { return XCTFail("Invalid guests must hide totals") }
    XCTAssertEqual(message, "Enter at least one guest.")
    model.setGuests(2)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 200)
  }

  func testMissingGroceriesSortBeforeCoveredIngredientsAndEmptyShoppingList() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    model.selectOptional(2, recipeID: 10, selected: true)
    model.setGrams("500", lotID: 20)
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(model.sortedLines(try plan(model)).map(\.ingredientID), [2, 1])
    XCTAssertEqual(try plan(model).shoppingList.map(\.ingredientID), [2])
    model.selectOptional(2, recipeID: 10, selected: false)
    XCTAssertEqual(try plan(model).ingredients[0].allocatedGrams, 250)
    XCTAssertTrue(try plan(model).shoppingList.isEmpty)
  }

  func testRefreshClearsApprovalAndLoadFailureCannotExposeStaleTotals() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 150)
    model.loadingFailed()
    model.setGuests(4)
    guard case .invalid = model.review else { return XCTFail("Failed reload must hide stale totals") }
    model.replaceSnapshot(snapshot())
    XCTAssertEqual(model.selectedRecipeIDs, [10])
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 500)
    XCTAssertTrue(model.confirmedLotIDs.isEmpty)
  }

  func testDeletedSelectedRecipeHasRecoveryAndPreservesOtherSelections() throws {
    let model = model()
    model.selectRecipe(10, selected: true)
    model.replaceSnapshot(.init(recipes: [], lots: [], ingredientNames: [:], stapleIngredientIDs: []))
    guard case .invalid(let message) = model.review else { return XCTFail("Deleted recipe must be explicit") }
    XCTAssertTrue(message.contains("no longer available"))
    XCTAssertEqual(model.selectedRecipeIDs, [10])
    model.selectRecipe(10, selected: false)
    guard case .empty = model.review else { return XCTFail("Removing missing recipe should recover") }
  }

  // MARK: - Snapshot over the production schema

  func testSnapshotLoadsCatalogRecipesStaplesAndOnlyTrackedLots() throws {
    let queue = try database()
    try queue.write { db in
      try db.execute(sql: """
        INSERT INTO recipes_catalog
          (catalog_id, revision, title, cuisine, minutes, servings, claims,
           rights_status, rights_evidence, legacy_recipe_id) VALUES
          ('rcp-000101', 1, 'Herb Rice', 'american', 20, 4, '{}', 'original', 'test', NULL);
        INSERT INTO recipes_catalog_lines
          (catalog_id, position, ingredient_key, quantity_kind, quantity_grams,
           quantity_amount, quantity_unit, is_required, assumed_staple) VALUES
          ('rcp-000101', 0, 'rice', 'grams', 400, NULL, NULL, 1, 0),
          ('rcp-000101', 1, 'oil', 'grams', 20, NULL, NULL, 1, 1),
          ('rcp-000101', 2, 'lovage', 'unknown', NULL, NULL, NULL, 1, 0);
        INSERT INTO inventory_lots (ingredient_id, quantity_grams, remaining_grams, confidence_score)
          VALUES (2, 500, 300, 1), (2, 100, 0, 1), (4, 900, 900, 1);
        """)
    }

    let snapshot = try GuestMealSnapshot.load(from: queue, now: mealDate)

    let herbRice = try XCTUnwrap(snapshot.recipes.first { $0.ref.id == "rcp-000101" })
    XCTAssertEqual(herbRice.databaseID, -101)
    XCTAssertEqual(herbRice.baseServings, 4)
    XCTAssertEqual(snapshot.ingredientNames[2], "Rice")
    XCTAssertEqual(snapshot.stapleIngredientIDs, [5])
    // Depleted rice and stock for ingredients no recipe uses are left out.
    XCTAssertEqual(snapshot.lots.map(\.ingredientId), [2])

    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(snapshot)
    model.selectRecipe(-101, selected: true)
    model.setGuests(2)
    XCTAssertEqual(try plan(model).ingredients.map(\.requiredGrams), [200, 10])
    XCTAssertEqual(model.uncountedLines.map(\.reason), [.notTracked])
  }

  func testSnapshotDropsLegacyRecipesThatRequireAHouseholdAllergen() throws {
    let queue = try database()
    try queue.write { db in
      try db.execute(sql: """
        INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
          (1, 'Peanut Stew', 40, 4, 'Simmer.'),
          (2, 'Rice Bowl', 15, 2, 'Steam.');
        INSERT INTO recipe_ingredients
          (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
          (1, 3, 1, 200, '200 g'),
          (2, 2, 1, 300, '300 g'),
          (2, 3, 0, 20, '20 g');
        INSERT OR REPLACE INTO health_profile (id, allergen_ingredient_ids) VALUES (1, '[3]');
        """)
    }

    let snapshot = try GuestMealSnapshot.load(from: queue, now: mealDate)

    XCTAssertNil(snapshot.recipes.first { $0.databaseID == 1 })
    let bowl = try XCTUnwrap(snapshot.recipes.first { $0.databaseID == 2 })
    XCTAssertEqual(bowl.lines.map(\.ingredientID), [2], "a blocked optional is never offered")
  }

  func testSnapshotLeavesOutScrapedRecipesAndSpellsOutLegacyIngredientKeys() throws {
    let queue = try database()
    try queue.write { db in
      try db.execute(sql: """
        INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
          (6, 'red_pepper_flakes', 318, 12, 57, 17);
        INSERT INTO recipes (id, title, time_minutes, servings, instructions) VALUES
          (27, 'Air fryer tuna pasta bake', 40, 2,
           'Source: https://www.bbcgoodfood.com/recipes/air-fryer-tuna-pasta-bake'),
          (2, 'Rice Bowl', 15, 2, '1. Steam the rice.');
        INSERT INTO recipe_ingredients
          (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity) VALUES
          (27, 5, 1, 50, '50 g'),
          (2, 2, 1, 300, '300 g'),
          (2, 6, 0, 2, '2 g');
        """)
    }

    let snapshot = try GuestMealSnapshot.load(from: queue, now: mealDate)

    XCTAssertNil(snapshot.recipes.first { $0.databaseID == 27 }, "a scraped bill is partial")
    let bowl = try XCTUnwrap(snapshot.recipes.first { $0.databaseID == 2 })
    // Rice takes the catalog vocabulary's name; red_pepper_flakes has no vocabulary row.
    XCTAssertEqual(bowl.lines.map(\.name), ["Rice", "Red pepper flakes"])
    XCTAssertEqual(snapshot.ingredientNames, [2: "Rice", 6: "Red pepper flakes"])
  }

  func testReadableKeySpellsOutKeysAndLeavesDisplayNamesAlone() {
    XCTAssertEqual(GuestMealSnapshot.readableKey("red_pepper_flakes"), "Red pepper flakes")
    XCTAssertEqual(GuestMealSnapshot.readableKey("garlic"), "Garlic")
    XCTAssertEqual(GuestMealSnapshot.readableKey("Olive Oil"), "Olive Oil")
    XCTAssertEqual(GuestMealSnapshot.readableKey("Sun_Dried Tomato"), "Sun Dried Tomato")
    XCTAssertEqual(GuestMealSnapshot.readableKey(""), "")
  }

  /// The app's launch hydration (data.json, USDA catalog, recipes-v2.json) on a fresh
  /// database: one hand-written legacy recipe and one catalog recipe, each planned from its
  /// own stored lines and scaled from 2 base servings to 4 guests.
  func testShippedDataPlansALegacyAndACatalogRecipeFromTheirOwnLines() async throws {
    let queue = try DatabaseQueue()
    try DatabaseMigrations.migrate(queue)
    try await AppDatabase(dbQueue: queue).warmBundledContentIfNeeded()

    let snapshot = try GuestMealSnapshot.load(from: queue, now: mealDate)

    let catalogRows = try await queue.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recipes_catalog") ?? 0
    }
    XCTAssertGreaterThan(catalogRows, 0)
    XCTAssertEqual(snapshot.recipes.filter { $0.databaseID < 0 }.count, catalogRows)
    // 166 legacy rows minus the 141 scraped ones.
    XCTAssertEqual(snapshot.recipes.filter { $0.databaseID > 0 }.count, 25)
    XCTAssertNil(snapshot.recipes.first { $0.title == "Air fryer tuna pasta bake" })
    XCTAssertEqual(snapshot.ingredientNames.values.filter { $0.contains("_") }, [])

    // data.json recipe 1: egg 100 g, rice 316 g, soy sauce 15 g; green onion 15 g optional.
    let friedRice = try XCTUnwrap(snapshot.recipes.first { $0.title == "Classic Egg Fried Rice" })
    XCTAssertGreaterThan(friedRice.databaseID, 0)
    let greenOnion = try XCTUnwrap(friedRice.lines.first { $0.name == "Green onion" })
    // rcp-000491: chickpeas 360 g, tomato 240 g, cucumber 300 g, lime 65 g, cilantro 4 g.
    let chaat = try XCTUnwrap(snapshot.recipes.first { $0.ref.id == "rcp-000491" })
    XCTAssertEqual(chaat.databaseID, -491)
    XCTAssertEqual(chaat.title, "Chickpea and Tomato Chaat")

    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(snapshot)
    model.selectRecipe(friedRice.databaseID, selected: true)
    model.selectRecipe(chaat.databaseID, selected: true)
    model.selectOptional(greenOnion.ingredientID, recipeID: friedRice.databaseID, selected: true)
    model.setGuests(4)

    let needed = try plan(model).ingredients
      .map { "\(model.name(for: $0.ingredientID)) \($0.requiredGrams)" }
      .sorted()
    XCTAssertEqual(needed, [
      "Chickpeas 720.0", "Cilantro 8.0", "Cucumber 600.0", "Egg 200.0", "Green onion 30.0",
      "Lime 130.0", "Rice 632.0", "Soy sauce 30.0", "Tomato 480.0",
    ])
    XCTAssertEqual(model.uncountedLines, [])
  }

  /// Production migrations, with app ingredients rice(2), peanut(3), flour(4), oil(5) and
  /// catalog vocabulary bridging rice and oil; lovage has no app ingredient.
  private func database() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try DatabaseMigrations.migrate(queue)
    try queue.write { db in
      try db.execute(sql: """
        INSERT INTO ingredients (id, name, calories, protein, carbs, fat) VALUES
          (2, 'rice', 130, 2.7, 28, 0.3),
          (3, 'peanut', 567, 25.8, 16, 49),
          (4, 'flour', 364, 10, 76, 1),
          (5, 'oil', 884, 0, 0, 100);
        INSERT INTO recipes_catalog_ingredients
          (key, fdc_id, legacy_id, display_name, category, classes) VALUES
          ('rice', NULL, 2, 'Rice', 'grain', '["plant"]'),
          ('oil', NULL, 5, 'Oil', 'fat', '["plant"]'),
          ('lovage', NULL, NULL, 'Lovage', 'herb', '["plant"]');
        INSERT INTO recipes_catalog_ingredient_bridge
          (ingredient_key, ingredient_id, resolved_by) VALUES
          ('rice', 2, 'legacy_id'),
          ('oil', 5, 'legacy_id');
        """)
    }
    return queue
  }

  private func recipe(id: Int64 = 10, grams: Double = 250) -> PlanCandidate {
    .init(
      databaseID: id, ref: RecipeRef(source: .catalog, id: String(id), revision: 1),
      title: "Rice supper", timeMinutes: 20, baseServings: 2,
      lines: [
        .init(ingredientID: 1, name: "Rice", grams: grams, isRequired: true),
        .init(ingredientID: 2, name: "Salt", grams: 25, isRequired: false),
      ]
    )
  }

  private func lot(id: Int64 = 20, ingredientID: Int64 = 1, grams: Double = 100) -> InventoryLot {
    .init(id: id, ingredientId: ingredientID, quantityGrams: 900, remainingGrams: grams,
          storageLocation: .pantry, confidenceScore: 1, source: .manual, acquiredAt: mealDate.addingTimeInterval(-3_600),
          expiresAt: mealDate.addingTimeInterval(3_600))
  }

  private func snapshot() -> GuestMealSnapshot {
    .init(recipes: [recipe()], lots: [lot()], ingredientNames: [1: "Rice", 2: "Salt"], stapleIngredientIDs: [])
  }

  private func model() -> GuestMealPlanViewModel {
    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(snapshot())
    return model
  }

  private func plan(_ model: GuestMealPlanViewModel, file: StaticString = #filePath, line: UInt = #line) throws -> GuestMealPlanner.Plan {
    guard case .ready(let plan) = model.review else {
      XCTFail("Expected a current plan, got \(model.review)", file: file, line: line)
      throw GuestMealMapping.Issue(message: "Expected a plan")
    }
    return plan
  }
}
