import GRDB
import XCTest

@testable import FridgeLuck

/// The accepted meal plan must be one object: what the editor displays, what the deduction
/// preview promises, and what logging persists all agree — including shortages, swaps,
/// fractional grams, identity rules, and repeated callbacks.
final class MealPlanAgreementTests: XCTestCase {
  /// XCTest's accuracy overload only compares scalars; element-wise comparison for arrays.
  private func assertEqual(
    _ actual: [Double], _ expected: [Double], accuracy: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard actual.count == expected.count else {
      XCTFail("count mismatch: \(actual.count) vs \(expected.count)", file: file, line: line)
      return
    }
    for (index, (a, e)) in zip(actual, expected).enumerated() {
      guard abs(a - e) <= accuracy else {
        XCTFail("element \(index): \(a) != \(e) ±\(accuracy)", file: file, line: line)
        return
      }
    }
  }

  // MARK: - Agreement (display / preview / persisted deduction)

  func testDisplayPlanPreviewAndLoggedDeductionAgree() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (3, 50)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)

    // Recipe serves 2; one serving at normal portion asks for half of each amount.
    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    XCTAssertEqual(plan.lines.map(\.resolvedIngredientId), [1, 2, 3])
    assertEqual(plan.lines.map(\.plannedGrams), [150, 50, 10], accuracy: 0.001)
    XCTAssertEqual(plan.lines.map(\.provenance), [.suggestedRecipeQuantity, .suggestedRecipeQuantity, .suggestedRecipeQuantity])

    let previews = MealPlanLinePreview.ingredientPreviews(
      from: try inventory.previewPlanConsumption(plan: plan))
    XCTAssertEqual(previews.map(\.ingredientId), [1, 2, 3])
    assertEqual(previews.map(\.proposedGrams), [150, 50, 10], accuracy: 0.001)
    assertEqual(previews.map(\.deductedGrams), [150, 50, 10], accuracy: 0.001)
    assertEqual(previews.map(\.shortfallGrams), [0, 0, 0], accuracy: 0.001)

    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    let outcome = try log.logMeal(
      recipe: recipe, servingsConsumed: 1, portionMultiplier: 1.0, sourceRefPrefix: "reverse_scan",
      plan: plan)

    // The log's recorded consumption equals the preview, line for line.
    XCTAssertEqual(outcome.inventoryConsumption.map(\.ingredientId), previews.map(\.ingredientId))
    for (preview, result) in zip(previews, outcome.inventoryConsumption) {
      XCTAssertEqual(preview.deductedGrams, result.consumedGrams, accuracy: 0.001)
      XCTAssertEqual(preview.proposedGrams, result.requestedGrams, accuracy: 0.001)
      XCTAssertEqual(preview.shortfallGrams, result.shortfallGrams, accuracy: 0.001)
    }
    // And the inventory events carry exactly those grams.
    let eventGrams = try PlanFixture.eventGramsByIngredient(db)
    XCTAssertEqual(eventGrams[1] ?? 0, 150, accuracy: 0.001)
    XCTAssertEqual(eventGrams[2] ?? 0, 50, accuracy: 0.001)
    XCTAssertEqual(eventGrams[3] ?? 0, 10, accuracy: 0.001)

    // The persisted accepted plan is the same plan, with applied grams filled in.
    let row = try XCTUnwrap(PlanFixture.acceptedRow(db, historyId: outcome.historyId))
    let accepted = try XCTUnwrap(MealConsumptionPlan.decode(from: row["accepted_plan_json"]))
    XCTAssertEqual(row["accepted_plan_identity"] as String?, plan.identity)
    XCTAssertEqual(accepted.recipeId, 1)
    assertEqual(accepted.lines.map(\.plannedGrams), plan.lines.map(\.plannedGrams), accuracy: 0.001)
    assertEqual(accepted.lines.map(\.appliedGrams), [150, 50, 10], accuracy: 0.001)
  }

  // MARK: - Shortages

  func testShortageConsumesAvailableStockAndReportsShortfall() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 100), (2, 600), (3, 50)])  // rice short
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)

    let previews = MealPlanLinePreview.ingredientPreviews(
      from: try inventory.previewPlanConsumption(plan: plan))
    let rice = try XCTUnwrap(previews.first { $0.ingredientId == 1 })
    XCTAssertEqual(rice.proposedGrams, 150, accuracy: 0.001)
    XCTAssertEqual(rice.deductedGrams, 100, accuracy: 0.001)
    XCTAssertEqual(rice.shortfallGrams, 50, accuracy: 0.001)

    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    let outcome = try log.logMeal(recipe: recipe, servingsConsumed: 1, plan: plan)
    let consumedRice = try XCTUnwrap(outcome.inventoryConsumption.first { $0.ingredientId == 1 })
    XCTAssertEqual(consumedRice.requestedGrams, 150, accuracy: 0.001)
    XCTAssertEqual(consumedRice.consumedGrams, 100, accuracy: 0.001)
    XCTAssertEqual(consumedRice.shortfallGrams, 50, accuracy: 0.001)
    let eventGrams = try PlanFixture.eventGramsByIngredient(db)
    XCTAssertEqual(eventGrams[1] ?? 0, 100, accuracy: 0.001)
    // The accepted plan keeps the user-facing proposal (150) and stores the applied 100.
    let row = try XCTUnwrap(PlanFixture.acceptedRow(db, historyId: outcome.historyId))
    let accepted = try XCTUnwrap(MealConsumptionPlan.decode(from: row["accepted_plan_json"]))
    XCTAssertEqual(accepted.lines[0].plannedGrams, 150, accuracy: 0.001)
    XCTAssertEqual(accepted.lines[0].appliedGrams, 100, accuracy: 0.001)
  }

  // MARK: - Swaps

  func testSwapSubstitutesAtRatioAndReidentifiesTheLine() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (4, 80)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0,
      swaps: [IngredientSwap(originalIngredientId: 3, substituteIngredientId: 4, ratio: 0.5)])
    let swapped = try XCTUnwrap(plan.lines.first { $0.lineKey == 3 })
    XCTAssertEqual(swapped.resolvedIngredientId, 4)
    XCTAssertEqual(swapped.originalIngredientId, 3)
    XCTAssertEqual(swapped.displayName, "Soy Sauce")
    // 20 g scallion at a 0.5 ratio, then the 0.5 serving factor.
    XCTAssertEqual(swapped.recipeReferenceGrams, 10, accuracy: 0.001)
    XCTAssertEqual(swapped.plannedGrams, 5, accuracy: 0.001)
    // Nutrition comes from the substitute (soy sauce per 100 g), not scallion.
    XCTAssertEqual(swapped.nutritionPer100g.calories, 53, accuracy: 0.001)

    let previews = MealPlanLinePreview.ingredientPreviews(
      from: try inventory.previewPlanConsumption(plan: plan))
    XCTAssertEqual(previews.map(\.ingredientId), [1, 2, 4])

    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    _ = try log.logMeal(recipe: recipe, servingsConsumed: 1, plan: plan)
    let eventGrams = try PlanFixture.eventGramsByIngredient(db)
    XCTAssertEqual(eventGrams[4] ?? 0, 5, accuracy: 0.001)
    XCTAssertNil(eventGrams[3], "the swapped-out ingredient must not be deducted")
  }

  // MARK: - Fractional grams and derived macros

  func testFractionalGramsSurvivePreviewLogAndMacroMath() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (3, 50)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)

    var plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    plan.lines[0].plannedGrams = 137.5
    plan.lines[0].provenance = .userVerified

    // Derived macros over the whole plan: 137.5 g rice at 130 kcal/100 g plus the
    // untouched egg (50 g at 155) and scallion (10 g at 32) lines.
    XCTAssertEqual(plan.totalMacros.calories, 178.75 + 77.5 + 3.2, accuracy: 0.001)
    XCTAssertEqual(plan.totalMacros.protein, 137.5 * 2.7 / 100 + 6.5 + 0.18, accuracy: 0.001)
    // The edited line alone carries 137.5 g × 130 kcal / 100 g.
    XCTAssertEqual(plan.lines[0].scaledMacros().calories, 178.75, accuracy: 0.001)

    let previews = MealPlanLinePreview.ingredientPreviews(
      from: try inventory.previewPlanConsumption(plan: plan))
    XCTAssertEqual(previews[0].proposedGrams, 137.5, accuracy: 0.001)
    XCTAssertEqual(previews[0].deductedGrams, 137.5, accuracy: 0.001)

    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })
    let outcome = try log.logMeal(recipe: recipe, servingsConsumed: 1, plan: plan)
    let eventGrams = try PlanFixture.eventGramsByIngredient(db)
    XCTAssertEqual(eventGrams[1] ?? 0, 137.5, accuracy: 0.001)
    let row = try XCTUnwrap(PlanFixture.acceptedRow(db, historyId: outcome.historyId))
    let accepted = try XCTUnwrap(MealConsumptionPlan.decode(from: row["accepted_plan_json"]))
    XCTAssertEqual(accepted.lines[0].appliedGrams, 137.5, accuracy: 0.001)
    XCTAssertEqual(accepted.lines[0].provenance, .userVerified)
  }

  // MARK: - Identity across rebuilds

  func testIdentitySurvivesRebuildsAndRescalesButNotRecipeChanges() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (3, 50)])

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    var edited = plan
    edited.lines[0].plannedGrams = 137.5
    edited.lines[0].provenance = .userVerified

    // Rebuilding the same recipe (bigger portion) keeps the identity and the verified grams.
    let rebuilt = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.4, previous: edited)
    XCTAssertEqual(rebuilt.identity, plan.identity)
    XCTAssertEqual(rebuilt.lines[0].plannedGrams, 137.5, accuracy: 0.001)
    XCTAssertEqual(rebuilt.lines[0].provenance, .userVerified)
    XCTAssertEqual(rebuilt.lines[1].plannedGrams, 50 * 1.4, accuracy: 0.001)

    // Rescaling keeps the identity too.
    let rescaled = rebuilt.rescaled(servingsConsumed: 2, portionMultiplier: 1.0)
    XCTAssertEqual(rescaled.identity, plan.identity)
    XCTAssertEqual(rescaled.lines[0].plannedGrams, 137.5, accuracy: 0.001)
    XCTAssertEqual(rescaled.lines[1].plannedGrams, 100, accuracy: 0.001)

    // A different recipe starts a fresh identity.
    let otherRecipe = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 2, servingsConsumed: 1, portionMultiplier: 1.0, previous: plan)
    XCTAssertNotEqual(otherRecipe.identity, plan.identity)
  }

  // MARK: - Repeated callbacks

  func testRepeatedLogCallbacksCannotDoubleDeduct() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (3, 50)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)
    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    let first = try log.logMeal(recipe: recipe, servingsConsumed: 1, plan: plan)
    let second = try log.logMeal(recipe: recipe, servingsConsumed: 1, plan: plan)

    // The retry is the same accepted meal: same history row, same consumption report.
    XCTAssertEqual(second.historyId, first.historyId)
    assertEqual(
      second.inventoryConsumption.map(\.consumedGrams),
      first.inventoryConsumption.map(\.consumedGrams), accuracy: 0.001)
    XCTAssertEqual(try PlanFixture.historyCount(db), 1)
    let eventGrams = try PlanFixture.eventGramsByIngredient(db)
    XCTAssertEqual(eventGrams[1] ?? 0, 150, accuracy: 0.001)
    XCTAssertEqual(eventGrams[2] ?? 0, 50, accuracy: 0.001)
    XCTAssertEqual(eventGrams[3] ?? 0, 10, accuracy: 0.001)
  }

  // MARK: - Rejections

  func testPlanRecipeMismatchIsRejectedAndWritesNothing() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (3, 50)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)
    let recipe2 = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 2) })

    let plan = try MealConsumptionPlanBuilder.build(
      from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
    XCTAssertThrowsError(try log.logMeal(recipe: recipe2, servingsConsumed: 1, plan: plan)) {
      error in
      guard case MealLogError.planRecipeMismatch = error else {
        return XCTFail("expected planRecipeMismatch, got \(error)")
      }
    }
    XCTAssertEqual(try PlanFixture.historyCount(db), 0)
    XCTAssertEqual(try PlanFixture.eventCount(db), 0)
  }

  func testInvalidPlannedGramsAreRejectedAndWriteNothing() throws {
    let db = try PlanFixture.makeDatabase()
    let inventory = InventoryRepository(db: db)
    try PlanFixture.stock(inventory, pairs: [(1, 1_000), (2, 600), (3, 50)])
    let log = PlanFixture.makeMealLogService(db: db, inventory: inventory)
    let recipe = try XCTUnwrap(try db.read { try Recipe.fetchOne($0, key: 1) })

    for badGrams in [-5.0, .nan, .infinity] {
      var plan = try MealConsumptionPlanBuilder.build(
        from: db, recipeId: 1, servingsConsumed: 1, portionMultiplier: 1.0)
      plan.lines[0].plannedGrams = badGrams
      XCTAssertThrowsError(try log.logMeal(recipe: recipe, servingsConsumed: 1, plan: plan)) {
        error in
        guard case MealLogError.invalidPlannedGrams = error else {
          return XCTFail("expected invalidPlannedGrams, got \(error)")
        }
      }
    }
    XCTAssertEqual(try PlanFixture.historyCount(db), 0)
    XCTAssertEqual(try PlanFixture.eventCount(db), 0)
  }

  func testUnknownRecipeFailsTheBuild() throws {
    let db = try PlanFixture.makeDatabase()
    XCTAssertThrowsError(
      try MealConsumptionPlanBuilder.build(
        from: db, recipeId: 999, servingsConsumed: 1, portionMultiplier: 1.0)
    ) { error in
      guard case MealConsumptionPlanError.unknownRecipe = error else {
        return XCTFail("expected unknownRecipe, got \(error)")
      }
    }
  }
}
