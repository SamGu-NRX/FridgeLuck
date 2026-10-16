import XCTest

@testable import FridgeLuck

/// The meal-photo Ingredient Breakdown shows the chosen recipe's ingredients in the amounts the
/// log counts, and says plainly when there is nothing to show.
final class MealBreakdownContentTests: XCTestCase {
  private let recipe = Recipe(
    id: 7, title: "Egg Fried Rice", timeMinutes: 15, servings: 2, instructions: "Fry.", tags: 0,
    source: .bundled)

  private func item(_ id: Int64, _ name: String, grams: Double, required: Bool = true) -> (
    ingredient: Ingredient, quantity: RecipeIngredient
  ) {
    (
      Ingredient(
        id: id, name: name, calories: 100, protein: 1, carbs: 1, fat: 1, fiber: 0, sugar: 0,
        sodium: 0),
      RecipeIngredient(
        recipeId: 7, ingredientId: id, isRequired: required, quantityGrams: grams,
        displayQuantity: "\(grams) g")
    )
  }

  private func make(
    recipe: Recipe?,
    loaded: [(ingredient: Ingredient, quantity: RecipeIngredient)]?,
    servings: Int = 1,
    portion: Double = 1
  ) -> MealBreakdownContent {
    MealBreakdownContent.make(
      recipe: recipe, loadedIngredients: loaded, servingsConsumed: servings,
      portionMultiplier: portion)
  }

  func testNoRecipeAsksForOne() {
    let content = make(recipe: nil, loaded: [item(1, "rice", grams: 300)])
    XCTAssertEqual(content, .noRecipe)
    XCTAssertEqual(content.message, "Choose a recipe to see what's in it.")
  }

  func testChosenRecipeWaitsForItsIngredients() {
    let content = make(recipe: recipe, loaded: nil)
    XCTAssertEqual(content, .loading)
    XCTAssertNil(content.message)
  }

  func testUnsavedRecipeHasNoIngredientList() {
    var unsaved = recipe
    unsaved.id = nil
    XCTAssertEqual(make(recipe: unsaved, loaded: nil), .noIngredientList)
  }

  func testRecipeWithoutRequiredIngredientsHasNoIngredientList() {
    XCTAssertEqual(make(recipe: recipe, loaded: []), .noIngredientList)
    XCTAssertEqual(
      make(recipe: recipe, loaded: [item(1, "scallion", grams: 10, required: false)]),
      .noIngredientList)
  }

  func testRowsMatchTheLoggedAmounts() {
    // Recipe serves 2; one serving at a large (1.4x) portion is 0.7 of the recipe.
    let content = make(
      recipe: recipe,
      loaded: [item(1, "cooked_rice", grams: 300), item(2, "egg", grams: 100)],
      servings: 1, portion: 1.4)

    guard case .ingredients(let rows) = content else {
      return XCTFail("expected ingredient rows, got \(content)")
    }
    XCTAssertEqual(rows.map(\.name), ["Cooked Rice", "Egg"])
    XCTAssertEqual(rows[0].grams, 210, accuracy: 0.001)
    XCTAssertEqual(rows[1].grams, 70, accuracy: 0.001)
  }

  func testOptionalIngredientsAreLeftOut() {
    let content = make(
      recipe: recipe,
      loaded: [item(1, "rice", grams: 200), item(2, "scallion", grams: 10, required: false)])
    guard case .ingredients(let rows) = content else {
      return XCTFail("expected ingredient rows, got \(content)")
    }
    XCTAssertEqual(rows.map(\.ingredientId), [1])
  }
}
