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
        photo: String? = nil, note: String? = nil,
        checks: [RecipeViewState.Step.SafetyCheck] = []
    ) -> RecipeViewState.Step {
        RecipeViewState.Step(
            id: id, title: title, body: body, photoCaption: photo, cookNote: note,
            requiredChecks: checks
        )
    }

    private func state(
        servings: Int = 2,
        ingredients: [RecipeViewState.Ingredient] = [],
        steps: [RecipeViewState.Step] = [],
        minutes: Int = 35, have: Int = 10, total: Int = 10, swaps: Int = 0,
        names: [String] = [], covered: [String] = []
    ) -> RecipeViewState {
        RecipeViewState(
            recipeID: "r-1", title: "Ginger chicken udon noodles",
            publisherDisplay: "Maya", revisionDisplay: "rev 2",
            minutes: minutes,
            fit: FLFitSummary(
                have: have, total: total, swapsNeeded: swaps,
                shortfallNames: names, swapCoveredNames: covered),
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

    // MARK: Servings change — the fit goes pending, honestly

    func testServingsChangeInvalidatesTheFitPendingRecomputation() {
        var s = state(servings: 2, have: 9, total: 10, swaps: 1, names: ["eggs"])
        s.apply(.setServings(4))
        XCTAssertEqual(s.targetServings, 4)
        XCTAssertTrue(s.fitIsPending)
        XCTAssertFalse(s.primaryActionIsFitBacked)
    }

    func testPendingFitStatesTheCheckInsteadOfStaleClaims() {
        var s = state(servings: 2, have: 10, total: 10)
        s.apply(.setServings(4))
        XCTAssertTrue(s.statsDisplay.contains("checking your kitchen for 4"), s.statsDisplay)
        XCTAssertFalse(s.statsDisplay.contains("10 of 10"))
    }

    func testSetServingsToTheSameValueKeepsTheFitCurrent() {
        var s = state(servings: 2, have: 10, total: 10)
        s.apply(.setServings(2))
        XCTAssertFalse(s.fitIsPending)
        XCTAssertEqual(s.statsDisplay, "10 of 10 · 35 min")
    }

    func testFitRecomputedForTheCurrentTargetRestoresTheFit() {
        var s = state(servings: 2, have: 10, total: 10)
        s.apply(.setServings(4))
        let doubled = FLFitSummary(
            have: 9, total: 10, swapsNeeded: 1,
            shortfallNames: ["eggs"], swapCoveredNames: ["eggs"])
        s.apply(.fitRecomputed(fit: doubled, forServings: 4))
        XCTAssertFalse(s.fitIsPending)
        XCTAssertTrue(s.primaryActionIsFitBacked)
        XCTAssertEqual(s.statsDisplay, "9 of 10 · 1 swap · 35 min")
    }

    func testStaleFitRecomputationIsDropped() {
        var s = state(servings: 2, have: 10, total: 10)
        s.apply(.setServings(4))
        // A result for the OLD target arrives late: stale, never shown.
        s.apply(.fitRecomputed(fit: FLFitSummary(have: 3, total: 10), forServings: 2))
        XCTAssertTrue(s.fitIsPending)
        XCTAssertEqual(s.statsDisplay, "checking your kitchen for 4 · 35 min")
        // The current target's result still applies afterwards.
        s.apply(.fitRecomputed(fit: FLFitSummary(have: 6, total: 10), forServings: 4))
        XCTAssertFalse(s.fitIsPending)
        XCTAssertEqual(s.statsDisplay, "6 recorded · 35 min")
    }

    func testPresenceIsNotASufficiencyClaimWhilePending() {
        // Doubling keeps ingredient identities, but the pending state
        // asserts nothing about the doubled amounts.
        var s = state(servings: 2,
                      ingredients: [ingredient(inKitchen: true)],
                      have: 10, total: 10)
        s.apply(.setServings(4))
        XCTAssertTrue(s.fitIsPending)
        XCTAssertFalse(s.primaryActionIsFitBacked)
        // isInKitchen itself is untouched — it is presence, not fit.
        XCTAssertTrue(s.ingredients[0].isInKitchen)
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
        // The numeric form needs VALIDATED coverage of every named
        // shortfall — a bare swap count proves no line's coverage.
        let validated = state(have: 8, total: 10, swaps: 2,
                              names: ["eggs", "oil"], covered: ["eggs", "oil"])
        XCTAssertEqual(validated.statsDisplay, "8 of 10 · 2 swaps · 35 min")
        // Without accepted swaps, the line states what is known.
        let bare = state(have: 8, total: 10, swaps: 2, names: ["eggs", "oil"])
        XCTAssertEqual(bare.statsDisplay, "8 recorded · check eggs and oil · 35 min")
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

    func testSkipAdvancesLikeNextButRecordsSkipped() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        s.apply(.skipStep)
        XCTAssertEqual(s.currentStepIndex, 1)
        XCTAssertEqual(s.stepOutcomes[0], .skipped)
        XCTAssertNil(s.stepOutcomes[1])
        // And Next records completed, distinctly.
        var t = state(steps: [step(id: "s-1"), step(id: "s-2")])
        t.apply(.beginCook)
        t.apply(.nextStep)
        XCTAssertEqual(t.stepOutcomes[0], .completed)
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

    // MARK: Skip vs Next — the record reflects what actually happened

    func testSkippingTheFinalStepDoesNotOpenTheRecord() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        s.apply(.skipStep)
        s.apply(.skipStep)   // the FINAL step is skipped
        XCTAssertNil(s.currentStepIndex)
        XCTAssertFalse(s.showsRecord, "a skipped final step must not produce a record")
        XCTAssertFalse(s.completedCookIsAssertable)
    }

    func testCompletingEveryStepOpensTheRecordAndCompletes() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        s.apply(.nextStep)
        s.apply(.nextStep)
        XCTAssertTrue(s.showsRecord)
        XCTAssertEqual(s.recordCompletion, .completed)
        XCTAssertTrue(s.completedCookIsAssertable)
    }

    func testASkippedMiddleStepLeavesTheRecordIncomplete() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        s.apply(.beginCook)
        s.apply(.skipStep)
        s.apply(.nextStep)   // the final step IS completed
        XCTAssertTrue(s.showsRecord)
        XCTAssertEqual(
            s.recordCompletion,
            .incomplete(skippedSteps: 1, unreviewedChecks: 0))
        XCTAssertFalse(s.completedCookIsAssertable)
    }

    func testRecordCompletionIsNilUntilEveryStepWasReached() {
        var s = state(steps: [step(id: "s-1"), step(id: "s-2")])
        XCTAssertNil(s.recordCompletion)
        s.apply(.beginCook)
        XCTAssertNil(s.recordCompletion)
        s.apply(.nextStep)
        XCTAssertNil(s.recordCompletion, "step 2 not reached yet")
        s.apply(.nextStep)
        XCTAssertNotNil(s.recordCompletion)
    }

    func testACompletedCookRequiresEveryRequiredSafetyCheckReviewed() {
        // The canon binds the RECORD: doneness requires a reviewed
        // thermometer check; timers only say when to check.
        let thermometer = step(
            id: "s-1", title: "Roast the thighs", body: "Until done.",
            checks: [.thermometerDoneness])
        var s = state(steps: [thermometer])
        s.apply(.beginCook)
        s.apply(.nextStep)   // completed the step, check unreviewed
        XCTAssertTrue(s.showsRecord)
        XCTAssertEqual(
            s.recordCompletion,
            .incomplete(skippedSteps: 0, unreviewedChecks: 1))
        XCTAssertFalse(
            s.completedCookIsAssertable,
            "a completed cook cannot be asserted while a required check never ran")
        s.apply(.safetyCheckReviewed(stepID: "s-1", check: .thermometerDoneness))
        XCTAssertEqual(s.recordCompletion, .completed)
        XCTAssertTrue(s.completedCookIsAssertable)
    }

    func testTimedRestIsASafetyCheckLikeAnyOther() {
        let rest = step(id: "s-1", title: "Rest the roast", body: "Ten minutes.",
                        checks: [.timedRest, .thermometerDoneness])
        var s = state(steps: [rest])
        s.apply(.beginCook)
        s.apply(.nextStep)
        XCTAssertEqual(
            s.recordCompletion,
            .incomplete(skippedSteps: 0, unreviewedChecks: 2))
        s.apply(.safetyCheckReviewed(stepID: "s-1", check: .timedRest))
        XCTAssertEqual(
            s.recordCompletion,
            .incomplete(skippedSteps: 0, unreviewedChecks: 1))
        s.apply(.safetyCheckReviewed(stepID: "s-1", check: .thermometerDoneness))
        XCTAssertEqual(s.recordCompletion, .completed)
    }

    func testBeginCookResetsOutcomesAndReviewedChecks() {
        let thermometer = step(id: "s-1", checks: [.thermometerDoneness])
        var s = state(steps: [thermometer])
        s.apply(.beginCook)
        s.apply(.nextStep)
        XCTAssertEqual(s.recordCompletion, .incomplete(skippedSteps: 0, unreviewedChecks: 1))
        s.apply(.safetyCheckReviewed(stepID: "s-1", check: .thermometerDoneness))
        XCTAssertEqual(s.recordCompletion, .completed)
        // A fresh cook session starts with no outcomes and no reviews.
        s.apply(.beginCook)
        XCTAssertEqual(s.stepOutcomes, [nil])
        XCTAssertTrue(s.reviewedChecks.isEmpty)
        XCTAssertNil(s.recordCompletion)
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
