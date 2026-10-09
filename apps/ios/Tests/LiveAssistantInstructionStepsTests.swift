import FLFeatureLogic
import XCTest
@testable import FridgeLuck

/// Regression tests for the Le Chef live panel's step handling.
///
/// `LiveAssistantViewModel` used to split `recipeContext.instructions` by line, which turned the
/// bundled `Source: https://…` line into step 1 and printed the recipe's own "1." numbering under
/// the panel's own counters. These tests pin the shared `CookingGuideSteps` parser path — the same
/// parser the offline cooking guide uses — plus the zero-step navigation contract and the cleaned
/// `session_context` payload sent to the backend.
@MainActor
final class LiveAssistantInstructionStepsTests: XCTestCase {
  /// The shape every bundled recipe with a source uses (data.json, 2026-10-07).
  private let bundledInstructions = """
    Source: https://www.bbcgoodfood.com/recipes/sichuan-smacked-cucumber-noodles
    1. Toast the sichuan peppercorns.
    2. Smack the cucumber.
    3. Mix well to combine, then divide between two bowls.
    """

  private func makeContext(instructions: String) -> LiveAssistantRecipeContext {
    LiveAssistantRecipeContext(
      recipeID: 42,
      title: "Sichuan Smacked Cucumber Noodles",
      timeMinutes: 15,
      servings: 2,
      instructions: instructions,
      ingredients: []
    )
  }

  private func makeViewModel(instructions: String) -> LiveAssistantViewModel {
    LiveAssistantViewModel(recipeContext: makeContext(instructions: instructions))
  }

  // MARK: - URL metadata

  func testSourceURLIsMetadataNotAStep() throws {
    let viewModel = makeViewModel(instructions: bundledInstructions)

    XCTAssertEqual(
      viewModel.instructionSteps,
      [
        "Toast the sichuan peppercorns.",
        "Smack the cucumber.",
        "Mix well to combine, then divide between two bowls.",
      ])
    XCTAssertEqual(viewModel.totalSteps, 3)
    XCTAssertFalse(
      viewModel.instructionSteps.contains { $0.lowercased().hasPrefix("source:") },
      "The Source URL must never appear as a cooking step.")

    let attribution = try XCTUnwrap(viewModel.recipeAttribution)
    XCTAssertEqual(attribution.label, "bbcgoodfood.com")
    XCTAssertEqual(
      attribution.url,
      URL(string: "https://www.bbcgoodfood.com/recipes/sichuan-smacked-cucumber-noodles"))
  }

  // MARK: - Numbered instructions

  func testNumberedInstructionsKeepOrderAndDropNumbers() {
    let viewModel = makeViewModel(
      instructions: "Source: https://example.org/recipe\n1. Preheat the oven.\n2. Stir.\n10. Serve.")

    XCTAssertEqual(
      viewModel.instructionSteps,
      ["Preheat the oven.", "Stir.", "Serve."],
      "The recipe's own numbering is stripped and the panel numbers pages itself.")
  }

  // MARK: - Ordinary text

  func testOrdinaryInstructionsPassThroughUnchanged() {
    let viewModel = makeViewModel(instructions: "Chop the onion.\n\nFry it.  ")

    XCTAssertEqual(viewModel.instructionSteps, ["Chop the onion.", "Fry it."])
    XCTAssertNil(viewModel.recipeAttribution)
    XCTAssertFalse(viewModel.isOnLastStep)
  }

  // MARK: - Zero-step navigation

  func testEmptyInstructionsHaveNoStepsAndNoFinalStepState() {
    let viewModel = makeViewModel(instructions: "")

    XCTAssertEqual(viewModel.totalSteps, 0)
    XCTAssertFalse(viewModel.isOnLastStep, "No steps must never read as being on the last step.")
    XCTAssertEqual(viewModel.stepProgress, 0)

    viewModel.goToNextStep()
    viewModel.goToPreviousStep()
    XCTAssertEqual(viewModel.currentStepIndex, 0, "Navigation is a no-op without steps.")
  }

  func testAttributionOnlyInstructionsHaveNoStepsAndNoFinalStepState() {
    let viewModel = makeViewModel(instructions: "Source: https://example.org/recipe")

    XCTAssertEqual(viewModel.instructionSteps, [])
    XCTAssertEqual(viewModel.totalSteps, 0)
    XCTAssertFalse(viewModel.isOnLastStep)
    XCTAssertEqual(viewModel.recipeAttribution?.label, "example.org")

    viewModel.goToNextStep()
    viewModel.goToPreviousStep()
    XCTAssertEqual(viewModel.currentStepIndex, 0)
  }

  func testNavigationStaysInBoundsAtBothEnds() {
    let viewModel = makeViewModel(instructions: "1. First.\n2. Second.")

    viewModel.goToPreviousStep()
    XCTAssertEqual(viewModel.currentStepIndex, 0, "Back at the first step must not go negative.")

    viewModel.goToNextStep()
    XCTAssertTrue(viewModel.isOnLastStep)

    viewModel.goToNextStep()
    XCTAssertEqual(viewModel.currentStepIndex, 1, "Next on the last step is a no-op.")

    viewModel.goToPreviousStep()
    XCTAssertEqual(viewModel.currentStepIndex, 0)
    XCTAssertFalse(viewModel.isOnLastStep)
  }

  func testAttributionIsOnlyShownOnTheLastStep() {
    let viewModel = makeViewModel(instructions: bundledInstructions)

    viewModel.goToNextStep()
    XCTAssertFalse(viewModel.isOnLastStep)

    viewModel.goToNextStep()
    XCTAssertTrue(viewModel.isOnLastStep)
    XCTAssertNotNil(
      viewModel.recipeAttribution,
      "Attribution rides with the view model; the step card shows it on the final step.")
  }

  // MARK: - session_context payload

  func testSessionContextPayloadSendsCleanedStepsAndSeparateAttribution() throws {
    let payload = GeminiLiveSessionClient.sessionContextPayload(
      recipeContext: makeContext(instructions: bundledInstructions),
      latestConfidence: nil
    )

    let selectedRecipe = try XCTUnwrap(payload["selectedRecipe"] as? [String: Any])

    // The backend's StoredRecipeContext.instructions is a string; it stays one.
    let instructions = try XCTUnwrap(selectedRecipe["instructions"] as? String)
    XCTAssertEqual(
      instructions,
      "Toast the sichuan peppercorns.\nSmack the cucumber.\nMix well to combine, then divide between two bowls.")
    XCTAssertFalse(
      instructions.contains("bbcgoodfood"),
      "The raw source URL must not reach the model as an instruction.")
    XCTAssertFalse(
      instructions.contains("1."),
      "The recipe's own numbering must not reach the model.")

    XCTAssertEqual(
      selectedRecipe["sourceAttribution"] as? String,
      "Recipe from bbcgoodfood.com (https://www.bbcgoodfood.com/recipes/sichuan-smacked-cucumber-noodles)")

    XCTAssertTrue(payload["confirmedIngredients"] is [[String: Any]])
    XCTAssertNil(payload["latestConfidence"], "The key is omitted when there is no confidence to send.")
  }

  func testSessionContextPayloadOmitsAttributionWhenThereIsNone() throws {
    let payload = GeminiLiveSessionClient.sessionContextPayload(
      recipeContext: makeContext(instructions: "Chop the onion."),
      latestConfidence: nil
    )

    let selectedRecipe = try XCTUnwrap(payload["selectedRecipe"] as? [String: Any])
    XCTAssertEqual(selectedRecipe["instructions"] as? String, "Chop the onion.")
    XCTAssertNil(selectedRecipe["sourceAttribution"])
  }
}
