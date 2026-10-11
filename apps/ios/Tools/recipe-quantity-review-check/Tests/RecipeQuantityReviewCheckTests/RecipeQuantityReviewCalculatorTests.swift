import XCTest
@testable import RecipeQuantityReviewCheck

/// The calculator's two invariants: the serving factor is applied exactly once, and the
/// substitute's ratio is applied exactly once on top of it. Calories always scale the
/// stored energy value — never a 4/4/9 reconstruction.
final class RecipeQuantityReviewCalculatorTests: XCTestCase {
  private func row(
    baseGrams: Double = 100,
    isRequired: Bool = true,
    ratio: Double? = nil,
    originalCalories: Double? = 400,
    replacementCalories: Double? = nil
  ) -> RecipeQuantityReviewSnapshot.Row {
    RecipeQuantityReviewSnapshot.Row(
      ingredientID: 1,
      originalName: "Chicken",
      replacementName: ratio != nil ? "Tofu" : nil,
      isRequired: isRequired,
      baseOriginalGrams: baseGrams,
      substituteRatio: ratio,
      originalNutrition: originalCalories.map { QuantityReviewNutrition(calories: $0, protein: 0, carbs: 0, fat: 0) },
      replacementNutrition: replacementCalories.map { QuantityReviewNutrition(calories: $0, protein: 0, carbs: 0, fat: 0) })
  }

  func testServingFactorScalesBaseAmountsExactlyOnce() throws {
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 8, recipeServings: 4)
    XCTAssertEqual(factor, 2, accuracy: 0.0001)

    let plain = RecipeQuantityReviewCalculator.amounts(row: row(baseGrams: 100), servingFactor: factor)
    XCTAssertEqual(plain.originalGrams, 200, accuracy: 0.0001)
    XCTAssertNil(plain.replacementGrams)

    // The factor applied twice would give 400; exactly once gives 200.
    let halved = RecipeQuantityReviewCalculator.amounts(row: row(baseGrams: 100), servingFactor: 0.5)
    XCTAssertEqual(halved.originalGrams, 50, accuracy: 0.0001)
  }

  func testSubstituteRatioAppliedExactlyOnceOnScaledAmount() throws {
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 6, recipeServings: 4)
    XCTAssertEqual(factor, 1.5, accuracy: 0.0001)

    // 100 g base, ratio 1.5, factor 1.5 → 225 (not 337.5 or 506.25).
    let amounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 100, ratio: 1.5, originalCalories: 400, replacementCalories: 300),
      servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 150, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementGrams ?? -1, 225, accuracy: 0.0001)
    XCTAssertEqual(amounts.originalCalories ?? 0, 600, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementCalories ?? 0, 450, accuracy: 0.0001)
  }

  func testFractionalServingsProduceFractionalFactors() throws {
    let factor = try RecipeQuantityReviewCalculator.servingFactor(
      selectedServings: 2.5, recipeServings: 4)
    XCTAssertEqual(factor, 0.625, accuracy: 0.0001)

    let amounts = RecipeQuantityReviewCalculator.amounts(
      row: row(baseGrams: 200, ratio: 0.8), servingFactor: factor)
    XCTAssertEqual(amounts.originalGrams, 125, accuracy: 0.0001)
    XCTAssertEqual(amounts.replacementGrams ?? -1, 100, accuracy: 0.0001)
  }

  func testInvalidSelectedServingsThrow() {
    for bad in [0.0, -1.0, .nan, .infinity] {
      XCTAssertThrowsError(
        try RecipeQuantityReviewCalculator.servingFactor(
          selectedServings: bad, recipeServings: 4),
        "selectedServings \(bad) must be refused"
      ) { error in
        guard case RecipeQuantityReviewFailure.inconsistentRows = error else {
          return XCTFail("expected inconsistentRows for \(bad)")
        }
      }
    }
  }

  func testInvalidRecipeServingsThrow() {
    XCTAssertThrowsError(
      try RecipeQuantityReviewCalculator.servingFactor(selectedServings: 2, recipeServings: 0)
    ) { error in
      guard case RecipeQuantityReviewFailure.invalidRecipeServings = error else {
        return XCTFail("expected invalidRecipeServings")
      }
    }
  }

  func testRequiredAndOptionalTotalsStaySeparate() throws {
    let rows = [
      row(baseGrams: 100, isRequired: true, originalCalories: 400),
      row(baseGrams: 100, isRequired: false, originalCalories: 500),
    ]

    let requiredAt1 = RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1)
    let optionalAt1 = RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 1)
    XCTAssertEqual(requiredAt1 ?? 0, 400, accuracy: 0.0001)
    XCTAssertEqual(optionalAt1 ?? 0, 500, accuracy: 0.0001)

    let requiredAt2 = RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 2)
    let optionalAt2 = RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 2)
    XCTAssertEqual(requiredAt2 ?? 0, 800, accuracy: 0.0001)
    XCTAssertEqual(optionalAt2 ?? 0, 1000, accuracy: 0.0001)
  }

  func testSubstitutedRowTotalUsesReplacementNutrition() throws {
    let rows = [
      row(baseGrams: 100, isRequired: true, ratio: 1.0, originalCalories: 400, replacementCalories: 300),
    ]
    let total = RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1)
    XCTAssertEqual(total ?? 0, 300, accuracy: 0.0001)
  }

  func testTotalsRefuseWhenRequiredNutritionMissing() {
    let rows = [
      row(baseGrams: 100, isRequired: true, originalCalories: nil),
      row(baseGrams: 100, isRequired: false, originalCalories: 500),
    ]
    // A hole is never filled with a zero: the required total is nil, the optional one is real.
    XCTAssertNil(RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1))
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 1) ?? 0,
      500, accuracy: 0.0001)
  }

  func testStoredEnergyScalesLinearlyNotFromMacros() throws {
    // Stored calories 900 with zero macros: a 4/4/9 reconstruction would show 0 kcal.
    // The scaled display must follow the stored value.
    let nutrition = QuantityReviewNutrition(calories: 900, protein: 0, carbs: 0, fat: 0)
    let snapshotRow = RecipeQuantityReviewSnapshot.Row(
      ingredientID: 1, originalName: "Oil", replacementName: nil, isRequired: true,
      baseOriginalGrams: 100, substituteRatio: nil,
      originalNutrition: nutrition, replacementNutrition: nil)
    let amounts = RecipeQuantityReviewCalculator.amounts(
      row: snapshotRow,
      servingFactor: try RecipeQuantityReviewCalculator.servingFactor(
        selectedServings: 2, recipeServings: 4))
    XCTAssertEqual(amounts.originalCalories ?? 0, 450, accuracy: 0.0001)
  }

  func testDefaultSelectedServingsPrefersExactThenBelow() {
    XCTAssertEqual(RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: 4), 4)
    XCTAssertEqual(RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: 7), 6)
    XCTAssertEqual(RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: 3), 3)
    XCTAssertEqual(RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: 13), 12)
    XCTAssertNil(RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: 0))
    XCTAssertNil(RecipeQuantityReviewCalculator.defaultSelectedServings(recipeServings: -2))
  }

  func testSnapshotImmutabilityAcrossSelections() throws {
    let snapshotRow = row(baseGrams: 200, ratio: 0.8, originalCalories: 330, replacementCalories: 200)
    let before = snapshotRow

    // Deriving display amounts for several selections must not disturb the base.
    for servings in RecipeQuantityReviewCalculator.servingOptions {
      let factor = try RecipeQuantityReviewCalculator.servingFactor(
        selectedServings: servings, recipeServings: 4)
      _ = RecipeQuantityReviewCalculator.amounts(row: snapshotRow, servingFactor: factor)
    }
    XCTAssertEqual(snapshotRow, before)
  }
}
