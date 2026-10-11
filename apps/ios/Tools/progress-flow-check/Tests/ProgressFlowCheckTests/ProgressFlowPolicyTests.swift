import Foundation
import XCTest

@testable import ProgressFlowCheck

/// R3: routing decisions — tapped meals route to the existing journal detail
/// screen, corrections hand off to their existing owner, goal editing goes
/// through the app's existing goal-editor callback.
final class ProgressFlowPolicyTests: XCTestCase {
  private func entry(id: Int64 = 42) -> CookingJournalEntry {
    let recipe = Recipe(
      id: 1,
      title: "Recipe 1",
      timeMinutes: 15,
      servings: 2,
      instructions: "cook",
      tags: 0,
      source: .bundled,
      createdAt: Date())
    return CookingJournalEntry(
      id: id,
      recipe: recipe,
      cookedAt: Date(),
      rating: 4,
      imagePath: nil,
      servingsConsumed: 1,
      macrosConsumed: MacroTotals(calories: 100, protein: 10, carbs: 10, fat: 10))
  }

  func testTappedMealRoutesToExistingJournalDetail() {
    XCTAssertEqual(
      ProgressFlowPolicy.mealRoute(for: entry(id: 42)),
      .journalDetail(entryID: 42))
  }

  func testCorrectionHandsOffWhileAFlowIsActive() {
    XCTAssertEqual(
      ProgressFlowPolicy.correctionDecision(isCorrectionFlowActive: true),
      .handOffToActiveCorrectionFlow)
  }

  func testCorrectionRoutesToJournalDetailWhenNoFlowIsActive() {
    XCTAssertEqual(
      ProgressFlowPolicy.correctionDecision(isCorrectionFlowActive: false),
      .routeToJournalDetail)
  }

  func testGoalEditingUsesExistingCallbackOnlyWhenOnboarded() {
    XCTAssertTrue(ProgressFlowPolicy.canOfferGoalEditing(hasOnboarded: true))
    XCTAssertFalse(ProgressFlowPolicy.canOfferGoalEditing(hasOnboarded: false))
  }
}
