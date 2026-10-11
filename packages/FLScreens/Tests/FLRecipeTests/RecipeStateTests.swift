// FLRecipe tests — the recipe document's binding rules, as tests.
//
// Servings scaling that touches every line (never "show base numbers"),
// the numeric grammar (½ tbsp, 1.5 tbsp, "2 eggs"), the bounds, the
// step flow that ends in the cook record, and notes that show only
// while cooking. Fixtures are synthetic.

import XCTest
@testable import FLRecipe
@testable import FLScreenSupport

final class RecipeStateTests: XCTestCase {

    // MARK: Fixtures (synthetic copy — no real user data)

    private func ingredient(
        id: String = "i-1", name: String = "butter", base: Double? = 130, unit: String? = "g",
        inKitchen: Bool = true, swap: String? = nil
    ) -> RecipeViewState.Ingredient {
        RecipeViewState.Ingredient(
            id: id, name: name, baseQuantity: base, unit: unit,
            isInKitchen: inKitchen, swapDisplay: swap
        )
    }

    private func step(
        id: String = "s-1", title: String = "Brown the butter", body: String = "Four minutes, no further.",
        photo: String? = nil, note: String? = nil
    ) -> RecipeViewState.Step {
        RecipeViewState.Step(
            id: id, title: title, body: body, photoCaption: photo, cookNote: note
        )
    }

    private func state(
        servings: Int = 2,
        ingredients: [RecipeViewState.Ingredient] = [],
        steps: [RecipeViewState.Step] = [],
        minutes: Int = 35, have: Int = 10, total: Int = 10, swaps: Int = 0,
        names: [String] = []
    ) -> RecipeViewState {
        RecipeViewState(
            recipeID: "r-1", title: "Ginger chicken udon noodles",
            publisherDisplay: "Maya", revisionDisplay: "rev 2",
            minutes: minutes,
            fit: FLFitSummary(have: have, total: total, swapsNeeded: swaps, shortfallNames: names),
            baseServings: 2, targetServings: servings,
            ingredients: ingredients, steps: steps
        )
    }

    // MARK: Servings bounds

    func testServingsStepperClampsToTheBounds() {
        var s = state(servings: 1)
        s.apply(.setServings(0))
        XCTAssertEqual(s.targetServings, RecipeBounds.minServings)
        s.apply(.setServings(99))
        XCTAssertEqual(s.targetServings, RecipeBounds.maxServings)
    }

    func testScaleFactorTracksTheTargetServings() {
        let s = state(servings: 4)
        XCTAssertEqual(s.scaleFactor, 2.0, accuracy: 0.0001)
    }

    // MARK: Scaling — every line moves

    func testMetricQuantityScalesAndStaysHonest() {
        // 130 g at ×2 → "260 g"; at ½× → "65 g". Round numbers never
        // grow decimal dust.
        let s = state(servings: 4, ingredients: [ingredient(base: 130, unit: "g")])
        XCTAssertEqual(s.scaledDisplay(for: s.ingredients[0]), "260 g butter")
        XCTAssertEqual(s.scaledQuantityDisplay(for: s.ingredients[0]), "260 g")
        let half = state(servings: 1, ingredients: [ingredient(base: 130, unit: "g")])
        XCTAssertEqual(half.scaledQuantityDisplay(for: half.ingredients[0]), "65 g")
    }

    func testSmallVolumeKeepsItsTablespoonForm() {
        let s = state(servings: 4, ingredients: [ingredient(id: "i-2", name: "rice vinegar", base: 0.75, unit: "tbsp")])
        XCTAssertEqual(s.scaledQuantityDisplay(for: s.ingredients[0]), "1.5 tbsp")
    }

    func testUnitlessLinesPluraliseByTheNumber() {
        // One egg at ×2 → "2 eggs".
        let s = state(servings: 4, ingredients: [ingredient(id: "i-3", name: "eggs", base: 1, unit: nil)])
        XCTAssertEqual(s.scaledDisplay(for: s.ingredients[0]), "2 eggs")
    }

    func testCountlessLinesPassThroughUntouched() {
        let s = state(servings: 4, ingredients: [ingredient(id: "i-4", name: "a handful of basil", base: nil, unit: nil)])
        XCTAssertEqual(s.scaledDisplay(for: s.ingredients[0]), "a handful of basil")
        XCTAssertEqual(s.scaledQuantityDisplay(for: s.ingredients[0]), "")
    }

    // MARK: Header lines

    func testStatsLineJoinsTheFitAndMinutes() {
        XCTAssertEqual(state().statsDisplay, "10 of 10 · 35 min")
        // A swap-covered shortfall with named lines earns the numeric form.
        let half = state(have: 8, total: 10, swaps: 2, names: ["eggs", "oil"])
        XCTAssertEqual(half.statsDisplay, "8 of 10 · 2 swaps · 35 min")
        // Without names, the summary stays in the recorded form.
        let unnamed = state(have: 8, total: 10, swaps: 2)
        XCTAssertEqual(unnamed.statsDisplay, "8 recorded · 35 min")
    }

    func testPrimaryActionNamesTheServings() {
        XCTAssertEqual(state(servings: 2).primaryActionTitle, "Cook for 2")
        XCTAssertEqual(state(servings: 1).primaryActionTitle, "Cook for 1")
    }

    // MARK: The cook flow

    func testBeginCookEntersTheStepFlowWithStepOneCurrent() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        XCTAssertTrue(s.isCooking)
        XCTAssertEqual(s.currentStepIndex, 0)
        XCTAssertEqual(s.stepCountDisplay, "Step 1 of 2")
        XCTAssertTrue(s.showsStepNotes)
    }

    func testBeginCookIsRefusedWithoutSteps() {
        var s = state()
        s.apply(.beginCook)
        XCTAssertFalse(s.isCooking)
        XCTAssertNil(s.currentStepIndex)
        XCTAssertNil(s.stepCountDisplay)
    }

    func testNextStepAdvancesAndTheRecordOpensAtTheLastStep() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        s.apply(.nextStep)
        XCTAssertEqual(s.currentStepIndex, 1)
        XCTAssertEqual(s.stepCountDisplay, "Step 2 of 2")
        XCTAssertFalse(s.showsRecord)
        s.apply(.nextStep)
        XCTAssertTrue(s.showsRecord)
        XCTAssertFalse(s.showsStepNotes, "notes hide once the record opens")
    }

    func testSkipMovesOnLikeNext() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        s.apply(.skipStep)
        XCTAssertEqual(s.currentStepIndex, 1)
    }

    func testNextWithoutCookingDoesNothing() {
        var s = state(steps: [step(id: "s-1")])
        s.apply(.nextStep)
        XCTAssertNil(s.currentStepIndex)
        XCTAssertFalse(s.showsRecord)
    }

    func testExitCookClosesTheFlowAndTheRecord() {
        var s = state(steps: [step(id: "s-1")])
        s.apply(.beginCook)
        s.apply(.exitCook)
        XCTAssertNil(s.currentStepIndex)
        XCTAssertFalse(s.isCooking)
        XCTAssertFalse(s.showsRecord)
    }

    // MARK: The cook record

    func testRatingClampsToTheFiveStarBounds() {
        var s = state()
        s.apply(.setRating(9))
        XCTAssertEqual(s.rating, RecipeBounds.maxRating)
        s.apply(.setRating(0))
        XCTAssertEqual(s.rating, RecipeBounds.minRating)
    }

    func testTheOneLineDifferenceRecordsAndShowsOnTheRecord() {
        var s = state()
        s.apply(.setDifferently("used less salt"))
        XCTAssertEqual(s.didDifferently, "used less salt")
    }

    func testDismissRecordClosesWithoutTouchingTheDraft() {
        var s = state()
        s.apply(.setDifferently("used less salt"))
        s.apply(.dismissRecord)
        XCTAssertFalse(s.showsRecord)
        XCTAssertEqual(s.didDifferently, "used less salt", "dismissal keeps the draft")
    }

    // MARK: Reducer — effects stay host-side

    func testEffectsIntentsLeaveStateUntouched() {
        var s = state(steps: [step(id: "s-1")])
        let before = s
        let effects: [RecipeIntent] = [
            .openRelated(recipeID: "r-9"), .saveRecord, .shareRecord,
        ]
        for intent in effects {
            s.apply(intent)
            XCTAssertEqual(s, before, "host effects must not mutate state: \(intent)")
        }
    }
}
