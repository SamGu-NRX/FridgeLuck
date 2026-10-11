import FLFeatureLogic
import Foundation
import XCTest

@testable import FridgeLuck

/// Acceptance tests for the app-to-planner input adapter: the documented
/// projections from read-only app state (stock lots, profile exclusions,
/// recipe tags) into `WeeklyPlanInput`. Pure mapping — no database here.
final class WeeklyPlanInputAdapterTests: XCTestCase {
  // MARK: - Fixtures

  private func makeIngredient(_ id: Int64, name: String) -> Ingredient {
    Ingredient(
      id: id, name: name, calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0, sugar: 0,
      sodium: 0, typicalUnit: nil, storageTip: nil, pairsWith: nil, notes: nil,
      description: nil, categoryLabel: nil, spriteGroup: nil, spriteKey: nil)
  }

  private func makeRecipe(_ id: Int64, tags: Int = 0, time: Int = 30) -> Recipe {
    Recipe(
      id: id, title: "Recipe \(id)", timeMinutes: time, servings: 2, instructions: "",
      tags: tags, source: .bundled, createdAt: nil)
  }

  private func makeRow(
    _ recipeId: Int64, _ ingredientId: Int64, required: Bool, grams: Double
  ) -> (ingredient: Ingredient, quantity: RecipeIngredient) {
    (
      makeIngredient(ingredientId, name: "Ingredient \(ingredientId)"),
      RecipeIngredient(
        recipeId: recipeId, ingredientId: ingredientId, isRequired: required,
        quantityGrams: grams, displayQuantity: "")
    )
  }

  private func makeLot(
    _ ingredientId: Int64, grams: Double, estimated: Bool, daysToExpiry: Int? = nil,
    now: Date
  ) -> InventoryPlanningLot {
    let expiry = daysToExpiry.map {
      Calendar.current.date(byAdding: .day, value: $0, to: now)
    }
    return InventoryPlanningLot(
      ingredientId: ingredientId, remainingGrams: grams, quantityIsEstimate: estimated,
      expiresAt: expiry)
  }

  private func makeProfile(
    groups: String = "[]", individual: String = "[]", restrictions: String = "[]"
  ) -> HealthProfile {
    var profile = HealthProfile.default
    profile.allergenSelectedGroups = groups
    profile.allergenIngredientIds = individual
    profile.dietaryRestrictions = restrictions
    return profile
  }

  // MARK: - Stock

  func testKnownLotsArePassedPerLotAndSumInStockByID() {
    let now = Calendar.current.startOfDay(for: Date())
    let lots = [
      makeLot(1, grams: 600, estimated: false, now: now),
      makeLot(1, grams: 50, estimated: false, now: now),
    ]
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [], ingredientsByRecipe: [:], lots: lots, profile: makeProfile())

    XCTAssertEqual(input.stock.count, 2)
    let combined = input.stockByID[1]
    XCTAssertEqual(combined?.quantityIsKnown, true)
    XCTAssertEqual(combined?.availableGrams, 650)
  }

  func testUnconfirmedLotTaintsTheWholeIngredient() {
    // One photo-intake guess alongside confirmed stock: the guess cannot back
    // feasibility, so the collapsed row is unknown regardless of totals.
    let now = Calendar.current.startOfDay(for: Date())
    let lots = [
      makeLot(1, grams: 600, estimated: false, now: now),
      makeLot(1, grams: 30, estimated: true, now: now),
    ]
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [], ingredientsByRecipe: [:], lots: lots, profile: makeProfile())

    let combined = input.stockByID[1]
    XCTAssertEqual(combined?.quantityIsKnown, false)
    XCTAssertEqual(combined?.availableGrams, 0)
  }

  // MARK: - Urgency from expiry

  func testUrgencyWeightsDecayAcrossTheWindow() {
    let now = Calendar.current.startOfDay(for: Date())
    let lots = [
      makeLot(1, grams: 100, estimated: false, daysToExpiry: 0, now: now),
      makeLot(2, grams: 100, estimated: false, daysToExpiry: 1, now: now),
      makeLot(3, grams: 100, estimated: false, daysToExpiry: 2, now: now),
      makeLot(4, grams: 100, estimated: false, daysToExpiry: 3, now: now),
      makeLot(5, grams: 100, estimated: false, daysToExpiry: 9, now: now),
      makeLot(6, grams: 100, estimated: false, now: now),
    ]
    let urgencies = WeeklyPlanInputAdapter.urgencies(lots: lots, now: now)
    let byId = Dictionary(urgencies.map { ($0.ingredientId, $0.weightPerGram) },
      uniquingKeysWith: { _, last in last })

    XCTAssertEqual(byId[1], 1.0, accuracy: 1e-9)
    XCTAssertEqual(byId[2], 2.0 / 3.0, accuracy: 1e-9)
    XCTAssertEqual(byId[3], 1.0 / 3.0, accuracy: 1e-9)
    XCTAssertNil(byId[4], "The window edge carries zero weight — absent, not zero.")
    XCTAssertNil(byId[5], "Lots expiring beyond the window carry no urgency.")
    XCTAssertNil(byId[6], "No expiry date means no urgency, not a guess.")
  }

  func testAlreadyExpiredLotCountsAsExpiryDay() {
    let now = Calendar.current.startOfDay(for: Date())
    let lots = [makeLot(1, grams: 100, estimated: false, daysToExpiry: -2, now: now)]
    let urgencies = WeeklyPlanInputAdapter.urgencies(lots: lots, now: now)
    XCTAssertEqual(urgencies.first?.weightPerGram, 1.0, accuracy: 1e-9)
  }

  // MARK: - Exclusions and diet

  func testExclusionsUnionGroupsIndividualAndDietExclusions() {
    // Group "milk" excludes the bundled dairy core IDs; 7 is an individual
    // exclusion; a vegan diet additionally excludes its own dairy set.
    let profile = makeProfile(
      groups: "[\"milk\"]", individual: "[7]", restrictions: "[\"vegan\"]")
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [], ingredientsByRecipe: [:], lots: [], profile: profile)

    let excluded = input.constraints.excludedIngredientIds
    XCTAssertTrue(excluded.contains(7), "Individual exclusions pass through.")
    for dairyID in AllergenExclusions.effectiveExcludedIngredientIDs(
      selectedGroups: ["milk"], individualExclusions: [7])
    {
      XCTAssertTrue(excluded.contains(dairyID), "The effective allergen set passes through.")
    }
    for dietID in HealthProfile.default.dietaryExcludedIngredientIds {
      XCTAssertTrue(excluded.contains(dietID), "Vegan diet exclusions are hard too.")
    }
    XCTAssertEqual(input.constraints.requiredDietClass, "vegan")
  }

  func testClassicProfileHasNoRequiredDiet() {
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [], ingredientsByRecipe: [:], lots: [], profile: makeProfile())
    XCTAssertNil(input.constraints.requiredDietClass)
  }

  func testRecipeDietClassMirrorsTheProfileTagMapping() {
    XCTAssertEqual(
      WeeklyPlanInputAdapter.dietClass(for: makeRecipe(1, tags: RecipeTags.vegan.rawValue)),
      "vegan")
    XCTAssertEqual(
      WeeklyPlanInputAdapter.dietClass(for: makeRecipe(2, tags: RecipeTags.vegetarian.rawValue)),
      "vegetarian")
    XCTAssertEqual(
      WeeklyPlanInputAdapter.dietClass(for: makeRecipe(3, tags: RecipeTags.lowCarb.rawValue)),
      "keto")
    XCTAssertNil(WeeklyPlanInputAdapter.dietClass(for: makeRecipe(4)))
  }

  // MARK: - Needs

  func testNeedsMapRequirednessAndGramsPerServing() {
    let recipe = makeRecipe(10)
    let rows = [
      makeRow(10, 1, required: true, grams: 120),
      makeRow(10, 2, required: false, grams: 15),
    ]
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [recipe], ingredientsByRecipe: [10: rows], lots: [], profile: makeProfile())

    let planned = input.recipes.first
    XCTAssertEqual(planned?.needs.count, 2)
    XCTAssertEqual(planned?.needs.first?.isOptional, false)
    XCTAssertEqual(planned?.needs.first?.gramsPerServing, 120)
    XCTAssertEqual(planned?.needs.last?.isOptional, true)
    XCTAssertEqual(planned?.needs.first?.substitutes, [], "The schema stores no substitutes.")
  }

  func testRecipesWithoutPersistedIDsAreSkipped() {
    var recipe = makeRecipe(0)
    recipe.id = nil
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [recipe], ingredientsByRecipe: [:], lots: [], profile: makeProfile())
    XCTAssertTrue(input.recipes.isEmpty)
  }

  func testConstraintsPassThroughAndSlotsStayInTheGuaranteedDomain() {
    let input = WeeklyPlanInputAdapter.makeInput(
      recipes: [], ingredientsByRecipe: [:], lots: [], profile: makeProfile(),
      servingsPerMeal: 4, maxCookTimeMinutes: 45)
    XCTAssertEqual(input.constraints.servingsPerMeal, 4)
    XCTAssertEqual(input.constraints.maxCookTimeMinutes, 45)
    XCTAssertLessThanOrEqual(input.slots.count, 3, "Default slots stay in the exact domain.")
  }
}
