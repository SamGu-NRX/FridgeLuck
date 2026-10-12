// FLTourTests — the constrained onboarding tour CANDIDATE, Linux-tested.
//
// The state layer is Foundation-only, so the machine's every edge is
// tested here on Linux: the candidate flag's gating, the five-step
// truncation (shortness enforced on arrival), start/completion, the
// auto-return contract (the card comes down after each step; the host
// re-presents), back's lower bound, skip's availability and finality,
// and the no-re-arm rule for a dismissed or completed tour.
//
// The SwiftUI views are Apple-gated and unverified on Linux by design
// (UNVERIFIED-NATIVE); the raw-source lint (Part6RawSourceLintTests)
// pins their conventions.

import XCTest
@testable import FLTour

final class TourStateTests: XCTestCase {

    private func step(_ id: String, title: String) -> TourViewState.Step {
        TourViewState.Step(
            id: id, title: title,
            bodyText: "One or two sentences, host-verbatim.",
            privacyLines: ["Everything runs on your phone."],
            primaryLabel: "Scan your first shelf")
    }

    private func tourWithThreeSteps() -> TourViewState {
        TourViewState(
            enabled: true,
            steps: [step("s1", title: "It learns your kitchen"),
                    step("s2", title: "What stays on the phone"),
                    step("s3", title: "What you can undo")],
            footerCaption: "no account needed")
    }

    // MARK: The candidate ships off

    func testTheCandidateShipsOffAndCannotStart() {
        var state = TourViewState()
        XCTAssertFalse(state.enabled, "the candidate flag ships OFF")
        XCTAssertEqual(state.stage, .idle)
        state.apply(.start)
        XCTAssertEqual(state.stage, .idle, "a flag-off candidate never presents")
    }

    func testSkipAlsoRequiresTheFlag() {
        var state = TourViewState()
        state.apply(.skip)
        XCTAssertEqual(state.stage, .idle, "nothing to dismiss while off")
    }

    // MARK: Shortness is enforced on arrival

    func testStepsTruncateToTheCapOnArrival() {
        let seven = (1...7).map { step("s\($0)", title: "Promise \($0)") }
        let state = TourViewState(enabled: true, steps: seven)
        XCTAssertEqual(state.steps.count, TourViewState.maxSteps, "the tour cannot quietly grow into a funnel")
        XCTAssertEqual(state.steps.map(\.id), ["s1", "s2", "s3", "s4", "s5"], "the first five win")

        var reArrived = tourWithThreeSteps()
        reArrived.apply(.stepsArrived(seven))
        XCTAssertEqual(reArrived.steps.count, TourViewState.maxSteps)
    }

    // MARK: Start

    func testStartWithNoStepsStaysIdle() {
        var state = TourViewState(enabled: true)
        state.apply(.start)
        XCTAssertEqual(state.stage, .idle, "an empty tour cannot start")
    }

    func testStartPresentsTheFirstPromise() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        XCTAssertEqual(state.stage, .presenting(index: 0))
        XCTAssertTrue(state.isPresenting)
        XCTAssertEqual(state.currentStep?.title, "It learns your kitchen")
        XCTAssertEqual(state.pagerLine, "1 of 3", "the pager counts from one")
        XCTAssertEqual(state.currentIndex, 0)
    }

    // MARK: The auto-return contract

    func testCompletingAMidTourStepReturnsHomeWithTheNextIndex() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.completeStep)
        XCTAssertEqual(state.stage, .returnedHome(nextIndex: 1), "the card comes down, the app is usable")
        XCTAssertFalse(state.isPresenting)
        XCTAssertNil(state.currentStep)
        XCTAssertNil(state.pagerLine, "the pager lives only while presenting")
    }

    func testTheHostRePresentsTheNextPromise() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.completeStep)
        state.apply(.presentStep(index: 1))
        XCTAssertEqual(state.stage, .presenting(index: 1))
        XCTAssertEqual(state.pagerLine, "2 of 3")
    }

    func testPresentStepIsBoundsCheckedAndIgnoresStrayPresents() {
        var state = tourWithThreeSteps()
        state.apply(.presentStep(index: 9))
        XCTAssertEqual(state.stage, .idle, "out of bounds never presents")

        state.apply(.start)
        state.apply(.presentStep(index: 9))
        XCTAssertEqual(state.stage, .presenting(index: 0), "still on the first promise")
    }

    // MARK: Back's lower bound

    func testBackStepsBackOnePromise() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.presentStep(index: 1))
        state.apply(.back)
        XCTAssertEqual(state.stage, .presenting(index: 0))
    }

    func testBackNeverGoesBeforeTheFirstStep() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.back)
        XCTAssertEqual(state.stage, .presenting(index: 0), "back has nowhere to go from the first promise")
    }

    // MARK: Completion

    func testCompletingTheLastPromiseCompletesTheTour() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.presentStep(index: 2))
        state.apply(.completeStep)
        XCTAssertEqual(state.stage, .completed)
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.isPresenting)
    }

    // MARK: Skip and the no-re-arm rule

    func testSkipDismissesFromAnyPresentingStep() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.presentStep(index: 2))
        state.apply(.skip)
        XCTAssertEqual(state.stage, .dismissed)
        XCTAssertTrue(state.isFinished)
    }

    func testDismissedAndCompletedToursNeverRearm() {
        var state = tourWithThreeSteps()
        state.apply(.start)
        state.apply(.skip)
        state.apply(.start)
        XCTAssertEqual(state.stage, .dismissed, "a dismissed tour stays dismissed for the session")
        state.apply(.presentStep(index: 0))
        XCTAssertEqual(state.stage, .dismissed, "the host cannot re-present either")
        state.apply(.completeStep)
        XCTAssertEqual(state.stage, .dismissed)

        var finishedByCompletion = tourWithThreeSteps()
        finishedByCompletion.apply(.start)
        finishedByCompletion.apply(.completeStep)
        finishedByCompletion.apply(.presentStep(index: 1))
        finishedByCompletion.apply(.completeStep)
        finishedByCompletion.apply(.presentStep(index: 2))
        finishedByCompletion.apply(.completeStep)
        XCTAssertEqual(finishedByCompletion.stage, .completed)
        finishedByCompletion.apply(.start)
        XCTAssertEqual(finishedByCompletion.stage, .completed, "a completed tour stays completed")
    }
}
