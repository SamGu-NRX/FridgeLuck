import XCTest

@testable import FridgeLuck

final class RecipePromptBuilderTests: XCTestCase {
  /// The ingredients sentence keeps its exact wording and comma-joined format.
  func testIngredientsLineFormatIsPreserved() {
    let prompt = RecipePromptBuilder.buildPrompt(
      ingredientNames: ["peanut butter", "celery", "bread"],
      dietaryRestrictions: [],
      avoidIngredients: []
    )

    XCTAssertEqual(
      prompt,
      "Create one recipe using these ingredients: peanut butter, celery, bread."
    )
  }

  /// Dietary restrictions are appended as their own sentence when present.
  func testDietaryRestrictionsSentencePresentWhenNonEmpty() {
    let prompt = RecipePromptBuilder.buildPrompt(
      ingredientNames: ["tofu"],
      dietaryRestrictions: ["vegan"],
      avoidIngredients: []
    )

    XCTAssertEqual(
      prompt,
      "Create one recipe using these ingredients: tofu. Respect dietary restrictions: vegan."
    )
  }

  /// No dietary restrictions sentence is emitted when the list is empty.
  func testDietaryRestrictionsSentenceAbsentWhenEmpty() {
    let prompt = RecipePromptBuilder.buildPrompt(
      ingredientNames: ["eggs"],
      dietaryRestrictions: [],
      avoidIngredients: []
    )

    XCTAssertEqual(
      prompt,
      "Create one recipe using these ingredients: eggs."
    )
  }

  /// The hard-exclusion sentence lists every avoid ingredient when present.
  func testHardExclusionSentencePresentWithJoinedNames() {
    let prompt = RecipePromptBuilder.buildPrompt(
      ingredientNames: ["shrimp"],
      dietaryRestrictions: [],
      avoidIngredients: ["peanuts", "tree nuts"]
    )

    XCTAssertEqual(
      prompt,
      "Create one recipe using these ingredients: shrimp. HARD EXCLUSION: The recipe must not include, garnish with, or mention any of these allergens: peanuts, tree nuts. Never suggest them as substitutes."
    )
  }

  /// No hard-exclusion sentence is emitted when the avoid list is empty.
  func testHardExclusionSentenceAbsentWhenEmpty() {
    let prompt = RecipePromptBuilder.buildPrompt(
      ingredientNames: ["eggs"],
      dietaryRestrictions: ["vegetarian"],
      avoidIngredients: []
    )

    XCTAssertEqual(
      prompt,
      "Create one recipe using these ingredients: eggs. Respect dietary restrictions: vegetarian."
    )
  }

  /// All three sentences appear in order when every list is populated.
  func testAllThreeSectionsCombined() {
    let prompt = RecipePromptBuilder.buildPrompt(
      ingredientNames: ["chicken", "rice"],
      dietaryRestrictions: ["gluten-free"],
      avoidIngredients: ["peanuts"]
    )

    XCTAssertEqual(
      prompt,
      "Create one recipe using these ingredients: chicken, rice. Respect dietary restrictions: gluten-free. HARD EXCLUSION: The recipe must not include, garnish with, or mention any of these allergens: peanuts. Never suggest them as substitutes."
    )
  }
}
