import FLFeatureLogic
import XCTest

final class CookingGuideStateTransitionsTests: XCTestCase {
  func testToggleIngredientAddsMissingIngredient() {
    var checked: Set<Int64> = []

    CookingGuideStateTransitions.toggleIngredient(42, checkedIngredients: &checked)

    XCTAssertEqual(checked, [42])
  }

  func testToggleIngredientRemovesExistingIngredient() {
    var checked: Set<Int64> = [42]

    CookingGuideStateTransitions.toggleIngredient(42, checkedIngredients: &checked)

    XCTAssertTrue(checked.isEmpty)
  }

  func testToggleCompletedStepAddsMissingStep() {
    var completed: Set<Int> = []

    CookingGuideStateTransitions.toggleCompletedStep(3, completedSteps: &completed)

    XCTAssertEqual(completed, [3])
  }

  func testToggleCompletedStepRemovesExistingStep() {
    var completed: Set<Int> = [3]

    CookingGuideStateTransitions.toggleCompletedStep(3, completedSteps: &completed)

    XCTAssertTrue(completed.isEmpty)
  }

  func testSubstitutionSlotUsesIngredientIDWhenPresent() {
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: 99), 99)
  }

  func testSubstitutionSlotFallsBackToSentinelWhenNil() {
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: nil), -1)
  }
}
