import XCTest
@testable import RecipeQuantityReviewCheck

/// Identity and usability rules: a single recipe identity is established before the
/// serving denominator is fetched, and unusable rows refuse the load outright.
final class RecipeQuantityReviewValidationTests: XCTestCase {
  private func joined(
    ingredientID: Int64 = 1,
    recipeID: Int64 = 10,
    grams: Double = 100,
    ratio: Double? = nil,
    substituteName: String? = nil
  ) -> QuantityReviewJoinedRow {
    QuantityReviewJoinedRow(
      ingredientID: ingredientID,
      recipeID: recipeID,
      isRequired: true,
      quantityGrams: grams,
      displayName: "Chicken",
      substituteID: ratio != nil ? 2 : nil,
      substituteName: substituteName,
      substituteRatio: ratio)
  }

  func testNilRecipeIDRefuses() {
    XCTAssertThrowsError(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: nil, rows: [joined()])
    ) { error in
      XCTAssertEqual(error as? RecipeQuantityReviewFailure, .missingRecipeID)
    }
  }

  func testEmptyRowsRefuse() {
    XCTAssertThrowsError(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: [])
    ) { error in
      XCTAssertEqual(error as? RecipeQuantityReviewFailure, .noIngredientRows)
    }
  }

  func testForeignRowRefusesBeforeDenominatorFetch() {
    let rows = [joined(ingredientID: 1, recipeID: 10), joined(ingredientID: 2, recipeID: 11)]
    XCTAssertThrowsError(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: rows)
    ) { error in
      guard case RecipeQuantityReviewFailure.inconsistentRows = error else {
        return XCTFail("expected inconsistentRows")
      }
    }
  }

  func testDuplicateIngredientRefuses() {
    let rows = [joined(ingredientID: 1, recipeID: 10), joined(ingredientID: 1, recipeID: 10)]
    XCTAssertThrowsError(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: rows)
    ) { error in
      guard case RecipeQuantityReviewFailure.inconsistentRows = error else {
        return XCTFail("expected inconsistentRows")
      }
    }
  }

  func testUnusableNumbersRefuse() {
    let cases: [(String, QuantityReviewJoinedRow)] = [
      ("NaN grams", joined(grams: .nan)),
      ("infinite grams", joined(grams: .infinity)),
      ("negative grams", joined(grams: -1)),
      ("zero ratio", joined(ratio: 0, substituteName: "Tofu")),
      ("negative ratio", joined(ratio: -0.5, substituteName: "Tofu")),
      ("NaN ratio", joined(ratio: .nan, substituteName: "Tofu")),
      ("ratio without name", joined(ratio: 0.8, substituteName: nil)),
    ]
    for (label, row) in cases {
      XCTAssertThrowsError(
        try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: [row]),
        label
      ) { error in
        guard case RecipeQuantityReviewFailure.inconsistentRows = error else {
          return XCTFail("\(label): expected inconsistentRows")
        }
      }
    }
  }

  func testValidRowsPass() {
    let rows = [
      joined(ingredientID: 1, recipeID: 10, grams: 200),
      joined(ingredientID: 2, recipeID: 10, grams: 50, ratio: 0.8, substituteName: "Tofu"),
    ]
    XCTAssertNoThrow(
      try RecipeQuantityReviewValidation.validateJoinedRows(recipeID: 10, rows: rows))
  }

  func testZeroAndNegativeDenominatorsRefuse() {
    for bad in [0, -1] {
      XCTAssertThrowsError(
        try RecipeQuantityReviewValidation.validateRecipeServings(bad)
      ) { error in
        XCTAssertEqual(
          error as? RecipeQuantityReviewFailure, .invalidRecipeServings(bad))
      }
    }
    XCTAssertNoThrow(try RecipeQuantityReviewValidation.validateRecipeServings(1))
    XCTAssertNoThrow(try RecipeQuantityReviewValidation.validateRecipeServings(6))
  }
}
