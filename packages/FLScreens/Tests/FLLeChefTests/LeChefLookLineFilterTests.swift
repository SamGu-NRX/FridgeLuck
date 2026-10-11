// FLLeChef tests — the look-line filter (SPEC §3.1).
//
// A camera look describes what a picture can show and never gives a
// safety verdict. `LookResult` has no verdict field, but its lines are
// free text — so the state layer filters every line at the reducer's
// ingress and again in the display grammar. These tests pin the
// filter's vocabulary against the review brief's examples: the lines
// that MUST drop, the lines that MUST survive, both state gates, and
// the filter's determinism. Every test runs on Linux — the filter is
// Foundation-only.

import XCTest
@testable import FLLeChef

final class LeChefLookLineFilterTests: XCTestCase {

    // MARK: Fixtures

    private let start = TimeInterval(1_700_000_000)

    /// A session mid-cook, clock ticked to `start`.
    private func cookingState() -> LeChefViewState {
        var state = LeChefViewState()
        state.apply(.enter(
            recipe: LeChefViewState.CookRecipe(
                revisionId: "rev-1", dishName: "Honey Chilli Noodles", servings: 2,
                steps: [
                    LeChefViewState.CookStep(
                        id: "s1", name: "Heat the pan",
                        segments: [.text("Do the thing.")],
                        timerLabel: nil, timerSeconds: nil, onDoneLine: nil),
                ]),
            at: start))
        state.apply(.tick(now: start))
        return state
    }

    /// Delivers a look result mid-cook through the full lifecycle.
    private func deliverLook(
        _ lines: [String], proposalId: String = "look-1"
    ) -> LeChefViewState {
        var state = cookingState()
        state.apply(.requestLook)
        state.apply(.lookCaptured(.singleFrame))
        state.apply(.sendLook)
        state.apply(.lookResultArrived(
            LeChefViewState.LookResult(observedLines: lines), proposalId: proposalId))
        return state
    }

    // MARK: The brief's MUST-DROP lines drop.

    func testVerdictShapedLinesAreDropped() {
        let dropped = [
            // Doneness asserted.
            "Fully cooked and ready to plate",
            "The chicken is cooked through",
            "This is undercooked",
            "It is raw in the middle",
            "The sauce looks done",
            "still raw after this long",
            // Safety asserted.
            "Safe to eat now",
            "This is not safe",
            "The surface is food-safe",
            "This pan is food safe",
            // Temperature-read doneness conclusions.
            "Reads 74 °C — fully cooked",
            "Internal temperature is 165 °F, so it is done",
            "74 degrees celsius, done",
            "reads 165F internal",
            // Verdict-shaped sentences.
            "This is done",
            "Ready to eat",
            "the noodles are ready to serve",
        ]
        for line in dropped {
            XCTAssertTrue(LookLineFilter.drops(line), "must drop: \(line)")
        }
    }

    // MARK: The brief's MUST-PASS lines survive.

    func testDescriptiveLinesSurvive() {
        let kept = [
            "two pans on the burner",
            "steam from the left pot",
            "the sauce is reducing",
            "Browning on the edges of the crust",
            "the pot is boiling",
            "chopped herbs on the cutting board",
            "the onions are translucent",
        ]
        for line in kept {
            XCTAssertFalse(LookLineFilter.drops(line), "must keep: \(line)")
        }
    }

    // MARK: Every vocabulary entry earns its place.

    func testEveryVerdictPhraseDropsALineBuiltAroundIt() {
        XCTAssertFalse(LookLineFilter.verdictPhrases.isEmpty)
        for phrase in LookLineFilter.verdictPhrases {
            XCTAssertTrue(
                LookLineFilter.drops("Looks \(phrase) to me"),
                "vocabulary entry must match a line built around it: \(phrase)")
        }
    }

    // MARK: Filtered output.

    func testFilteredKeepsOrderAndDropsWholeLines() {
        XCTAssertEqual(
            LookLineFilter.filtered([
                "two pans on the burner", "fully cooked",
                "steam from the left pot", "SAFE TO EAT",
            ]),
            ["two pans on the burner", "steam from the left pot"])
    }

    func testTheFilterIsDeterministicAndIdempotent() {
        let mixed = [
            "two pans on the burner", "this is done", "steam from the left pot",
        ]
        XCTAssertEqual(LookLineFilter.filtered(mixed), LookLineFilter.filtered(mixed))
        XCTAssertEqual(
            LookLineFilter.filtered(LookLineFilter.filtered(mixed)),
            LookLineFilter.filtered(mixed))
    }

    // MARK: The two state gates.

    func testReducerIngressFiltersBeforeStateHoldsTheLines() {
        let state = deliverLook([
            "two pans on the burner", "fully cooked and safe to eat",
            "steam from the left pot",
        ])
        guard case .lookResult(let stored) = state.proposals[0].payload else {
            return XCTFail("the proposal carries the look result")
        }
        XCTAssertEqual(
            stored.observedLines, ["two pans on the burner", "steam from the left pot"],
            "state never holds a verdict-shaped line — no consumer (display, transcript, persistence, voice) can see one")
        XCTAssertTrue(state.proposals[0].isRead)
    }

    func testTheDisplayGrammarFiltersAndAlwaysPairsWhatItCannotAssess() {
        let state = deliverLook([
            "two pans on the burner", "readings 74 °C — this is done",
        ])
        XCTAssertEqual(
            state.proposalDisplay(state.proposals[0]),
            ["two pans on the burner", state.lookCannotAssessDisplay])
    }

    func testTheDisplayGrammarFiltersStateBuiltByHand() {
        var state = cookingState()
        state.proposals = [LeChefViewState.Proposal(
            id: "look-hand", job: .coach,
            payload: .lookResult(LeChefViewState.LookResult(observedLines: ["this is done"])))]
        XCTAssertEqual(
            state.proposalDisplay(state.proposals[0]),
            [state.lookCannotAssessDisplay],
            "the last gate filters even state no reducer built")
    }

    func testAFilteredAwayLookStillEndsTheLifecycleAsARead() {
        let state = deliverLook(["safe to eat"])
        XCTAssertEqual(state.lookStage, .none)
        XCTAssertEqual(state.proposals.count, 1)
        XCTAssertEqual(
            state.proposalDisplay(state.proposals[0]), [state.lookCannotAssessDisplay])
    }
}
