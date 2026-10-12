import XCTest

@testable import FridgeLuck

/// "Not this item" on a needs-confirmation row must never be a silent no-op. On a first
/// run the learning cache is empty, so no candidate is pre-selected and the old path
/// mutated nothing at all — the tap the first-run walkthrough reported as dead.
@MainActor
final class IngredientReviewNotThisItemTests: XCTestCase {
  private func makeDetection(ingredientId: Int64, label: String = "suger") -> Detection {
    Detection(
      ingredientId: ingredientId,
      label: label,
      confidence: 0.42,
      source: .vision,
      originalVisionLabel: label,
      alternatives: []
    )
  }

  /// First run: no learned suggestion exists, so no candidate chip is selected. The tap
  /// must still produce a visible state change by rejecting the row.
  func testNotThisItemRejectsARowEvenWhenNothingIsSelected() {
    let detection = makeDetection(ingredientId: 7)

    let outcome = IngredientReviewView.notThisItemOutcome(
      detection: detection,
      selectedIngredientId: nil,
      suggestedIngredientId: nil
    )

    XCTAssertTrue(outcome.didRejectDetection, "A tap on Not this item must never be a no-op")
    XCTAssertNil(outcome.removedConfirmedIngredientId)
    XCTAssertNil(outcome.recordedSuggestedOutcome)
  }

  /// When a suggestion was seeded and pre-selected, rejecting keeps clearing that
  /// selection (old, correct behavior) on top of rejecting the row.
  func testNotThisItemClearsASelectedSuggestionAndRejectsTheRow() {
    let detection = makeDetection(ingredientId: 7)

    let outcome = IngredientReviewView.notThisItemOutcome(
      detection: detection,
      selectedIngredientId: 5,
      suggestedIngredientId: 5
    )

    XCTAssertTrue(outcome.didRejectDetection)
    XCTAssertTrue(outcome.didClearSelection)
    XCTAssertEqual(outcome.removedConfirmedIngredientId, 5)
    XCTAssertEqual(outcome.recordedSuggestedOutcome, false, "Suggestion 5 differs from the vision label's ingredient 7, so the suggestion was not accepted")
  }

  /// Existing telemetry semantics: a suggestion equal to what vision already proposed
  /// still counts as accepted, even though the user cleared the row.
  func testNotThisItemCountsASuggestionMatchingTheVisionLabelAsAccepted() {
    let detection = makeDetection(ingredientId: 9)

    let outcome = IngredientReviewView.notThisItemOutcome(
      detection: detection,
      selectedIngredientId: 9,
      suggestedIngredientId: 9
    )

    XCTAssertEqual(outcome.removedConfirmedIngredientId, 9)
    XCTAssertEqual(outcome.recordedSuggestedOutcome, true)
  }
}
