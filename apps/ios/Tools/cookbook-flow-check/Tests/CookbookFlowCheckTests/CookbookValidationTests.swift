import XCTest

@testable import CookbookFlowCheck
@testable import FLFeatureLogic

/// Pure policy checks: what a cookbook draft must satisfy before any write.
/// These run first because every persistence guarantee below assumes the gate.
final class CookbookValidationTests: XCTestCase {
  private func draft(
    title: String = "Soup",
    timeMinutes: Int = 20,
    servings: Int = 2,
    instructions: String = "Boil. Season. Serve.",
    lines: [CookbookIngredientLine] = [CookbookIngredientLine(ingredientId: 1, grams: 100, isRequired: true)]
  ) -> CookbookRecipeDraft {
    CookbookRecipeDraft(
      title: title, timeMinutes: timeMinutes, servings: servings,
      instructions: instructions, tagMask: 0, ingredientLines: lines)
  }

  func testValidDraftHasNoProblems() {
    XCTAssertTrue(CookbookRecipePolicy.validate(draft()).isEmpty)
    XCTAssertTrue(CookbookRecipePolicy.isSavable(draft()))
  }

  func testFinitePositiveQuantitiesAccepted() {
    for grams in [0.5, 1.0, 120.5, 5000.0] {
      let d = draft(lines: [CookbookIngredientLine(ingredientId: 1, grams: grams, isRequired: true)])
      XCTAssertTrue(
        CookbookRecipePolicy.validate(d).isEmpty, "grams \(grams) should be savable")
    }
  }

  func testNonFiniteQuantitiesRejected() {
    for grams in [Double.nan, Double.infinity, -Double.infinity] {
      let d = draft(lines: [CookbookIngredientLine(ingredientId: 1, grams: grams, isRequired: true)])
      XCTAssertEqual(
        CookbookRecipePolicy.validate(d), [.invalidQuantity(ingredientId: 1)],
        "grams \(grams) must be rejected")
    }
  }

  func testNonPositiveQuantitiesRejected() {
    for grams in [0.0, -0.001, -250.0] {
      let d = draft(lines: [CookbookIngredientLine(ingredientId: 1, grams: grams, isRequired: true)])
      XCTAssertEqual(
        CookbookRecipePolicy.validate(d), [.invalidQuantity(ingredientId: 1)],
        "grams \(grams) must be rejected, not clamped")
    }
  }

  func testZeroServingsAndZeroTimeRejected() {
    XCTAssertEqual(CookbookRecipePolicy.validate(draft(servings: 0)), [.invalidServings(0)])
    XCTAssertEqual(CookbookRecipePolicy.validate(draft(timeMinutes: 0)), [.invalidTimeMinutes(0)])
  }

  func testWhitespaceTitleRejected() {
    XCTAssertEqual(CookbookRecipePolicy.validate(draft(title: "   \n")), [.emptyTitle])
  }

  func testOverlongTitleRejected() {
    let long = String(repeating: "a", count: CookbookRecipePolicy.maxTitleLength + 1)
    XCTAssertEqual(
      CookbookRecipePolicy.validate(draft(title: long)),
      [.titleTooLong(limit: CookbookRecipePolicy.maxTitleLength)])
  }

  func testExactTitleLimitAccepted() {
    let exact = String(repeating: "a", count: CookbookRecipePolicy.maxTitleLength)
    XCTAssertTrue(CookbookRecipePolicy.validate(draft(title: exact)).isEmpty)
  }

  func testWhitespaceOnlyInstructionsRejected() {
    XCTAssertEqual(CookbookRecipePolicy.validate(draft(instructions: "  ")), [.emptyInstructions])
  }

  func testNoIngredientLinesRejected() {
    XCTAssertEqual(CookbookRecipePolicy.validate(draft(lines: [])), [.noIngredientLines])
  }

  func testDuplicateIngredientRejected() {
    let d = draft(lines: [
      CookbookIngredientLine(ingredientId: 4, grams: 50, isRequired: true),
      CookbookIngredientLine(ingredientId: 4, grams: 30, isRequired: false),
    ])
    XCTAssertEqual(CookbookRecipePolicy.validate(d), [.duplicateIngredient(ingredientId: 4)])
  }

  func testAllProblemsReportedTogether() {
    let d = CookbookRecipeDraft(
      title: "", timeMinutes: 0, servings: 0, instructions: "", tagMask: 0,
      ingredientLines: [CookbookIngredientLine(ingredientId: 1, grams: .nan, isRequired: true)])
    XCTAssertEqual(
      CookbookRecipePolicy.validate(d),
      [.emptyTitle, .invalidTimeMinutes(0), .invalidServings(0), .emptyInstructions, .invalidQuantity(ingredientId: 1)])
  }
}
