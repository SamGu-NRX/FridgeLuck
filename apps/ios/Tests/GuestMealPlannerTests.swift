import FLFeatureLogic
import Foundation
import XCTest

final class GuestMealPlannerTests: XCTestCase {
  private typealias Planner = GuestMealPlanner
  private let eventDate = Date(timeIntervalSince1970: 1_800_000_000)

  func testMenuSharesStockAcrossRecipesAndCombinesRepeatedIngredients() throws {
    let menu = [
      recipe(1, servings: 2, amounts: [(10, 200), (20, 50), (10, 25)]),
      recipe(2, servings: 4, amounts: [(10, 100), (30, 80)]),
    ]
    let stock = [lot(1, ingredient: 10, grams: 300), lot(2, ingredient: 20, grams: 150)]

    let result = try Planner.plan(
      guestCount: 4, eventDate: eventDate, recipes: menu, inventory: stock
    )

    XCTAssertEqual(result.guestCount, 4)
    XCTAssertEqual(result.eventDate, eventDate)
    XCTAssertEqual(result.ingredients.map(\.ingredientID), [10, 20, 30])
    XCTAssertEqual(result.ingredients.map(\.requiredGrams), [550, 100, 80])
    XCTAssertEqual(result.ingredients.map(\.availableGrams), [300, 150, 0])
    XCTAssertEqual(result.ingredients.map(\.allocatedGrams), [300, 100, 0])
    XCTAssertEqual(result.ingredients.map(\.missingGrams), [250, 0, 80])
    XCTAssertEqual(result.shoppingList.map(\.ingredientID), [10, 30])
  }

  func testFractionalGuestScalingDoesNotRoundUpWholeRecipeBatches() throws {
    let result = try Planner.plan(
      guestCount: 3, eventDate: eventDate,
      recipes: [recipe(1, servings: 4, amounts: [(10, 150)])],
      inventory: [lot(1, ingredient: 10, grams: 50.25)]
    )

    let line = try XCTUnwrap(result.shoppingList.first)
    XCTAssertEqual(line.requiredGrams, 112.5)
    XCTAssertEqual(line.missingGrams, 62.25)
  }

  func testOnlyConfirmedStockRemainingAfterEventCutoffReducesShopping() throws {
    let result = try Planner.plan(
      guestCount: 1, eventDate: eventDate,
      recipes: [recipe(1, servings: 1, amounts: [(10, 500)])],
      inventory: [
        lot(1, ingredient: 10, grams: 40, expiry: eventDate.addingTimeInterval(-1)),
        lot(2, ingredient: 10, grams: 60, expiry: eventDate),
        lot(3, ingredient: 10, grams: 100, expiry: eventDate.addingTimeInterval(1)),
        lot(4, ingredient: 10, grams: 80, status: .needsConfirmation),
        lot(5, ingredient: 10, grams: 20),
        lot(6, ingredient: 10, grams: 30, status: .needsConfirmation, expiry: eventDate),
        lot(7, ingredient: 99, grams: 999),
      ]
    )

    let line = try XCTUnwrap(result.ingredients.first)
    XCTAssertEqual(line.availableGrams, 120)
    XCTAssertEqual(line.missingGrams, 380)
    XCTAssertEqual(line.needsConfirmationGrams, 80)
    XCTAssertEqual(line.expiresBeforeEventGrams, 130)
  }

  func testConfirmationAndChangedGuestCountRecomputeWithoutReservingStock() throws {
    let menu = [recipe(1, servings: 2, amounts: [(10, 200)])]
    let unconfirmed = try Planner.plan(
      guestCount: 2, eventDate: eventDate, recipes: menu,
      inventory: [lot(1, ingredient: 10, grams: 250, status: .needsConfirmation)]
    )
    let confirmedStock = [lot(1, ingredient: 10, grams: 250)]
    let confirmed = try Planner.plan(
      guestCount: 2, eventDate: eventDate, recipes: menu, inventory: confirmedStock
    )
    let moreGuests = try Planner.plan(
      guestCount: 4, eventDate: eventDate, recipes: menu, inventory: confirmedStock
    )
    let repeated = try Planner.plan(
      guestCount: 2, eventDate: eventDate, recipes: menu, inventory: confirmedStock
    )

    XCTAssertEqual(unconfirmed.shoppingList.map(\.missingGrams), [200])
    XCTAssertEqual(confirmed.ingredients.map(\.allocatedGrams), [200])
    XCTAssertEqual(confirmed.shoppingList, [])
    XCTAssertEqual(moreGuests.shoppingList.map(\.missingGrams), [150])
    XCTAssertEqual(repeated, confirmed)
    XCTAssertEqual(confirmedStock.first?.remainingGrams, 250)
  }

  func testMovingEventPastExpiryAddsGroceries() throws {
    let menu = [recipe(1, servings: 1, amounts: [(10, 200)])]
    let stock = [lot(1, ingredient: 10, grams: 300, expiry: eventDate.addingTimeInterval(60))]
    let earlier = try Planner.plan(
      guestCount: 1, eventDate: eventDate, recipes: menu, inventory: stock
    )
    let later = try Planner.plan(
      guestCount: 1, eventDate: eventDate.addingTimeInterval(120), recipes: menu, inventory: stock
    )

    XCTAssertEqual(earlier.ingredients.map(\.allocatedGrams), [200])
    XCTAssertEqual(earlier.shoppingList, [])
    XCTAssertEqual(later.shoppingList.map(\.missingGrams), [200])
  }

  func testDuplicateLotsAndRecipesAreRejectedInsteadOfDoubleCounting() {
    assertError(
      .duplicateLot(1),
      inventory: [lot(1, ingredient: 10, grams: 50), lot(1, ingredient: 10, grams: 50)]
    )
    let dish = recipe(1, servings: 1, amounts: [(10, 100)])
    assertError(.duplicateRecipe(1), recipes: [dish, dish])
  }

  func testInvalidCountsAndEmptyMenuAreRejected() {
    assertError(.invalidGuestCount, guests: 0)
    assertError(.invalidGuestCount, guests: -1)
    assertError(.emptyMenu, recipes: [])
    assertError(.invalidBaseServings(1), recipes: [recipe(1, servings: 0, amounts: [(10, 100)])])
    assertError(.invalidBaseServings(1), recipes: [recipe(1, servings: -1, amounts: [(10, 100)])])
    assertError(.emptyRecipe(1), recipes: [recipe(1, servings: 1, amounts: [])])
  }

  func testInvalidIdentitiesAreRejected() {
    assertError(.invalidRecipe(0), recipes: [recipe(0, servings: 1, amounts: [(10, 100)])])
    assertError(.invalidIngredient(-1), recipes: [recipe(1, servings: 1, amounts: [(-1, 100)])])
    assertError(.invalidLot(0), inventory: [lot(0, ingredient: 10, grams: 50)])
    assertError(.invalidIngredient(0), inventory: [lot(1, ingredient: 0, grams: 50)])
  }

  func testNonFiniteAndNegativeGramsAreRejected() {
    for grams in [Double.nan, .infinity, -.infinity, -1, 0] {
      assertError(
        .invalidRecipeGrams(recipeID: 1, ingredientID: 10),
        recipes: [recipe(1, servings: 1, amounts: [(10, grams)])]
      )
    }
    for grams in [Double.nan, .infinity, -.infinity, -1] {
      assertError(.invalidInventoryGrams(1), inventory: [lot(1, ingredient: 10, grams: grams)])
    }
  }

  func testEmptyInventoryLotsAreAllowed() throws {
    let result = try Planner.plan(
      guestCount: 1, eventDate: eventDate,
      recipes: [recipe(1, servings: 1, amounts: [(10, 100)])],
      inventory: [lot(1, ingredient: 10, grams: 0)]
    )
    XCTAssertEqual(result.shoppingList.map(\.missingGrams), [100])
  }

  func testInvalidDatesAreRejected() {
    for seconds in [Double.nan, .infinity, -.infinity] {
      assertError(.invalidEventDate, date: Date(timeIntervalSinceReferenceDate: seconds))
      assertError(
        .invalidExpiry(1),
        inventory: [
          lot(1, ingredient: 10, grams: 50, expiry: Date(timeIntervalSinceReferenceDate: seconds))
        ]
      )
    }
  }

  func testOverflowInScaledOrCombinedQuantitiesIsRejected() {
    assertError(
      .quantityOverflow(10), guests: 2,
      recipes: [recipe(1, servings: 1, amounts: [(10, .greatestFiniteMagnitude)])]
    )
    assertError(
      .quantityOverflow(10),
      recipes: [
        recipe(1, servings: 1, amounts: [(10, .greatestFiniteMagnitude), (10, .greatestFiniteMagnitude)])
      ]
    )
    assertError(
      .quantityOverflow(10),
      inventory: [
        lot(1, ingredient: 10, grams: .greatestFiniteMagnitude),
        lot(2, ingredient: 10, grams: .greatestFiniteMagnitude),
      ]
    )
  }

  private func recipe(_ id: Int64, servings: Int, amounts: [(Int64, Double)]) -> Planner.Recipe {
    Planner.Recipe(
      recipeID: id, baseServings: servings,
      ingredients: amounts.map { Planner.IngredientAmount(ingredientID: $0.0, grams: $0.1) }
    )
  }

  private func lot(
    _ id: Int64, ingredient: Int64, grams: Double,
    status: Planner.QuantityStatus = .confirmed, expiry: Date? = nil
  ) -> Planner.InventoryLot {
    Planner.InventoryLot(
      lotID: id, ingredientID: ingredient, remainingGrams: grams,
      quantityStatus: status, expiresAt: expiry
    )
  }

  private func assertError(
    _ expected: Planner.PlanningError, guests: Int = 1, date: Date? = nil,
    recipes: [Planner.Recipe]? = nil, inventory: [Planner.InventoryLot] = [],
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try Planner.plan(
        guestCount: guests, eventDate: date ?? eventDate,
        recipes: recipes ?? [recipe(1, servings: 1, amounts: [(10, 100)])], inventory: inventory
      ), file: file, line: line
    ) { error in
      XCTAssertEqual(error as? Planner.PlanningError, expected, file: file, line: line)
    }
  }
}
