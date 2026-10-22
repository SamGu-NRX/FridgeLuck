import XCTest

@testable import FridgeLuck

final class FridgeLuckPolishTests: XCTestCase {
  func testIngredientPickerUsesHumanSubtitleAndAccessibleName() {
    let ingredient = ingredient(
      name: "honey",
      category: "sweetener_baking",
      description: "Honey is a USDA-listed ingredient; nutrition is per 100 g as reported by FoodData Central (Survey (FNDDS))."
    )

    XCTAssertEqual(
      IngredientPickerPresentation.subtitle(for: ingredient),
      "Sweetener or baking · nutrition per 100 g"
    )
    XCTAssertFalse(
      IngredientPickerPresentation.accessibilityLabel(for: ingredient).contains("USDA-listed")
    )
  }

  func testIngredientPickerCollapsesRawDuplicateButKeepsDistinctFood() {
    let spinach = ingredient(name: "Spinach", calories: 23, protein: 2.86, carbs: 3.63, fat: 0.39)
    let rawSpinach = ingredient(name: "Spinach (Raw)", calories: 23, protein: 2.86, carbs: 3.63, fat: 0.39)
    let frozenSpinach = ingredient(name: "Spinach (Frozen, Cooked)", calories: 34, protein: 4.01, carbs: 4.8, fat: 0.87)

    let result = IngredientPickerPresentation.deduplicate([spinach, rawSpinach, frozenSpinach])

    XCTAssertEqual(result.map(\.name), ["Spinach", "Spinach (Frozen, Cooked)"])
  }

  func testManualGroceryItemIsNotPresentedAsScanConfidence() {
    let item = GroceryPendingItem(
      ingredientId: 1,
      ingredientName: "Honey",
      quantityGrams: 20,
      storageLocation: .pantry,
      confidenceScore: 1,
      source: .manual
    )

    XCTAssertEqual(GroceryReviewPresentation.confidence(for: item).text, "Added by you")
  }

  func testRecipeMacroDisplaysUseOneRoundingRule() {
    XCTAssertEqual(MacroDisplayFormatting.rounded(286.5), 287)
    XCTAssertEqual(MacroDisplayFormatting.rounded(26.5), 27)
    XCTAssertEqual(MacroDisplayFormatting.rounded(18.5), 19)
  }

  func testRecipePickerCountMatchesSixVisibleRows() {
    XCTAssertEqual(RecipePickerPresentation.visibleSuggestionCount(total: 8), 6)
    XCTAssertEqual(RecipePickerPresentation.visibleSuggestionCount(total: 6), 6)
    XCTAssertEqual(RecipePickerPresentation.visibleSuggestionCount(total: 1), 1)
  }

  private func ingredient(
    name: String,
    calories: Double = 100,
    protein: Double = 10,
    carbs: Double = 10,
    fat: Double = 5,
    category: String? = "protein",
    description: String? = nil
  ) -> Ingredient {
    Ingredient(
      id: nil,
      name: name,
      calories: calories,
      protein: protein,
      carbs: carbs,
      fat: fat,
      fiber: 1,
      sugar: 1,
      sodium: 0.1,
      typicalUnit: nil,
      storageTip: nil,
      pairsWith: nil,
      notes: nil,
      description: description,
      categoryLabel: category,
      spriteGroup: nil,
      spriteKey: nil
    )
  }
}
