import FLFeatureLogic
import Foundation
import XCTest

@testable import FridgeLuck

@MainActor
final class GuestMealPlanningFlowTests: XCTestCase {
  private let mealDate = Date(timeIntervalSince1970: 2_000_000_000)

  func testRecipeMappingUsesStoredServingsGramsAndOnlyChosenOptionals() throws {
    let stored = recipe()
    let requiredOnly = try GuestMealMapping.recipe(stored, optionalIDs: [])
    XCTAssertEqual(requiredOnly.recipeID, 10)
    XCTAssertEqual(requiredOnly.baseServings, 2)
    XCTAssertEqual(requiredOnly.ingredients, [.init(ingredientID: 1, grams: 250)])
    let withOptional = try GuestMealMapping.recipe(stored, optionalIDs: [2])
    XCTAssertEqual(withOptional.ingredients, [
      .init(ingredientID: 1, grams: 250), .init(ingredientID: 2, grams: 25),
    ])
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

  func testMappingRejectsInvalidRecipeAndLotWithNames() throws {
    var invalid = recipe().recipe
    invalid.servings = 0
    XCTAssertThrowsError(try GuestMealMapping.recipe(.init(recipe: invalid, ingredients: recipe().ingredients), optionalIDs: [])) {
      XCTAssertTrue($0.localizedDescription.contains("Rice supper"))
    }
    var badLot = lot()
    badLot.remainingGrams = .infinity
    XCTAssertThrowsError(try GuestMealMapping.lot(badLot, reviewedGrams: nil, name: "Rice")) {
      XCTAssertTrue($0.localizedDescription.contains("Rice, lot 20"))
    }
    let corrected = try GuestMealMapping.lot(badLot, reviewedGrams: 10, name: "Rice")
    XCTAssertEqual(corrected.remainingGrams, 10)
  }

  func testRecipeMappingRejectsForeignAndDuplicateIngredientRows() throws {
    var row = recipe().ingredients[0]
    row.recipeId = 999
    XCTAssertThrowsError(try GuestMealMapping.recipe(.init(recipe: recipe().recipe, ingredients: [row]), optionalIDs: []))
    row.recipeId = 10
    XCTAssertThrowsError(try GuestMealMapping.recipe(.init(recipe: recipe().recipe, ingredients: [row, row]), optionalIDs: []))
    XCTAssertEqual(try GuestMealMapping.recipe(.init(recipe: recipe().recipe, ingredients: [row]), optionalIDs: []).ingredients.count, 1)
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
    model.replaceSnapshot(.init(recipes: [recipe()], lots: [stock], ingredientNames: [1: "Rice"]))
    model.selectRecipe(10, selected: true)
    XCTAssertTrue(model.canConfirm(stock))
    model.confirmLot(20, confirmed: true)
    XCTAssertEqual(try plan(model).ingredients[0].missingGrams, 150)
    stock.expiresAt = Date(timeIntervalSinceReferenceDate: .infinity)
    model.replaceSnapshot(.init(recipes: [recipe()], lots: [stock], ingredientNames: [1: "Rice"]))
    XCTAssertFalse(model.canConfirm(stock))
    XCTAssertEqual(model.exclusionReason(for: stock), "Excluded: correct the invalid expiry in your fridge, then reload inventory.")
    guard case .invalid(let message) = model.review else { return XCTFail("Malformed expiry must hide totals") }
    XCTAssertTrue(message.contains("Rice, lot 20"))
  }

  func testExactIngredientIDsPreventFormSubstitutionAndSharedStockIsAllocatedOnce() throws {
    let second = recipe(id: 11, grams: 100)
    let model = GuestMealPlanViewModel(eventDate: mealDate)
    model.replaceSnapshot(.init(recipes: [recipe(), second], lots: [lot(), lot(id: 21, ingredientID: 3, grams: 1_000)], ingredientNames: [1: "Raw rice", 3: "Cooked rice"]))
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
    model.replaceSnapshot(.init(recipes: [], lots: [], ingredientNames: [:]))
    guard case .invalid(let message) = model.review else { return XCTFail("Deleted recipe must be explicit") }
    XCTAssertTrue(message.contains("no longer available"))
    XCTAssertEqual(model.selectedRecipeIDs, [10])
    model.selectRecipe(10, selected: false)
    guard case .empty = model.review else { return XCTFail("Removing missing recipe should recover") }
  }

  private func recipe(id: Int64 = 10, grams: Double = 250) -> GuestMealRecipe {
    .init(
      recipe: .init(id: id, title: "Rice supper", timeMinutes: 20, servings: 2, instructions: "Cook", tags: 0, source: .bundled),
      ingredients: [
        .init(recipeId: id, ingredientId: 1, isRequired: true, quantityGrams: grams, displayQuantity: "not used"),
        .init(recipeId: id, ingredientId: 2, isRequired: false, quantityGrams: 25, displayQuantity: "not used"),
      ]
    )
  }

  private func lot(id: Int64 = 20, ingredientID: Int64 = 1, grams: Double = 100) -> InventoryLot {
    .init(id: id, ingredientId: ingredientID, quantityGrams: 900, remainingGrams: grams,
          storageLocation: .pantry, confidenceScore: 1, source: .manual, acquiredAt: mealDate.addingTimeInterval(-3_600),
          expiresAt: mealDate.addingTimeInterval(3_600))
  }

  private func snapshot() -> GuestMealSnapshot {
    .init(recipes: [recipe()], lots: [lot()], ingredientNames: [1: "Rice", 2: "Salt"])
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
