// FLScreenSupport tests — FLFitSummary, the shared fit-line grammar.
//
// The honesty rules SPEC 3.2 fixes for the hero, as tests: "10 of 10"
// only when every line is sufficient; the numeric form only for real,
// swap-covered shortfalls; the recorded form otherwise; never a
// percentage; never an unearned "you have everything".

import XCTest
@testable import FLScreenSupport

final class FLFitSummaryTests: XCTestCase {

    // MARK: Complete kitchens

    func testCompleteKitchenClaimsTheWholeCount() {
        let summary = FLFitSummary(have: 10, total: 10)
        XCTAssertEqual(summary.lineText, "10 of 10")
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.missingCaption, "You have everything")
    }

    func testHaveAboveTotalClampsSoTheCountNeverExceedsTheWhole() {
        let summary = FLFitSummary(have: 14, total: 10)
        XCTAssertEqual(summary.lineText, "10 of 10")
        XCTAssertTrue(summary.isComplete)
    }

    // MARK: The numeric form — earned only

    func testRealSwapCoveredShortfallEarnsTheNumericForm() {
        // Validated coverage: the host accepted a swap for the named
        // shortfall — the numeric form is earned.
        let summary = FLFitSummary(
            have: 9, total: 10, swapsNeeded: 1, shortfallNames: ["eggs"],
            swapCoveredNames: ["eggs"])
        XCTAssertEqual(summary.lineText, "9 of 10 · 1 swap")
        XCTAssertEqual(summary.missingCaption, "Missing eggs · 1 swap")
        XCTAssertFalse(summary.isComplete)
        XCTAssertTrue(summary.isCompleteAfterSwaps)
    }

    func testBareSwapCountNeverEarnsTheNumericForm() {
        // The reviewer's case: have=7, total=10, swapsNeeded=1 with three
        // named shortfalls and NO accepted swap must not read as complete
        // after swaps — coverage of the three names is unproven.
        let summary = FLFitSummary(
            have: 7, total: 10, swapsNeeded: 1,
            shortfallNames: ["eggs", "oil", "butter"])
        XCTAssertEqual(summary.lineText, "7 recorded · check eggs and oil and 1 more")
        XCTAssertFalse(summary.isCompleteAfterSwaps)
    }

    func testPartiallyValidatedCoverageStatesWhatIsKnown() {
        // One shortfall's swap accepted, two still to check: the summary
        // says exactly that — never the numeric complete form.
        let summary = FLFitSummary(
            have: 7, total: 10, swapsNeeded: 1,
            shortfallNames: ["eggs", "oil", "butter"],
            swapCoveredNames: ["eggs"])
        XCTAssertEqual(summary.lineText, "1 swap accepted, 2 items still to check")
        XCTAssertFalse(summary.isCompleteAfterSwaps)
        let caption = summary.missingCaption
        XCTAssertTrue(caption.contains("1 swap accepted"), caption)
    }

    func testASwapAcceptedForANonShortfallCoversNothing() {
        // A validated name that does not name a shortfall validates no
        // line: the summary keeps the recorded form.
        let summary = FLFitSummary(
            have: 8, total: 10, swapsNeeded: 1, shortfallNames: ["eggs"],
            swapCoveredNames: ["butter"])
        XCTAssertEqual(summary.lineText, "8 recorded · check eggs")
        XCTAssertFalse(summary.isCompleteAfterSwaps)
    }

    func testPluralSwaps() {
        let summary = FLFitSummary(
            have: 8, total: 10, swapsNeeded: 2, shortfallNames: ["eggs", "oil"],
            swapCoveredNames: ["eggs", "oil"])
        XCTAssertEqual(summary.lineText, "8 of 10 · 2 swaps")
        XCTAssertEqual(summary.missingCaption, "Missing eggs and oil · 2 swaps")
    }

    func testNumericFormIsNeverGivenAwayWithoutNames() {
        // A swap count with no named lines cannot render "9 of 10" —
        // the record must stay inspectable.
        let summary = FLFitSummary(have: 9, total: 10, swapsNeeded: 1, shortfallNames: [])
        XCTAssertEqual(summary.lineText, "9 recorded")
    }

    func testSwapsWithoutShortfallAreNotANumberedPromise() {
        // have == total but swaps present: the kitchen covers the dish;
        // the summary must not regress into a shortfall line.
        let summary = FLFitSummary(have: 10, total: 10, swapsNeeded: 3)
        XCTAssertEqual(summary.lineText, "10 of 10")
    }

    // MARK: The recorded form

    func testUnnamedShortfallRecordsTheCount() {
        let summary = FLFitSummary(have: 9, total: 10)
        XCTAssertEqual(summary.lineText, "9 recorded")
        XCTAssertFalse(summary.missingCaption.contains("You have everything"))
    }

    func testNamedShortfallNamesAtMostTwoLinesAndCountsTheRest() {
        let summary = FLFitSummary(
            have: 7, total: 10, shortfallNames: ["eggs", "oil", "butter"])
        XCTAssertEqual(summary.lineText, "7 recorded · check eggs and oil and 1 more")
    }

    func testNamedShortfallOfExactlyTwoNamesBoth() {
        let summary = FLFitSummary(
            have: 8, total: 10, shortfallNames: ["eggs", "oil"])
        XCTAssertEqual(summary.lineText, "8 recorded · check eggs and oil")
    }

    // MARK: Degenerate inputs

    func testZeroTotalIsNotComplete() {
        let summary = FLFitSummary(have: 0, total: 0)
        XCTAssertFalse(summary.isComplete)
        XCTAssertEqual(summary.lineText, "0 recorded")
    }

    func testNegativeInputsClamp() {
        let summary = FLFitSummary(have: -3, total: -1)
        XCTAssertEqual(summary.have, 0)
        XCTAssertEqual(summary.total, 0)
    }

    func testShortfallNamesShorterThanMissingFallToTheRecordedForm() {
        // Names cover only some missing lines: the numeric form would
        // hide the rest, so the recorded form carries the whole truth.
        let summary = FLFitSummary(
            have: 6, total: 10, swapsNeeded: 2, shortfallNames: ["eggs"])
        XCTAssertEqual(summary.lineText, "6 recorded · check eggs")
    }
}
