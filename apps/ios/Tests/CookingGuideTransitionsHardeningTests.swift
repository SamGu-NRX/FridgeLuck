import FLFeatureLogic
import XCTest

/// Behavioral hardening for `CookingGuideStateTransitions`.
///
/// These tests pin the public contract relied on by the cooking guide UI:
/// - `toggleIngredient` / `toggleCompletedStep` are true parity toggles
///   (membership after N toggles == N is odd) and never disturb other ids.
/// - Extreme and boundary ids (Int64.min/max, Int.min/max, 0, negatives)
///   round-trip without cross-collisions.
/// - `substitutionSlot(for:)` round-trips through the view-layer key
///   derivation (`ingredient.id ?? -1` in CookingGuideSections.swift).
///
/// Realistic regressions these would catch: a toggle rewritten as
/// insert-only or remove-only, a toggle that clears/replaces the set, and a
/// change of the substitution sentinel or its pass-through semantics.
final class CookingGuideTransitionsHardeningTests: XCTestCase {
  // MARK: - toggleIngredient parity

  func testToggleIngredientOddCountYieldsMembership() {
    var checked: Set<Int64> = []

    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    XCTAssertEqual(checked, [7], "single toggle must check the ingredient")

    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    XCTAssertEqual(checked, [7], "three toggles (odd) must leave the ingredient checked")
  }

  func testToggleIngredientEvenCountYieldsAbsence() {
    var checked: Set<Int64> = []

    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    XCTAssertTrue(checked.isEmpty, "two toggles (even) must leave the set empty")

    // Two more toggles (four total, even) must still end unchecked.
    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    XCTAssertTrue(checked.isEmpty)
  }

  func testToggleIngredientManyTogglesFollowParity() {
    var checked: Set<Int64> = []

    for count in 1...1000 {
      CookingGuideStateTransitions.toggleIngredient(3, checkedIngredients: &checked)
      XCTAssertEqual(checked.contains(3), count % 2 == 1, "membership after \(count) toggles must equal parity")
    }
  }

  // MARK: - toggleIngredient isolation (mixed set)

  func testToggleIngredientDoesNotDisturbOtherIngredients() {
    var checked: Set<Int64> = [7, 8, 9]

    // Simulates the guide: user re-taps an already-checked row among others.
    CookingGuideStateTransitions.toggleIngredient(8, checkedIngredients: &checked)
    XCTAssertEqual(checked, [7, 9], "unchecking 8 must leave 7 and 9 intact")

    CookingGuideStateTransitions.toggleIngredient(7, checkedIngredients: &checked)
    CookingGuideStateTransitions.toggleIngredient(9, checkedIngredients: &checked)
    XCTAssertTrue(checked.isEmpty, "unchecking remaining rows must empty the set")
  }

  func testToggleIngredientAddingOneKeepsExistingMembers() {
    var checked: Set<Int64> = [1, 2]
    CookingGuideStateTransitions.toggleIngredient(3, checkedIngredients: &checked)
    XCTAssertEqual(checked, [1, 2, 3], "checking a new row must not drop existing checks")
  }

  // MARK: - toggleIngredient extreme ids

  func testToggleIngredientExtremeIDsRoundTrip() {
    var checked: Set<Int64> = []

    for id in [Int64.min, Int64.max, Int64(0), Int64(-1)] {
      CookingGuideStateTransitions.toggleIngredient(id, checkedIngredients: &checked)
      XCTAssertTrue(checked.contains(id), "id \(id) must be checkable")
      CookingGuideStateTransitions.toggleIngredient(id, checkedIngredients: &checked)
      XCTAssertFalse(checked.contains(id), "id \(id) must be uncheckable again")
    }
    XCTAssertTrue(checked.isEmpty)
  }

  func testToggleIngredientExtremeIDsDoNotCollide() {
    var checked: Set<Int64> = [Int64.min, Int64.max]

    // Toggling boundary-adjacent ids must not evict the extremes.
    CookingGuideStateTransitions.toggleIngredient(Int64(0), checkedIngredients: &checked)
    XCTAssertEqual(checked, [Int64.min, Int64.max, 0])

    CookingGuideStateTransitions.toggleIngredient(Int64(-1), checkedIngredients: &checked)
    XCTAssertEqual(checked, [Int64.min, Int64.max, 0, -1])
  }

  // MARK: - toggleCompletedStep

  func testToggleCompletedStepFollowsParity() {
    var completed: Set<Int> = []

    CookingGuideStateTransitions.toggleCompletedStep(0, completedSteps: &completed)
    CookingGuideStateTransitions.toggleCompletedStep(0, completedSteps: &completed)
    XCTAssertTrue(completed.isEmpty, "even number of toggles must leave the step uncompleted")

    CookingGuideStateTransitions.toggleCompletedStep(0, completedSteps: &completed)
    XCTAssertEqual(completed, [0], "odd number of toggles must leave the step completed")
  }

  func testToggleCompletedStepDoesNotDisturbOtherSteps() {
    var completed: Set<Int> = [0, 1, 2]

    CookingGuideStateTransitions.toggleCompletedStep(1, completedSteps: &completed)
    XCTAssertEqual(completed, [0, 2], "uncompleting step 1 must leave steps 0 and 2 intact")
  }

  func testToggleCompletedStepExtremeIndicesRoundTrip() {
    var completed: Set<Int> = []

    for index in [Int.min, Int.max, 0, -1] {
      CookingGuideStateTransitions.toggleCompletedStep(index, completedSteps: &completed)
      XCTAssertTrue(completed.contains(index), "step index \(index) must be completable")
      CookingGuideStateTransitions.toggleCompletedStep(index, completedSteps: &completed)
      XCTAssertFalse(completed.contains(index), "step index \(index) must be clearable again")
    }
    XCTAssertTrue(completed.isEmpty)
  }

  func testToggleCompletedStepExtremeIndicesDoNotCollide() {
    var completed: Set<Int> = [Int.min, Int.max]

    CookingGuideStateTransitions.toggleCompletedStep(0, completedSteps: &completed)
    XCTAssertEqual(completed, [Int.min, Int.max, 0], "completing step 0 must not evict extreme indices")
  }

  // MARK: - substitutionSlot

  func testSubstitutionSlotPassesThroughRealIDs() {
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: 0), 0)
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: Int64.max), Int64.max)
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: Int64.min), Int64.min)
  }

  /// Known sentinel collision: a real id of -1 is indistinguishable from nil.
  ///
  /// This is tolerated today because every id reaching this API in the
  /// cooking guide comes from an INNER JOIN on the `ingredients` table rowid
  /// (RecipeRepository.ingredientsForRecipe), so real ids are always >= 1 and
  /// the view layer itself derives keys as `ingredient.id ?? -1`. If recipe
  /// ingredients can ever carry a real -1 id, this keying silently merges
  /// them into the nil-id slot. See SUSPECTED report.
  func testSubstitutionSlotNegativeOneCollidesWithNilSentinel() {
    XCTAssertEqual(
      CookingGuideStateTransitions.substitutionSlot(for: -1),
      CookingGuideStateTransitions.substitutionSlot(for: nil),
      "sentinel -1 must not silently diverge from the nil case; both map to the same slot"
    )
    XCTAssertEqual(CookingGuideStateTransitions.substitutionSlot(for: -1), -1)
  }

  /// Mirrors the view contract: CookingGuideView.swift stores the
  /// substitution under `substitutionSlot(for: ingredient.id)` and
  /// CookingGuideSections.swift looks it up under `ingredient.id ?? -1`.
  /// Those two derivations must agree for both nil and real ids.
  func testSubstitutionSlotRoundTripsThroughViewKeyDerivation() {
    var activeSubstitutions: [Int64: String] = [:]

    // Real id (from the DB join): store under slot, look up with `id ?? -1`.
    let realID: Int64? = 42
    activeSubstitutions[CookingGuideStateTransitions.substitutionSlot(for: realID)] = "swap"
    XCTAssertEqual(activeSubstitutions[realID ?? -1], "swap", "store/lookup keys must agree for real ids")

    // Nil id: sentinel slot, looked up under `id ?? -1` == -1.
    let nilID: Int64? = nil
    activeSubstitutions[CookingGuideStateTransitions.substitutionSlot(for: nilID)] = "fallback"
    XCTAssertEqual(activeSubstitutions[nilID ?? -1], "fallback", "store/lookup keys must agree for nil ids")
  }
}
