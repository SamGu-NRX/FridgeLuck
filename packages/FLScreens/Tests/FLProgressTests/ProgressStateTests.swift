// FLProgressTests — the Progress tab and Profile destination, Linux-tested.
//
// The state layer is Foundation-only, so every observable behaviour is
// tested here on Linux: counter and week-list arrivals (host-owned
// arithmetic, host order), first-run derivation, the saved-food display
// grammar shared with Quests, the quests CANDIDATE's flag gating, and
// the Profile Forget flow's phase machine on the state's host-maintained
// clock (five-second window, undo within it, expiry by tick, "Recipes
// stay; the profile empties").
//
// The SwiftUI views are Apple-gated and unverified on Linux by design
// (UNVERIFIED-NATIVE); the raw-source lint (Part6RawSourceLintTests)
// pins their conventions.

import XCTest
@testable import FLProgress

final class ProgressStateTests: XCTestCase {

    // MARK: Counters arrive from the host, verbatim

    func testCountersArrivalStoresTheHostsValues() {
        var state = ProgressViewState()
        state.apply(.countersArrived(ProgressViewState.Counters(
            cookedThisWeek: 12, weekStreak: 3, savedFoodGrams: 1200
        )))
        XCTAssertEqual(state.counters.cookedThisWeek, 12)
        XCTAssertEqual(state.counters.weekStreak, 3)
        XCTAssertEqual(state.counters.savedFoodGrams, 1200)
    }

    func testCountersClampNegativeHostValuesToZero() {
        let counters = ProgressViewState.Counters(
            cookedThisWeek: -2, weekStreak: -1, savedFoodGrams: -5
        )
        XCTAssertEqual(counters.cookedThisWeek, 0)
        XCTAssertEqual(counters.weekStreak, 0)
        XCTAssertEqual(counters.savedFoodGrams, 0)
    }

    func testWeekCooksArriveInTheHostsOrderAndAreNeverReSorted() {
        var state = ProgressViewState()
        // Deliberately not chronological: order is the host's statement.
        let cooks = [
            ProgressViewState.WeekCook(id: "c3", dayDisplay: "Mon", dishDisplay: "Miso mushroom udon", ratingDisplay: "5", timeDisplay: "20:12"),
            ProgressViewState.WeekCook(id: "c1", dayDisplay: "Thu", dishDisplay: "Butter bean curry", ratingDisplay: "5", timeDisplay: "18:40"),
        ]
        state.apply(.weekCooksArrived(cooks))
        XCTAssertEqual(state.weekCooks.map(\.id), ["c3", "c1"], "the state never re-sorts the host's order")
    }

    // MARK: First run

    func testFirstRunIsEmptyLogAndNothingElse() {
        var state = ProgressViewState()
        XCTAssertTrue(state.isFirstRun, "a brand-new state is first run")

        // A week list with an empty log is still not a first run — the
        // host decides what "log" means; the state renders what it holds.
        state.apply(.weekCooksArrived([
            ProgressViewState.WeekCook(id: "c1", dayDisplay: "Thu", dishDisplay: "Curry", ratingDisplay: "5", timeDisplay: "18:40"),
        ]))
        XCTAssertFalse(state.isFirstRun)
    }

    func testFirstRunCountersRenderAsZeroNotDashes() {
        // The display derivation for the counters' parts: 0 stays "0"
        // (the view renders it in the quiet colour; no dash anywhere).
        let counters = ProgressViewState.Counters(cookedThisWeek: 0, weekStreak: 0, savedFoodGrams: 0)
        XCTAssertTrue(counters.isEmptyLog)
        XCTAssertEqual("\(counters.cookedThisWeek)", "0")
        XCTAssertEqual("\(counters.weekStreak)", "0")
    }

    // MARK: The saved-food grammar (shared with Quests)

    func testSavedFoodDisplayUsesTheSharedGrammar() {
        var state = ProgressViewState()
        state.apply(.countersArrived(ProgressViewState.Counters(
            cookedThisWeek: 3, weekStreak: 1, savedFoodGrams: 620
        )))
        XCTAssertEqual(state.savedFoodDisplay, "620 g", "below a kilogram, grams")
        state.apply(.countersArrived(ProgressViewState.Counters(
            cookedThisWeek: 3, weekStreak: 1, savedFoodGrams: 1200
        )))
        XCTAssertEqual(state.savedFoodDisplay, "1.2 kg", "at or above a kilogram, one-decimal kilograms")
    }

    // MARK: The quests CANDIDATE's flag

    func testQuestsEntryIsOffByDefaultAndTheIntentIsDropped() {
        var state = ProgressViewState()
        XCTAssertFalse(state.questsEnabled, "the candidate ships OFF")
        XCTAssertFalse(state.showsQuestsEntry, "the entry row's absence is the off state")

        state.apply(.openQuests)
        XCTAssertFalse(state.questsPresented, "a flag-off candidate cannot be reached by accident")
    }

    func testQuestsEntryPresentsOnlyWhileTheFlagIsOn() {
        var state = ProgressViewState(questsEnabled: true)
        XCTAssertTrue(state.showsQuestsEntry)
        state.apply(.openQuests)
        XCTAssertTrue(state.questsPresented)
        state.apply(.closeQuests)
        XCTAssertFalse(state.questsPresented)
    }

    // MARK: Profile presentation (Profile lives inside Progress)

    func testProfilePresentationRoundTrip() {
        var state = ProgressViewState()
        XCTAssertFalse(state.profilePresented)
        state.apply(.openProfile)
        XCTAssertTrue(state.profilePresented)
        state.apply(.closeProfile)
        XCTAssertFalse(state.profilePresented)
    }

    // MARK: Provenance

    func testAsOfProvenanceIsHostVerbatimAndNilable() {
        // The provenance line arrives with the state (the host sets it
        // when it hands the week over); there is no intent for it.
        var state = ProgressViewState(asOf: "As of 18:40")
        XCTAssertEqual(state.asOf, "As of 18:40")
        state = ProgressViewState()
        XCTAssertNil(state.asOf, "nil hides the caption")
    }
}

final class ProfileStateTests: XCTestCase {

    private func profileWithEvidence() -> ProfileViewState {
        ProfileViewState(
            householdLine: "Flat 4B · 3 people",
            tasteSummary: "23 cooks of evidence · 4 sentences learned",
            cookbookSummary: "84 cooks · ratings, swaps, notes"
        )
    }

    // MARK: The confirmation carries the size

    func testForgetConfirmLineCarriesTheSize() {
        let state = profileWithEvidence()
        XCTAssertEqual(
            state.forgetConfirmLine,
            "Forget 23 cooks of evidence · 4 sentences learned? Recipes stay; the profile empties.",
            "Forget is an informed choice, not a mystery button")
    }

    func testForgetConfirmLineIsNilWithoutTasteEvidence() {
        let state = ProfileViewState(cookbookSummary: "84 cooks")
        XCTAssertNil(state.forgetConfirmLine)
    }

    func testRequestForgetWithoutTasteEvidenceDoesNotOpenTheFlow() {
        var state = ProfileViewState(cookbookSummary: "84 cooks")
        state.apply(.requestForget)
        XCTAssertFalse(state.isConfirmingForget, "nothing to forget, nothing to confirm")
    }

    // MARK: The phase machine on the state's clock

    func testConfirmArmsTheUndoWindowFromTheStateClock() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        XCTAssertTrue(state.isConfirmingForget)
        state.apply(.confirmForget)
        guard case .forgotten(let undoUntil) = state.forgetPhase else {
            return XCTFail("confirm must reach forgotten")
        }
        XCTAssertEqual(undoUntil, 1_005, "the window is the mock's five seconds")
        XCTAssertEqual(state.forgetReceiptLine, "Forgotten.")
        XCTAssertTrue(state.isUndoAvailable, "the undo row lives while the window runs")
    }

    func testUndoWithinTheWindowRestoresEverythingExactly() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        state.apply(.confirmForget)
        state.now = 1_003
        state.apply(.undoForget)
        XCTAssertEqual(state.forgetPhase, .idle)
        XCTAssertNil(state.forgetReceiptLine)
        XCTAssertEqual(state.tasteSummary, "23 cooks of evidence · 4 sentences learned", "the evidence is exactly as it was")
        XCTAssertEqual(state.cookbookSummary, "84 cooks · ratings, swaps, notes")
    }

    func testUndoAtTheWindowBoundaryIsStillAllowed() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        state.apply(.confirmForget)
        state.now = 1_005
        state.apply(.undoForget)
        XCTAssertEqual(state.forgetPhase, .idle, "now == undoUntil is within the window")
    }

    func testUndoPastTheWindowIsRefused() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        state.apply(.confirmForget)
        state.now = 1_006
        XCTAssertFalse(state.isUndoAvailable, "the undo row stops living when the window closes")
        state.apply(.undoForget)
        XCTAssertTrue(state.isEvidenceForgotten, "the window has closed; the forget stands")
    }

    func testTickPastTheWindowClearsTheTasteEvidenceForGood() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        state.apply(.confirmForget)
        state.apply(.tick(at: 1_006))
        XCTAssertNil(state.tasteSummary, "the profile empties")
        XCTAssertEqual(state.forgetPhase, .idle)
        XCTAssertFalse(state.showsEvidenceRows, "the evidence rows stop showing")
        XCTAssertEqual(state.cookbookSummary, "84 cooks · ratings, swaps, notes", "recipes stay")
        XCTAssertFalse(state.isUndoAvailable, "an expired window offers no undo row")
    }

    func testTickInsideTheWindowKeepsTheUndoAlive() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        state.apply(.confirmForget)
        state.apply(.tick(at: 1_004))
        XCTAssertTrue(state.isUndoAvailable)
        XCTAssertNotNil(state.tasteSummary, "the evidence is hidden but not gone while the window runs")
    }

    func testTickRefreshesTheClockBeforeJudging() {
        var state = profileWithEvidence()
        state.now = 0
        state.apply(.requestForget)
        state.apply(.confirmForget)  // window: 5 ..< ends at now(0)+5
        state.apply(.tick(at: 900))
        // The tick at 900 refreshed the clock first: the undo window
        // armed at 5 is long past, so the forget stands.
        XCTAssertNil(state.tasteSummary)
    }

    func testCancelLeavesEverythingUntouched() {
        var state = profileWithEvidence()
        state.now = 1_000
        state.apply(.requestForget)
        state.apply(.cancelForget)
        XCTAssertEqual(state.forgetPhase, .idle)
        XCTAssertNotNil(state.tasteSummary)
        XCTAssertNil(state.forgetReceiptLine)
    }

    // MARK: The household of one, untold

    func testHouseholdOfOneHidesItsSection() {
        let state = ProfileViewState(tasteSummary: nil, cookbookSummary: nil)
        XCTAssertNil(state.householdLine, "a household of one, untold, is simply not shown")
    }
}
