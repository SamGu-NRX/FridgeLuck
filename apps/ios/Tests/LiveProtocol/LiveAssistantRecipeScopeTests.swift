import XCTest

@testable import FridgeLuck

@MainActor
final class LiveAssistantRecipeScopeTests: XCTestCase {
  func testCookSessionSnapshotCarriesRecipeScopeAndBill() {
    let context = LiveAssistantRecipeContext(
      recipeID: 42,
      title: "Soy sauce stir-fry",
      timeMinutes: 20,
      servings: 2,
      instructions: "Stir.",
      ingredients: [
        LiveAssistantIngredientContext(
          id: "soy-sauce", name: "soy sauce", quantityGrams: 15)
      ])
    let viewModel = CookModeViewModel(
      recipe: Recipe(
        id: 42, title: context.title, timeMinutes: 20, servings: 2, instructions: "Stir.",
        tags: 0, source: .bundled, createdAt: nil),
      logsMeal: false,
      dependencies: .ephemeral())
    viewModel.startOrResume()

    let payload = LiveAssistantViewModel.boundedSnapshot(from: viewModel, recipeContext: context)
    let session = try! XCTUnwrap(payload["cookSession"] as? [String: Any])
    let recipes = try! XCTUnwrap(payload["recipes"] as? [[String: Any]])
    let bill = try! XCTUnwrap(recipes.first?["ingredientBill"] as? [[String: Any]])
    XCTAssertEqual(session["recipeId"] as? String, "42")
    XCTAssertEqual(recipes.first?["id"] as? String, "42")
    XCTAssertEqual(bill.first?["ingredientId"] as? String, "soy-sauce")
    XCTAssertEqual((bill.first?["quantity"] as? [String: Any])?["value"] as? Double, 15)
  }
}
