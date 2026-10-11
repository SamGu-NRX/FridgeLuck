import XCTest
import GRDB
@testable import RecipeQuantityReviewCheck

/// Regression tests for the refusal paths the adversarial review added to the core:
/// a substituted row whose substitute read failed must never fall back to the original's
/// energy, a non-finite read is an unavailable read, substitute fields must be complete,
/// and a missing recipe row refuses as recipeNotFound.
final class RecipeQuantityReviewRefusalRegressionTests: XCTestCase {
  private func row(
    originalCalories: Double? = 100,
    replacementCalories: Double? = nil,
    ratio: Double? = 1.0
  ) -> RecipeQuantityReviewSnapshot.Row {
    RecipeQuantityReviewSnapshot.Row(
      ingredientID: 1,
      originalName: "chicken",
      replacementName: ratio != nil ? "tofu" : nil,
      isRequired: true,
      baseOriginalGrams: 200,
      substituteRatio: ratio,
      originalNutrition: originalCalories.map {
        QuantityReviewNutrition(calories: $0, protein: 10, carbs: 0, fat: 1)
      },
      replacementNutrition: replacementCalories.map {
        QuantityReviewNutrition(calories: $0, protein: 8, carbs: 0, fat: 2)
      })
  }

  // The substituted row's contribution is the substitute's calories. When the substitute's
  // read is unavailable, the total refuses — falling back to the original's energy would
  // count food that is not in the plan.
  func testSubstitutedRowWithUnavailableSubstituteReadRefusesTotal() {
    let rows = [row(originalCalories: 330, replacementCalories: nil, ratio: 0.8)]
    XCTAssertNil(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1.0),
      "a substituted row with no substitute nutrition must refuse the total, not use the original's")
    XCTAssertNil(
      RecipeQuantityReviewCalculator.optionalTotalCalories(rows: rows, servingFactor: 1.0))
  }

  // The mirror case: the same row with the substitute read available sums the substitute's
  // stored energy, never the original's.
  func testSubstitutedRowUsesSubstituteCaloriesWhenAvailable() {
    let rows = [row(originalCalories: 330, replacementCalories: 121.6, ratio: 0.8)]
    XCTAssertEqual(
      RecipeQuantityReviewCalculator.requiredTotalCalories(rows: rows, servingFactor: 1.0) ?? -1,
      121.6, accuracy: 0.0001)
  }

  // A non-finite read (NaN or infinite) is an unavailable read: the snapshot carries nil
  // and totals refuse rather than propagate a poisoned value.
  func testNonFiniteNutritionReadIsUnavailable() async {
    let reader = NonFiniteNutritionReader()
    do {
      let snapshot = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 10)
      XCTAssertEqual(snapshot.rows.count, 1)
      XCTAssertNil(
        snapshot.rows[0].originalNutrition,
        "a NaN nutrition read must show as unavailable, not enter the snapshot")
      XCTAssertNil(
        RecipeQuantityReviewCalculator.requiredTotalCalories(
          rows: snapshot.rows, servingFactor: 1.0))
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  // Substitute fields must be present together — id, name, and ratio — or not at all.
  // A partial substitute would render a name with no amounts or scale an unknown target.
  func testPartialSubstituteFieldsRefuse() {
    let base = QuantityReviewJoinedRow(
      ingredientID: 1, recipeID: 10, isRequired: true, quantityGrams: 200,
      displayName: "chicken")
    let partials: [(Int64?, String?, Double?)] = [
      (4, nil, nil), (nil, "tofu", nil), (nil, nil, 0.8),
      (4, nil, 0.8), (nil, "tofu", 0.8), (4, "tofu", nil),
    ]
    for (id, name, ratio) in partials {
      let partial = QuantityReviewJoinedRow(
        ingredientID: 1, recipeID: 10, isRequired: true, quantityGrams: 200,
        displayName: "chicken", substituteID: id, substituteName: name, substituteRatio: ratio)
      XCTAssertThrowsError(
        try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: [partial]),
        "expected refusal for substitute fields (id: \\(id as Any), name: \\(name as Any), ratio: \\(ratio as Any))"
      ) { error in
        guard case RecipeQuantityReviewFailure.inconsistentRows = error else {
          return XCTFail("expected inconsistentRows, got \\(error)")
        }
      }
    }
    // The complete and empty shapes both pass.
    let complete = QuantityReviewJoinedRow(
      ingredientID: 1, recipeID: 10, isRequired: true, quantityGrams: 200,
      displayName: "chicken", substituteID: 4, substituteName: "tofu", substituteRatio: 0.8)
    XCTAssertNoThrow(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: [complete]))
    XCTAssertNoThrow(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: [base]))
  }

  // A reader that returns rows but no recipe row must refuse with recipeNotFound — the
  // missing-denominator case, distinct from noIngredientRows.
  func testMissingRecipeRowRefusesWithRecipeNotFound() async {
    let reader = RowsWithoutRecipeReader()
    do {
      _ = try await RecipeQuantityReviewSession(read: reader).load(recipeID: 10)
      XCTFail("expected recipeNotFound")
    } catch let failure as RecipeQuantityReviewFailure {
      XCTAssertEqual(failure, .recipeNotFound(10))
    } catch {
      XCTFail("unexpected error \\(error)")
    }
  }
}

/// Serves valid rows and a valid denominator, but reports every nutrition read as NaN —
/// the shape a corrupted nutrition row would produce.
private struct NonFiniteNutritionReader: RecipeQuantityReviewReading {
  func fetchRecipeServings(id: Int64) throws -> Int? { 4 }
  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    [QuantityReviewJoinedRow(
      ingredientID: 1, recipeID: recipeID, isRequired: true, quantityGrams: 200,
      displayName: "chicken")]
  }
  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    QuantityReviewNutrition(calories: .nan, protein: 31, carbs: 0, fat: 3.6)
  }
  func referencePerServingCalories(recipeID: Int64) throws -> Double? { nil }
}

/// Serves rows but no recipe row — the missing-denominator case.
private struct RowsWithoutRecipeReader: RecipeQuantityReviewReading {
  func fetchRecipeServings(id: Int64) throws -> Int? { nil }
  func joinedRows(recipeID: Int64) throws -> [QuantityReviewJoinedRow] {
    [QuantityReviewJoinedRow(
      ingredientID: 1, recipeID: recipeID, isRequired: true, quantityGrams: 200,
      displayName: "chicken")]
  }
  func nutrition(ingredientID: Int64, grams: Double) throws -> QuantityReviewNutrition {
    QuantityReviewNutrition(calories: 330, protein: 31, carbs: 0, fat: 3.6)
  }
  func referencePerServingCalories(recipeID: Int64) throws -> Double? { nil }
}
