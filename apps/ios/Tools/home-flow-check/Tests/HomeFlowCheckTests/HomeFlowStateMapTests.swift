import XCTest
@testable import HomeFlowCheck

// Tests for the pure Home flow state map (FL4).
//
// Every test drives the REAL production map (`HomeFlowStateMap`) with literal
// expected outputs. State precedence: error > cooking > returning > emptyNew >
// partlyStocked. Learning progress is not an input type anywhere in these tests —
// the map's input struct has no tutorial field at all, which is the compile-time
// guarantee the spec asks for.
final class HomeFlowStateMapTests: XCTestCase {
  // MARK: - Builders

  /// A recommendation the map can hand out as a cook action.
  private func makeRecommendation(
    id: Int64 = 42,
    name: String = "Weeknight Fried Rice"
  ) -> HomeRecommendation {
    HomeRecommendation(
      recipeID: id,
      recipeName: name,
      explanation: "Uses what you have.",
      cookTimeMinutes: 20,
      matchLabel: "Perfect match",
      badgeLabel: "Perfect match",
      ingredientIDs: [1, 2, 3]
    )
  }

  /// An inventory item. `daysUntilExpiry` stays nil unless a caller asks for a
  /// known-expiry item — mirroring the domain, where unknown expiry is nil.
  private func makeItem(daysUntilExpiry: Int? = nil) -> InventoryActiveItem {
    InventoryActiveItem(
      ingredientId: 7,
      ingredientName: "Eggs",
      storageLocation: .fridge,
      totalRemainingGrams: 300,
      averageConfidenceScore: 0.9,
      earliestExpiresAt: daysUntilExpiry.map { offset in
        Calendar.current.date(byAdding: .day, value: offset, to: Date())!
      },
      daysUntilExpiry: daysUntilExpiry,
      lastUpdatedAt: Date(timeIntervalSince1970: 0),
      lotCount: 1,
      mostRecentSource: .manual,
      hasEstimatedQuantity: false
    )
  }

  private func makeInputs(
    hasOnboarded: Bool = true,
    items: [InventoryActiveItem] = [],
    totalMealsCooked: Int = 0,
    healthProfile: HealthProfile?? = nil,
    primary: HomeRecommendation?? = nil
  ) -> HomeFlowInputs {
    HomeFlowInputs(
      hasCompletedOnboarding: hasOnboarded,
      inventoryItems: items,
      useSoon: [],
      totalMealsCooked: totalMealsCooked,
      mealsCookedLast7Days: 0,
      latestJournalEntry: nil,
      todayMacros: MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0),
      currentStreak: 0,
      weekActivity: Array(repeating: false, count: 7),
      healthProfile: healthProfile ?? nil,
      primaryRecommendation: primary ?? nil,
      fallbackOptions: []
    )
  }

  /// A real profile value, built with the production memberwise initializer.
  private func makeProfile() -> HealthProfile {
    HealthProfile(
      displayName: "Sam",
      age: nil,
      goal: .general,
      dailyCalories: nil,
      proteinPct: 0.25,
      carbsPct: 0.45,
      fatPct: 0.30,
      dietaryRestrictions: "[]",
      allergenIngredientIds: "[]",
      updatedAt: nil
    )
  }

  // MARK: - State resolution

  func testNilInputsResolveToErrorState() {
    let state = HomeFlowStateMap.state(inputs: nil, cookContext: nil)
    XCTAssertEqual(state, .error)
  }

  func testErrorOutranksCookingWhenInputsAreStillNil() {
    let state = HomeFlowStateMap.state(
      inputs: nil,
      cookContext: HomeCookContext(recipeName: "Chili")
    )
    XCTAssertEqual(state, .error)
  }

  func testCookingOverridesReturningState() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(totalMealsCooked: 12),
      cookContext: HomeCookContext(recipeName: "Chili")
    )
    XCTAssertEqual(state, .cooking(HomeCookContext(recipeName: "Chili")))
  }

  func testCookingOverridesPartlyStockedState() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(items: [makeItem()]),
      cookContext: HomeCookContext(recipeName: "Chili")
    )
    XCTAssertEqual(state, .cooking(HomeCookContext(recipeName: "Chili")))
  }

  func testCookingContextCarriesNilRecipeNameWhenUnsurfaced() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(),
      cookContext: HomeCookContext(recipeName: nil)
    )
    XCTAssertEqual(state, .cooking(HomeCookContext(recipeName: nil)))
  }

  func testOneMealCookedMeansReturningEvenWithEmptyFridge() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(items: [], totalMealsCooked: 1),
      cookContext: nil
    )
    XCTAssertEqual(state, .returning)
  }

  func testManyMealsCookedWithFullFridgeStillResolvesToReturning() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(items: [makeItem(daysUntilExpiry: 2)], totalMealsCooked: 40),
      cookContext: nil
    )
    XCTAssertEqual(state, .returning)
  }

  func testOnboardedEmptyKitchenWithNoMealsIsEmptyNew() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(hasOnboarded: true, items: []),
      cookContext: nil
    )
    XCTAssertEqual(state, .emptyNew)
  }

  func testOnboardedWithStockAndNoMealsIsPartlyStocked() {
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(hasOnboarded: true, items: [makeItem(daysUntilExpiry: nil)]),
      cookContext: nil
    )
    XCTAssertEqual(state, .partlyStocked)
  }

  func testItemsWithUnknownExpiryStillProducePartlyStocked() {
    // Unknown expiry is nil, never zero — the item still counts as stock.
    let item = makeItem(daysUntilExpiry: nil)
    XCTAssertNil(item.daysUntilExpiry)
    let state = HomeFlowStateMap.state(
      inputs: makeInputs(items: [item]),
      cookContext: nil
    )
    XCTAssertEqual(state, .partlyStocked)
  }

  func testSameInputsResolveToSameState() {
    let a = makeInputs(items: [makeItem()], totalMealsCooked: 3)
    let b = makeInputs(items: [makeItem()], totalMealsCooked: 3)
    XCTAssertEqual(a, b)
    XCTAssertEqual(
      HomeFlowStateMap.state(inputs: a, cookContext: nil),
      HomeFlowStateMap.state(inputs: b, cookContext: nil)
    )
  }

  // MARK: - Primary actions

  func testErrorStateLeadsWithRetry() {
    let action = HomeFlowStateMap.primaryAction(for: .error, inputs: nil)
    XCTAssertEqual(action, .retry)
  }

  func testCookingStateLeadsWithResumeCook() {
    let action = HomeFlowStateMap.primaryAction(
      for: .cooking(HomeCookContext(recipeName: "Chili")),
      inputs: makeInputs()
    )
    XCTAssertEqual(action, .resumeCook)
  }

  func testEmptyNewWithoutProfileLeadsWithCompleteProfile() {
    let action = HomeFlowStateMap.primaryAction(
      for: .emptyNew,
      inputs: makeInputs(healthProfile: .some(nil))
    )
    XCTAssertEqual(action, .completeProfile)
  }

  func testEmptyNewWithProfileLeadsWithScanKitchen() {
    let action = HomeFlowStateMap.primaryAction(
      for: .emptyNew,
      inputs: makeInputs(healthProfile: .some(makeProfile()))
    )
    XCTAssertEqual(action, .scanKitchen)
  }

  func testPartlyStockedWithRecommendationLeadsWithCook() {
    let recipe = makeRecommendation()
    let action = HomeFlowStateMap.primaryAction(
      for: .partlyStocked,
      inputs: makeInputs(primary: .some(recipe))
    )
    XCTAssertEqual(action, .cook(recipe))
  }

  func testPartlyStockedWithoutRecommendationLeadsWithScanKitchen() {
    let action = HomeFlowStateMap.primaryAction(
      for: .partlyStocked,
      inputs: makeInputs(primary: .some(nil))
    )
    XCTAssertEqual(action, .scanKitchen)
  }

  func testReturningWithEmptyFridgeLeadsWithRestock() {
    let action = HomeFlowStateMap.primaryAction(
      for: .returning,
      inputs: makeInputs(items: [], totalMealsCooked: 5)
    )
    XCTAssertEqual(action, .restock)
  }

  func testReturningWithRecommendationLeadsWithCook() {
    let recipe = makeRecommendation(id: 9, name: "Shakshuka")
    let action = HomeFlowStateMap.primaryAction(
      for: .returning,
      inputs: makeInputs(
        items: [makeItem(daysUntilExpiry: 1)],
        totalMealsCooked: 5,
        primary: .some(recipe)
      )
    )
    XCTAssertEqual(action, .cook(recipe))
  }

  func testReturningWithStockButNoRecommendationLeadsWithScanKitchen() {
    let action = HomeFlowStateMap.primaryAction(
      for: .returning,
      inputs: makeInputs(
        items: [makeItem()],
        totalMealsCooked: 5,
        primary: .some(nil)
      )
    )
    XCTAssertEqual(action, .scanKitchen)
  }

  func testEveryStateResolvesToAPrimaryAction() {
    // Totality: the map's switch covers every case. A new HomeFlowState case must
    // break the production switch at compile time — this test pins the set of
    // cases the flow currently defines.
    let states: [HomeFlowState] = [
      .emptyNew,
      .partlyStocked,
      .cooking(HomeCookContext(recipeName: "Chili")),
      .cooking(nil),
      .returning,
      .error,
    ]
    for state in states {
      _ = HomeFlowStateMap.primaryAction(for: state, inputs: makeInputs())
    }
  }

  // MARK: - Transition seam: cook context arriving and leaving

  func testCookContextArrivingChangesStateWithoutChangingInputs() {
    let inputs = makeInputs(items: [makeItem()], primary: .some(makeRecommendation()))
    let before = HomeFlowStateMap.state(inputs: inputs, cookContext: nil)
    XCTAssertEqual(before, .partlyStocked)

    let during = HomeFlowStateMap.state(
      inputs: inputs,
      cookContext: HomeCookContext(recipeName: "Weeknight Fried Rice")
    )
    XCTAssertEqual(during, .cooking(HomeCookContext(recipeName: "Weeknight Fried Rice")))

    let after = HomeFlowStateMap.state(inputs: inputs, cookContext: nil)
    XCTAssertEqual(after, .partlyStocked)
  }

  // MARK: - Compile-time contract: no tutorial progress in the input surface

  func testInputsCarryNoTutorialField() {
    // The gate's old input was `tutorialProgress.isComplete`. The flow's inputs
    // must never reintroduce tutorial progress: the state map is a pure function
    // of repository outputs. This inspects the real stored surface of
    // HomeFlowInputs, so adding a tutorial-shaped field breaks this test.
    // (Structural by design — the behavioral guarantee is the map's purity,
    // covered by the determinism and agreement tests throughout this file.)
    let inputs = makeInputs()
    let labels = Mirror(reflecting: inputs).children.compactMap(\.label)
    XCTAssertFalse(labels.isEmpty, "HomeFlowInputs must expose its stored surface")
    for label in labels {
      XCTAssertFalse(
        label.lowercased().contains("tutorial"),
        "HomeFlowInputs must not carry tutorial progress (found field \(label))"
      )
    }
    // The same inputs always re-map to the same state.
    let state = HomeFlowStateMap.state(inputs: inputs, cookContext: nil)
    XCTAssertEqual(HomeFlowStateMap.state(inputs: inputs, cookContext: nil), state)
  }

  // MARK: - Fork projection (the shipped view's gate seam)

  /// A snapshot with only the fields the fork projection reads; the rest are
  /// presentation-neutral zeros.
  private func makeSnapshot(
    hasOnboarded: Bool,
    stockedIngredientCount: Int,
    totalMealsCooked: Int
  ) -> HomeDashboardSnapshot {
    HomeDashboardSnapshot(
      stockedIngredientCount: stockedIngredientCount,
      recipeCount: 12,
      hasOnboarded: hasOnboarded,
      currentStreak: 0,
      mealsLast7Days: 0,
      mealsLast14Days: [],
      weekdayDistribution: [],
      healthProfile: nil,
      totalMealsCooked: totalMealsCooked,
      latestJournalEntry: nil,
      useSoonSuggestions: [],
      todayCalories: 0,
      todayProtein: 0,
      todayCarbs: 0,
      todayFat: 0,
      calorieGoal: 2000,
      proteinGoal: 100,
      carbsGoal: 200,
      fatGoal: 60,
      primaryRecommendation: nil,
      fallbackOptions: []
    )
  }

  func testProjectionAgreesWithCanonicalMapForEmptyNew() {
    let snapshot = makeSnapshot(hasOnboarded: true, stockedIngredientCount: 0, totalMealsCooked: 0)
    let projected = HomeFlowStateMap.state(from: snapshot, cookContext: nil)
    let canonical = HomeFlowStateMap.state(
      inputs: makeInputs(hasOnboarded: true, items: [], totalMealsCooked: 0),
      cookContext: nil
    )
    XCTAssertEqual(projected, .emptyNew)
    XCTAssertEqual(projected, canonical)
  }

  func testProjectionAgreesWithCanonicalMapForPartlyStocked() {
    let snapshot = makeSnapshot(hasOnboarded: true, stockedIngredientCount: 2, totalMealsCooked: 0)
    let projected = HomeFlowStateMap.state(from: snapshot, cookContext: nil)
    let canonical = HomeFlowStateMap.state(
      inputs: makeInputs(
        hasOnboarded: true,
        items: [makeItem(), makeItem()],
        totalMealsCooked: 0
      ),
      cookContext: nil
    )
    XCTAssertEqual(projected, .partlyStocked)
    XCTAssertEqual(projected, canonical)
  }

  func testProjectionAgreesWithCanonicalMapForReturning() {
    let snapshot = makeSnapshot(hasOnboarded: true, stockedIngredientCount: 0, totalMealsCooked: 3)
    let projected = HomeFlowStateMap.state(from: snapshot, cookContext: nil)
    let canonical = HomeFlowStateMap.state(
      inputs: makeInputs(items: [], totalMealsCooked: 3),
      cookContext: nil
    )
    XCTAssertEqual(projected, .returning)
    XCTAssertEqual(projected, canonical)
  }

  func testProjectionHidesStockBeforeOnboarding() {
    // A not-yet-onboarded device with rows present still resolves empty-new:
    // onboarding is the entry door, matching the read model's hiding rule.
    let snapshot = makeSnapshot(hasOnboarded: false, stockedIngredientCount: 5, totalMealsCooked: 0)
    let projected = HomeFlowStateMap.state(from: snapshot, cookContext: nil)
    XCTAssertEqual(projected, .emptyNew)
  }

  func testProjectionStockEvidenceIsInventoryNotCatalog() {
    // recipeCount is a catalog statistic and never stock evidence: a populated
    // catalog with an empty pantry is empty-new, not partly-stocked.
    let snapshot = makeSnapshot(hasOnboarded: true, stockedIngredientCount: 0, totalMealsCooked: 0)
    XCTAssertEqual(snapshot.recipeCount, 12, "the fixture models a populated catalog")
    let projected = HomeFlowStateMap.state(from: snapshot, cookContext: nil)
    XCTAssertEqual(projected, .emptyNew)
  }

  func testProjectionCookingWinsOverReturningAndStock() {
    let snapshot = makeSnapshot(hasOnboarded: true, stockedIngredientCount: 4, totalMealsCooked: 3)
    let projected = HomeFlowStateMap.state(
      from: snapshot,
      cookContext: HomeCookContext(recipeName: "Chili")
    )
    XCTAssertEqual(projected, .cooking(HomeCookContext(recipeName: "Chili")))
  }

  func testProjectionNeverReportsErrorForNonNilSnapshot() {
    // Totality of the projection: every reachable shape resolves to a data state;
    // .error stays owned by the nil-snapshot branch in the view.
    let shapes: [HomeDashboardSnapshot] = [
      makeSnapshot(hasOnboarded: true, stockedIngredientCount: 0, totalMealsCooked: 0),
      makeSnapshot(hasOnboarded: true, stockedIngredientCount: 2, totalMealsCooked: 0),
      makeSnapshot(hasOnboarded: true, stockedIngredientCount: 0, totalMealsCooked: 9),
      makeSnapshot(hasOnboarded: false, stockedIngredientCount: 7, totalMealsCooked: 2),
    ]
    for snapshot in shapes {
      let state = HomeFlowStateMap.state(from: snapshot, cookContext: nil)
      XCTAssertNotEqual(state, .error)
    }
  }
}
