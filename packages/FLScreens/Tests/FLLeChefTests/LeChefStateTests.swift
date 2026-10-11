// FLLeChef tests — the cook mode's binding rules, as tests.
//
// The session is a mode, not a tab: enter from a recipe or Tonight,
// cook, complete, remember. The contracts under test (SPEC §4, §3.1,
// §3.4):
//
// - Five jobs, each with a local core — a cook progresses and completes
//   with zero connectivity.
// - Reads apply without ceremony; mutations wait for an explicit
//   approval action. Voice commands map onto the touch vocabulary and
//   can never approve a mutation, save the record, or create a timer
//   outside the local path.
// - Phone-controlled timers: set, pause, complete in the state machine;
//   a fired timer adds a check line and never advances a step.
// - Push-to-look: frame or a clip of at most 3 seconds, explicit send;
//   a look result is a READ that can never carry a safety verdict.
// - Voice is opt-in per cook, off by default; the chat fallback sits
//   behind the same toggle.
// - Nothing persists beyond the live session unless the user saves:
//   the persisted snapshot has no frame, transcript or look field by
//   construction, and the saved record carries only the rating and the
//   explicitly saved note.
//
// Fixtures are synthetic. Every test runs on Linux — the stage machine,
// timers, proposals, transcript toggle and display grammar are
// Foundation-only.

import XCTest
@testable import FLLeChef

// MARK: Fixtures (file scope — usable as default parameter values)

private let start = TimeInterval(1_700_000_000)

private func step(
    _ id: String, _ name: String, body: String = "Do the thing.",
    timerLabel: String? = nil, timerSeconds: Int? = nil, onDone: String? = nil
) -> LeChefViewState.CookStep {
    LeChefViewState.CookStep(
        id: id, name: name,
        segments: [.text(body)],
        timerLabel: timerLabel, timerSeconds: timerSeconds, onDoneLine: onDone
    )
}

/// Four steps; the last carries the mock's noodles timer shape.
private func recipe() -> LeChefViewState.CookRecipe {
    LeChefViewState.CookRecipe(
        revisionId: "rev-1", dishName: "Honey Chilli Noodles", servings: 2,
        steps: [
            step("s1", "Heat the pan"),
            step("s2", "Brown the mince", timerLabel: "Mince", timerSeconds: 300, onDone: "Mince done — drain the fat"),
            step("s3", "Sauce goes in"),
            step("s4", "Noodles in", timerLabel: "Noodles", timerSeconds: 120, onDone: "Rice done — stir the sauce in"),
        ]
    )
}

/// A session mid-cook, clock ticked to `start`.
private func cookingState(link: LeChefViewState.Link = .live) -> LeChefViewState {
    var state = LeChefViewState()
    state.link = link
    state.apply(.enter(recipe: recipe(), at: start))
    state.apply(.tick(now: start))
    return state
}

/// A session on the complete surface (all four steps done in 24 minutes).
private func completeState() -> LeChefViewState {
    var state = cookingState()
    let middle = start + 24 * 60
    state.apply(.nextStep(at: middle))
    state.apply(.nextStep(at: middle))
    state.apply(.nextStep(at: middle))
    state.apply(.nextStep(at: middle))
    return state
}

private func substitution(id: String = "swap-1") -> LeChefViewState.Proposal {
    LeChefViewState.Proposal(
        id: id, job: .substitute,
        payload: .substitution(
            name: "Swap rice vinegar for lemon juice",
            difference: "a little sharper",
            allergenRecheck: "Check with everyone — swaps can move an allergen."
        )
    )
}

private func mirrorFields(_ value: Any) -> [String] {
    Mirror(reflecting: value).children.compactMap { $0.label }
}

// MARK: - The stage machine

final class LeChefStageTests: XCTestCase {

    func testEnterStartsTheCookAtStepOne() {
        var state = LeChefViewState()
        state.apply(.enter(recipe: recipe(), at: start))
        XCTAssertEqual(state.stage, .cooking)
        XCTAssertEqual(state.stepIndex, 0)
        XCTAssertEqual(state.recipe?.dishName, "Honey Chilli Noodles")
        XCTAssertEqual(state.steps.count, 4)
        XCTAssertEqual(
            state.headerProgressDisplay(at: start), "Step 1 of 4 · 0 min in")
    }

    func testEnterOnlyFromIdle() {
        var state = cookingState()
        let before = state
        state.apply(.enter(recipe: recipe(), at: start + 10))
        XCTAssertEqual(state, before)
    }

    func testPauseAndResumeRoundTrip() {
        var state = cookingState()
        state.apply(.pauseSession)
        XCTAssertEqual(state.stage, .paused)
        state.apply(.resumeSession)
        XCTAssertEqual(state.stage, .cooking)
    }

    func testLeaveFromCookingParksTheSession() {
        var state = cookingState()
        state.apply(.leaveSession)
        XCTAssertEqual(state.stage, .paused)
        // A parked session still records — "reopen to step 4".
        XCTAssertNotNil(LeChefPersistedState.recording(state))
    }

    func testPauseKeepsTimerDeadlines() {
        var state = cookingState()
        state.apply(.setTimer(label: "Noodles", seconds: 120, onDoneLine: nil))
        let deadline = state.timers[0].endAt
        state.apply(.pauseSession)
        XCTAssertEqual(state.timers[0].endAt, deadline, "a pause never rewrites a timer")
    }

    func testCancelEndsWithNothingToRecord() {
        var state = cookingState()
        state.apply(.cancelSession)
        XCTAssertEqual(state.stage, .cancelled)
        XCTAssertNil(LeChefPersistedState.recording(state))
    }

    func testNextOnLastStepCompletesTheCook() {
        var state = completeState()
        XCTAssertEqual(state.stage, .complete)
        XCTAssertEqual(state.endedAt, start + 24 * 60)
        XCTAssertEqual(state.cookedDurationLine, "Cooked in 24 min · 2 servings")
    }

    func testCloseCompleteResetsToIdle() {
        var state = completeState()
        state.apply(.closeComplete)
        XCTAssertEqual(state.stage, .idle)
        XCTAssertNil(state.recipe)
        XCTAssertNil(LeChefPersistedState.recording(state))
    }

    func testTheFiveJobsSurfaceByStage() {
        XCTAssertEqual(LeChefViewState().activeJobs, [])
        XCTAssertEqual(cookingState().activeJobs, [.plan, .coach, .substitute, .adapt])
        XCTAssertEqual(completeState().activeJobs, [.remember])
    }

    func testEveryJobDeclaresALocalCore() {
        // The five-job contract: each job's local core is stated, and a
        // statement exists for all five — the offline surface renders it.
        XCTAssertEqual(LeChefViewState.Job.allCases.count, 5)
        for job in LeChefViewState.Job.allCases {
            XCTAssertFalse(job.localCoreLine.isEmpty)
        }
    }
}

// MARK: - The step engine

final class LeChefStepEngineTests: XCTestCase {

    func testNextAdvancesAndClearsCheckLines() {
        var state = cookingState()
        state.apply(.deliver([LeChefViewState.Proposal(id: "info-1", job: .coach, payload: .information(text: "note"))]))
        state.apply(.nextStep(at: start + 10))
        XCTAssertEqual(state.stepIndex, 1)
        XCTAssertEqual(state.currentStep?.name, "Brown the mince")
        XCTAssertEqual(state.nextStepPreview, "Sauce goes in")
    }

    func testNextFromTheLastStepIsDoneCooking() {
        var state = cookingState()
        state.apply(.nextStep(at: start))
        state.apply(.nextStep(at: start))
        state.apply(.nextStep(at: start))
        XCTAssertEqual(state.nextButtonTitle, "Done cooking")
        state.apply(.nextStep(at: start))
        XCTAssertEqual(state.stage, .complete)
    }

    func testBackNeverBeforeTheFirstStep() {
        var state = cookingState()
        state.apply(.backStep)
        XCTAssertEqual(state.stepIndex, 0)
        state.apply(.nextStep(at: start))
        state.apply(.backStep)
        XCTAssertEqual(state.stepIndex, 0)
    }

    func testJumpToAnyStepAndOutOfRangeIgnored() {
        var state = cookingState()
        state.apply(.jumpToStep(index: 2))
        XCTAssertEqual(state.stepIndex, 2)
        state.apply(.jumpToStep(index: 9))
        XCTAssertEqual(state.stepIndex, 2)
        state.apply(.jumpToStep(index: -1))
        XCTAssertEqual(state.stepIndex, 2)
        state.apply(.jumpToStep(index: 2))
        XCTAssertEqual(state.stepIndex, 2, "re-jumping to the same step is a no-op")
    }

    func testRepeatRePresentsWithoutMoving() {
        var state = cookingState()
        state.apply(.nextStep(at: start))
        state.apply(.repeatStep)
        XCTAssertEqual(state.stepIndex, 1)
    }

    func testAdaptedStepsKeepTheIndexAndClamp() {
        var state = cookingState()
        state.apply(.nextStep(at: start))
        state.apply(.nextStep(at: start))
        state.apply(.nextStep(at: start)) // index 3 of 4
        let adapted = [
            step("a1", "One thigh, baked", body: "Bake 6 min, not 8."),
            step("a2", "Rest and shred"),
        ]
        state.apply(.adaptedSteps(adapted))
        XCTAssertEqual(state.steps.count, 2)
        XCTAssertEqual(state.stepIndex, 1, "the index clamps to the last step, never out of range")
        XCTAssertEqual(state.currentStep?.name, "Rest and shred")

        // And an in-range adaptation keeps the cook where it was.
        state.apply(.adaptedSteps([
            step("b1", "One thigh, baked"), step("b2", "Rest"), step("b3", "Sauce"),
        ]))
        XCTAssertEqual(state.stepIndex, 1)
    }

    func testEnteringAStepNeverInventsATimer() {
        var state = cookingState()
        state.apply(.nextStep(at: start)) // step 2 has a natural 5-min timer
        XCTAssertTrue(state.timers.isEmpty, "a recipe timer starts when the cook starts it — never automatically")
    }
}

// MARK: - Timers (phone-controlled, local)

final class LeChefTimerTests: XCTestCase {

    func testSetTimerCreatesADeadlineFromTheLastKnownClock() {
        var state = cookingState()
        state.apply(.tick(now: start + 60))
        state.apply(.setTimer(label: "Noodles", seconds: 120, onDoneLine: "Rice done — stir the sauce in"))
        XCTAssertEqual(state.timers.count, 1)
        XCTAssertEqual(state.timers[0].endAt, start + 60 + 120)
        XCTAssertTrue(state.timers[0].isRunning)
        XCTAssertFalse(state.timers[0].isPaused)
    }

    func testTickFiresADueTimerOnceAndAddsItsCheckLine() {
        var state = cookingState()
        state.apply(.setTimer(label: "Noodles", seconds: 120, onDoneLine: "Rice done — stir the sauce in"))
        state.apply(.tick(now: start + 119))
        XCTAssertEqual(state.checkLines, [], "not due yet")
        state.apply(.tick(now: start + 120))
        XCTAssertEqual(state.timers[0].fired, true)
        XCTAssertEqual(state.timers[0].remainingSeconds(at: start + 120), 0)
        XCTAssertEqual(state.checkLines, ["Rice done — stir the sauce in"])
        state.apply(.tick(now: start + 121))
        XCTAssertEqual(state.checkLines, ["Rice done — stir the sauce in"], "a tick never fires twice")
    }

    func testAFiredTimerNeverAdvancesTheStep() {
        var state = cookingState()
        state.apply(.setTimer(label: "Noodles", seconds: 60, onDoneLine: nil))
        state.apply(.tick(now: start + 60))
        XCTAssertEqual(state.stepIndex, 0, "the timer's job is the check line, not the step")
        XCTAssertEqual(state.stage, .cooking)
    }

    func testPauseAndResumePreserveTheRemainder() {
        var state = cookingState()
        state.apply(.setTimer(label: "Noodles", seconds: 300, onDoneLine: nil))
        state.apply(.tick(now: start + 60)) // 240 left
        state.apply(.toggleTimerPause(id: state.timers[0].id))
        XCTAssertTrue(state.timers[0].isPaused)
        XCTAssertEqual(state.timers[0].remainingSeconds(at: start + 600), 240, "frozen while paused")
        state.apply(.tick(now: start + 900))
        XCTAssertFalse(state.timers[0].fired, "a paused timer never fires")
        state.apply(.toggleTimerPause(id: state.timers[0].id))
        XCTAssertEqual(state.timers[0].endAt, start + 900 + 240, "resumes from the remainder")
        state.apply(.tick(now: start + 900 + 240))
        XCTAssertEqual(state.timers[0].fired, true)
    }

    func testRemoveTimerDropsItsCheckLineToo() {
        var state = cookingState()
        state.apply(.setTimer(label: "Noodles", seconds: 60, onDoneLine: "Rice done — stir the sauce in"))
        state.apply(.tick(now: start + 60))
        XCTAssertEqual(state.checkLines.count, 1)
        state.apply(.removeTimer(id: state.timers[0].id))
        XCTAssertTrue(state.timers.isEmpty)
        XCTAssertTrue(state.checkLines.isEmpty)
    }

    func testVoiceTimerCreatesATimerThroughTheLocalPath() {
        var state = cookingState()
        state.apply(.tick(now: start))
        state.apply(.toggleTranscript)
        state.apply(.voiceCommand(.timer(seconds: 180)))
        XCTAssertEqual(state.timers.count, 1)
        XCTAssertEqual(state.timers[0].endAt, start + 180)
        XCTAssertEqual(state.timers[0].label, "Timer")
    }

    func testZeroAndNegativeTimersAreRefused() {
        var state = cookingState()
        state.apply(.setTimer(label: "Nothing", seconds: 0, onDoneLine: nil))
        state.apply(.setTimer(label: "Nothing", seconds: -5, onDoneLine: nil))
        XCTAssertTrue(state.timers.isEmpty, "no fake timers — a timer exists only when the machine created one")
    }

    func testTwoTimersGetDistinctAcknowledgements() {
        var state = cookingState()
        state.apply(.setTimer(label: "Noodles", seconds: 60, onDoneLine: nil))
        state.apply(.setTimer(label: "Eggs", seconds: 90, onDoneLine: nil))
        XCTAssertNotEqual(state.timers[0].id, state.timers[1].id)
    }
}

// MARK: - Timer clock seeding (PR #121 review BLOCK item 4)

/// Entering or re-entering a session must leave the on-screen clock
/// derived from the session's real deadlines: the host's clock seeds
/// the deadline base at `.enter`, hydration seeds the clock from the
/// persisted deadlines, and a deadline that passed while closed
/// resolves to the expired state per the timer machine — never a
/// silent zero. Every clock here is injected and fixed (epoch
/// 1,700,000,000 and nearby): had any path read the wall clock
/// instead, the arithmetic would floor to 0 and these would fail.
final class LeChefTimerSeedingTests: XCTestCase {

    /// The reviewer's exact sequence: enter at a real epoch, then set a
    /// timer BEFORE any other clock intent.
    func testEnterSeedsTheClockSoTheFirstTimerCountsFromIt() {
        var state = LeChefViewState()
        state.apply(.enter(recipe: recipe(), at: start))
        XCTAssertEqual(
            state.lastKnownNow, start,
            "enter is a clock reading — the deadline base seeds from the host clock")
        state.apply(.setTimer(label: "Noodles", seconds: 120, onDoneLine: nil))
        XCTAssertEqual(
            state.timers[0].endAt, start + 120,
            "not 120: an epoch-zero deadline rendered the timer expired at once")
        XCTAssertEqual(state.timers[0].remainingSeconds(at: start + 30), 90)
        XCTAssertFalse(state.timers[0].fired, "a future deadline is a running timer, not a fired one")
    }

    func testRestoreSeedsTheClockFromThePersistedDeadline() {
        // A 300-second timer created at start+160 (deadline start+460),
        // the app killed, reopened two minutes later at the injected clock.
        let record = LeChefPersistedState(
            stage: .cooking, revisionId: "rev-1", dishName: "Honey Chilli Noodles",
            servings: 2, stepIndex: 3, startedAt: start,
            timers: [LeChefPersistedState.TimerRecord(
                id: "timer-1", label: "Noodles", totalSeconds: 300, endAt: start + 460
            )],
            appliedSwapIds: []
        )
        let now = start + 320
        let reopened = LeChefViewState(restoring: record, steps: recipe().steps, at: now)
        XCTAssertEqual(reopened.lastKnownNow, now, "hydration is a clock reading")
        XCTAssertEqual(
            reopened.timers[0].remainingSeconds(at: now), 140,
            "deadline − now, seeded from the persisted deadline")
        XCTAssertEqual(
            reopened.timers[0].remainingSeconds(at: start + 380), 80,
            "still counting from the same deadline")
        XCTAssertTrue(reopened.timers[0].isRunning)
    }

    func testRestoreResolvesAPassedDeadlineToTheExpiredState() {
        // The deadline passed while the app was closed: hydration runs
        // the timer machine's own firing rule — fired, check line
        // earned — never a silent running 0:00.
        let record = LeChefPersistedState(
            stage: .cooking, revisionId: "rev-1", dishName: "Honey Chilli Noodles",
            servings: 2, stepIndex: 3, startedAt: start,
            timers: [LeChefPersistedState.TimerRecord(
                id: "timer-1", label: "Noodles", totalSeconds: 300,
                endAt: start + 100, onDoneLine: "Rice done — stir the sauce in"
            )],
            appliedSwapIds: []
        )
        let reopened = LeChefViewState(restoring: record, steps: recipe().steps, at: start + 160)
        XCTAssertTrue(
            reopened.timers[0].fired,
            "a passed deadline resolves to the expired state, not a silent zero")
        XCTAssertNil(reopened.timers[0].endAt)
        XCTAssertEqual(reopened.timers[0].remainingSeconds(at: start + 160), 0)
        XCTAssertEqual(
            reopened.checkLines, ["Rice done — stir the sauce in"],
            "the firing rule's check line, earned exactly once")
    }

    func testRestoreKeepsATimerWithNoDeadlineUntouched() {
        // No persisted deadline: nothing is invented — no fake clock,
        // no fake fire; the timer keeps its current presentation.
        let record = LeChefPersistedState(
            stage: .cooking, revisionId: "rev-1", dishName: "Honey Chilli Noodles",
            servings: 2, stepIndex: 3, startedAt: start,
            timers: [LeChefPersistedState.TimerRecord(
                id: "timer-1", label: "Noodles", totalSeconds: 300
            )],
            appliedSwapIds: []
        )
        let reopened = LeChefViewState(restoring: record, steps: recipe().steps, at: start + 320)
        XCTAssertNil(reopened.timers[0].endAt)
        XCTAssertNil(reopened.timers[0].pausedRemaining)
        XCTAssertFalse(reopened.timers[0].fired, "no deadline is never invented into a fire")
        XCTAssertTrue(reopened.checkLines.isEmpty)
    }

    func testRestoreKeepsPausedAndFiredRecordsExactly() {
        // Paused: the frozen remainder is the clock, at any `now`.
        // Fired: stays fired, and hydration never restates its check
        // line — the machine's lines re-earn on the live path or not at
        // all.
        let record = LeChefPersistedState(
            stage: .cooking, revisionId: "rev-1", dishName: "Honey Chilli Noodles",
            servings: 2, stepIndex: 3, startedAt: start,
            timers: [
                LeChefPersistedState.TimerRecord(
                    id: "timer-1", label: "Noodles", totalSeconds: 300, pausedRemaining: 240
                ),
                LeChefPersistedState.TimerRecord(
                    id: "timer-2", label: "Eggs", totalSeconds: 60, fired: true,
                    onDoneLine: "Eggs done"
                ),
            ],
            appliedSwapIds: []
        )
        let reopened = LeChefViewState(restoring: record, steps: recipe().steps, at: start + 320)
        XCTAssertTrue(reopened.timers[0].isPaused)
        XCTAssertEqual(
            reopened.timers[0].remainingSeconds(at: start + 320), 240,
            "frozen at the persisted remainder")
        XCTAssertTrue(reopened.timers[1].fired)
        XCTAssertTrue(
            reopened.checkLines.isEmpty,
            "hydration never restates a fired record's check line")
    }
}

// MARK: - Proposals: reads vs. approved mutations

final class LeChefProposalTests: XCTestCase {

    func testReadsApplyWithoutCeremony() {
        var state = cookingState()
        let read = LeChefViewState.Proposal(id: "info-1", job: .coach, payload: .information(text: "Sauce first tonight."))
        state.apply(.deliver([read]))
        XCTAssertEqual(state.proposals.first?.id, "info-1")
        XCTAssertEqual(state.proposals.first?.isRead, true)
        XCTAssertEqual(state.proposalDisplay(state.proposals[0]), ["Sauce first tonight."])
    }

    func testAMutationWaitsForAnExplicitApproval() {
        var state = cookingState()
        state.apply(.deliver([substitution()]))
        XCTAssertEqual(state.proposals[0].isApplied, false, "delivery never applies a mutation")
        state.apply(.approveProposal(id: "swap-1"))
        XCTAssertEqual(state.proposals[0].isApplied, true)
    }

    func testApprovalIsTheOnlyMutationPath() {
        // Everything else the session can send must leave a pending
        // mutation pending.
        var state = cookingState()
        state.apply(.deliver([substitution()]))
        let before = state
        state.apply(.nextStep(at: start))
        state.apply(.deliver([substitution()]))
        state.apply(.mutationFailed(id: "swap-1"))
        state.apply(.applyTimerSuggestion(id: "swap-1"))
        XCTAssertEqual(state.proposals.first?.isApplied, false)
        _ = before
    }

    func testVoiceCommandsCanNeverApproveAMutation() {
        var state = cookingState()
        state.apply(.deliver([substitution()]))
        state.apply(.toggleTranscript)
        state.apply(.voiceCommand(.next))
        state.apply(.voiceCommand(.back))
        state.apply(.voiceCommand(.repeatStep))
        state.apply(.voiceCommand(.show(step: 1)))
        state.apply(.voiceCommand(.timer(seconds: 60)))
        XCTAssertEqual(state.proposals.first?.isApplied, false, "the five-word grammar maps to touch intents — approval is not in it")
    }

    func testRedeliveryIsIdempotent() {
        var state = cookingState()
        let read = LeChefViewState.Proposal(id: "info-1", job: .coach, payload: .information(text: "Sauce first tonight."))
        state.apply(.deliver([read]))
        state.apply(.deliver([read]))
        state.apply(.deliver([read]))
        XCTAssertEqual(state.proposals.count, 1)
    }

    func testDeclineRemovesTheProposal() {
        var state = cookingState()
        state.apply(.deliver([substitution()]))
        state.apply(.declineProposal(id: "swap-1"))
        XCTAssertTrue(state.proposals.isEmpty)
    }

    func testAnApprovedMutationThatFailsReturnsToPendingWithAQuietLine() {
        var state = cookingState()
        state.apply(.deliver([substitution()]))
        state.apply(.approveProposal(id: "swap-1"))
        state.apply(.mutationFailed(id: "swap-1"))
        XCTAssertEqual(state.proposals[0].isApplied, false, "the proposal returns to pending — nothing was altered")
        XCTAssertFalse(state.mutationFailureLine?.isEmpty ?? true)
    }

    func testApprovingAReadIsANoOp() {
        var state = cookingState()
        let read = LeChefViewState.Proposal(id: "info-1", job: .coach, payload: .information(text: "Sauce first tonight."))
        state.apply(.deliver([read]))
        state.apply(.approveProposal(id: "info-1"))
        XCTAssertEqual(state.proposals[0].isRead, true)
    }

    func testTheTimerSuggestionChipRoutesToTheLocalTimerPath() {
        // The suggestion is a READ: its chip creates the timer through
        // the same local setTimer path as the add-tile — no approval,
        // and nothing executes from the proposal itself.
        var state = cookingState()
        state.apply(.tick(now: start))
        let suggestion = LeChefViewState.Proposal(
            id: "ts-1", job: .coach, payload: .timerSuggestion(seconds: 120, label: "Check the noodles"))
        state.apply(.deliver([suggestion]))
        XCTAssertEqual(state.proposalDisplay(state.proposals[0]), ["Want a 2 min timer to check again?"])
        state.apply(.applyTimerSuggestion(id: "ts-1"))
        XCTAssertTrue(state.proposals.isEmpty)
        XCTAssertEqual(state.timers.count, 1)
        XCTAssertEqual(state.timers[0].endAt, start + 120)
        XCTAssertEqual(state.timers[0].label, "Check the noodles")
    }

    func testASubstitutionDescribesTheDifferenceAndRechecksAllergens() {
        // SPEC 3.1: swaps describe the difference and never promise
        // "no change"; the recheck line is part of the display.
        var state = cookingState()
        state.apply(.deliver([substitution()]))
        let lines = state.proposalDisplay(state.proposals[0])
        XCTAssertEqual(lines, [
            "Swap rice vinegar for lemon juice",
            "a little sharper",
            "Check with everyone — swaps can move an allergen.",
        ])
    }
}

// MARK: - The camera look (push-to-look)

final class LeChefLookTests: XCTestCase {

    func testOnlyPushToLookIsBuilt() {
        // Continuous camera + voice is the round's other candidate —
        // flagged, not built. The built set says so.
        XCTAssertEqual(LeChefViewState.CameraCandidate.built, [.pushToLook])
        XCTAssertFalse(LeChefViewState.CameraCandidate.continuousVoice.isBuilt)
    }

    func testAClipRunsAtMostThreeSeconds() {
        XCTAssertTrue(LeChefViewState.LookCapture.singleFrame.isValid)
        XCTAssertTrue(LeChefViewState.LookCapture.clip(seconds: 1).isValid)
        XCTAssertTrue(LeChefViewState.LookCapture.clip(seconds: 3).isValid, "3 seconds is the cap")
        XCTAssertFalse(LeChefViewState.LookCapture.clip(seconds: 4).isValid)
        XCTAssertFalse(LeChefViewState.LookCapture.clip(seconds: 0).isValid)
    }

    func testTheLookLifecycleRunsRequestCaptureSendResult() {
        var state = cookingState()
        state.apply(.requestLook)
        XCTAssertEqual(state.lookStage, .viewfinder)
        state.apply(.lookCaptured(.singleFrame))
        XCTAssertEqual(state.lookStage, .captured)
        state.apply(.sendLook)
        XCTAssertEqual(state.lookStage, .uploading)
        state.apply(.lookResultArrived(
            LeChefViewState.LookResult(observedLines: ["The noodles look glossy and loose."]),
            proposalId: "look-1"
        ))
        XCTAssertEqual(state.lookStage, .none, "the lifecycle ends; the result lives in the queue")
        XCTAssertEqual(state.proposals.count, 1)
        XCTAssertEqual(state.proposals[0].isRead, true)
    }

    func testAnOverLongClipIsRefusedNotTrimmed() {
        var state = cookingState()
        state.apply(.requestLook)
        state.apply(.lookCaptured(.clip(seconds: 9)))
        XCTAssertEqual(state.lookStage, .viewfinder, "refused — nothing sent")
        XCTAssertEqual(state.lookProblem, .clipTooLong)
        XCTAssertTrue(state.lookProblemDisplay?.contains("3 seconds") ?? false)
    }

    func testALookResultIsAppliedAsAReadAndPairsWithWhatItCannotAssess() {
        var state = cookingState()
        state.apply(.requestLook)
        state.apply(.lookCaptured(.singleFrame))
        state.apply(.sendLook)
        state.apply(.lookResultArrived(
            LeChefViewState.LookResult(observedLines: ["Sauce has thickened."]),
            proposalId: "look-1"
        ))
        let lines = state.proposalDisplay(state.proposals[0])
        XCTAssertEqual(lines, ["Sauce has thickened.", state.lookCannotAssessDisplay])
        XCTAssertTrue(lines[1].contains("can't check doneness or safety"))
    }

    func testALookFailureEscapesAndRetries() {
        var state = cookingState()
        state.apply(.requestLook)
        state.apply(.lookCaptured(.singleFrame))
        state.apply(.sendLook)
        state.apply(.lookFailed)
        XCTAssertEqual(state.lookStage, .failed)
        XCTAssertEqual(state.lookProblem, .sendFailed)
        state.apply(.retryLook)
        XCTAssertEqual(state.lookStage, .uploading)
    }

    func testCancellingALookSendsNothing() {
        var state = cookingState()
        state.apply(.requestLook)
        state.apply(.lookCaptured(.singleFrame))
        state.apply(.cancelLook)
        XCTAssertEqual(state.lookStage, .none)
        XCTAssertTrue(state.proposals.isEmpty)
        XCTAssertNil(state.lookProblem)
    }

    func testTheLookCannotStartOutsideASessionOrTwice() {
        var state = LeChefViewState()
        state.apply(.requestLook)
        XCTAssertEqual(state.lookStage, .none)
        state = cookingState()
        state.apply(.requestLook)
        state.apply(.requestLook)
        XCTAssertEqual(state.lookStage, .viewfinder, "one look at a time")
    }
}

// MARK: - Voice and the transcript (opt-in per cook)

final class LeChefVoiceTests: XCTestCase {

    func testVoiceIsOffByDefault() {
        let state = cookingState()
        XCTAssertFalse(state.isTranscriptOn, "'Just the steps' is the default until a cost budget exists")
        XCTAssertEqual(state.voiceHintDisplay, nil)
        XCTAssertEqual(state.voiceOffDisplay, "Voice off — Just the steps")
    }

    func testTurningOnShowsTheGrammarAndTurningOffDropsTheTranscript() {
        var state = cookingState()
        state.apply(.toggleTranscript)
        XCTAssertTrue(state.isTranscriptOn)
        XCTAssertEqual(
            state.voiceHintDisplay,
            "Listening. Say next, back, repeat, show, or timer 3 minutes.")
        state.apply(.transcriptAppended(speaker: .you, text: "next"))
        state.apply(.toggleTranscript)
        XCTAssertFalse(state.isTranscriptOn)
        XCTAssertTrue(state.transcript.isEmpty, "off means just the steps — nothing held")
    }

    func testChatIsTheFallbackBehindTheToggle() {
        var state = cookingState()
        state.apply(.sendChat(text: "Can I use dried noodles?"))
        XCTAssertTrue(state.transcript.isEmpty, "with the toggle off there is no chat")
        state.apply(.toggleTranscript)
        state.apply(.sendChat(text: "Can I use dried noodles?"))
        XCTAssertEqual(state.transcript.count, 1)
        XCTAssertEqual(state.transcript[0].speaker, .you)
        state.apply(.transcriptAppended(speaker: .lechef, text: "Yes — soak them 4 minutes first."))
        XCTAssertEqual(state.transcript.count, 2)
    }

    func testVoiceCommandsAreIgnoredWhileTheTranscriptIsOff() {
        var state = cookingState()
        state.apply(.voiceCommand(.next))
        XCTAssertEqual(state.stepIndex, 0, "voice off means nothing listens")
        state.apply(.voiceCommand(.timer(seconds: 60)))
        XCTAssertTrue(state.timers.isEmpty)
    }

    func testTheFiveWordsMapOntoTouchOperations() {
        var state = cookingState()
        state.apply(.toggleTranscript)
        state.apply(.voiceCommand(.next))
        XCTAssertEqual(state.stepIndex, 1)
        state.apply(.voiceCommand(.back))
        XCTAssertEqual(state.stepIndex, 0)
        state.apply(.voiceCommand(.show(step: 3)))
        XCTAssertEqual(state.stepIndex, 2, "'show step N' jumps")
        state.apply(.voiceCommand(.show(step: nil)))
        XCTAssertEqual(state.stepIndex, 2, "a bare 'show' re-presents")
        state.apply(.voiceCommand(.repeatStep))
        XCTAssertEqual(state.stepIndex, 2)
    }

    func testTheOfflineVoiceGrammarIsOnDevice() {
        var state = cookingState(link: .offline)
        state.apply(.toggleTranscript)
        XCTAssertEqual(
            state.voiceHintDisplay,
            "On-device listening. Say: next · back · repeat · timer N minutes · show")
        XCTAssertEqual(state.offlineNoticeDisplay, "LeChef is offline. Steps and timers still work.")
    }
}

// MARK: - Remember (rating, note, receipt)

final class LeChefRememberTests: XCTestCase {

    func testRatingsStayInTheFiveStarRange() {
        var state = completeState()
        state.apply(.setRating(6))
        XCTAssertNil(state.rating)
        state.apply(.setRating(0))
        XCTAssertNil(state.rating)
        state.apply(.setRating(4))
        XCTAssertEqual(state.rating, 4)
    }

    func testTheNoteIsADraftUntilTheExplicitSave() {
        var state = completeState()
        state.apply(.editNoteDraft("Half the chilli next time."))
        XCTAssertNil(state.savedNote, "a draft is not a save")
        state.apply(.saveRecord)
        XCTAssertEqual(state.savedNote, "Half the chilli next time.")
        XCTAssertTrue(state.isSavingRecord)
        state.apply(.recordSaved)
        XCTAssertTrue(state.showsSaveReceipt)
        XCTAssertEqual(state.saveReceiptDisplay, "Saved on this phone.")
    }

    func testAVoiceTranscriptionIsADraftTheUserConfirms() {
        var state = completeState()
        state.apply(.draftVoiceNote("Less soy, more lime."))
        XCTAssertEqual(state.noteDraft, "Less soy, more lime.")
        XCTAssertNil(state.savedNote, "a transcript alone never saves — the explicit save does")
        state.apply(.saveRecord)
        XCTAssertEqual(state.savedNote, "Less soy, more lime.")
    }

    func testAnEmptyVoiceDraftIsRefused() {
        var state = completeState()
        state.apply(.draftVoiceNote("   "))
        XCTAssertNil(state.noteDraft)
    }

    func testSavingWithNothingToSaveIsANoOp() {
        var state = completeState()
        state.apply(.saveRecord)
        XCTAssertFalse(state.isSavingRecord)
    }

    func testADoubleSaveIsIgnoredWhileInFlight() {
        var state = completeState()
        state.apply(.setRating(5))
        state.apply(.saveRecord)
        state.apply(.saveRecord)
        XCTAssertTrue(state.isSavingRecord)
        XCTAssertEqual(state.savedNote, nil)
    }

    func testAFailedSaveKeepsEverythingAndExplainsQuietly() {
        var state = completeState()
        state.apply(.setRating(3))
        state.apply(.editNoteDraft("Watch the noodles."))
        state.apply(.saveRecord)
        state.apply(.recordSaveFailed)
        XCTAssertFalse(state.saveFailed == false)
        XCTAssertEqual(state.rating, 3)
        XCTAssertEqual(state.savedNote, "Watch the noodles.")
        XCTAssertFalse(state.showsSaveReceipt)
    }

    func testEditingAgainAfterAResetClearsTheReceipt() {
        var state = completeState()
        state.apply(.editNoteDraft("Fine."))
        state.apply(.saveRecord)
        state.apply(.recordSaved)
        XCTAssertTrue(state.showsSaveReceipt)
        state.apply(.editNoteDraft("Fine — but toast the sesame."))
        XCTAssertFalse(state.showsSaveReceipt)
    }
}

// MARK: - Offline: a whole cook completes with zero connectivity

final class LeChefOfflineTests: XCTestCase {

    func testAFullCookProgressesAndCompletesOffline() {
        var state = cookingState(link: .offline)
        state.apply(.toggleTranscript) // opt-in voice, on-device grammar

        // Steps and local timers work with no link.
        state.apply(.nextStep(at: start + 10))
        state.apply(.setTimer(label: "Mince", seconds: 120, onDoneLine: "Mince done — drain the fat"))
        state.apply(.tick(now: start + 130))
        XCTAssertEqual(state.checkLines, ["Mince done — drain the fat"])
        state.apply(.nextStep(at: start + 140))
        state.apply(.nextStep(at: start + 150))
        state.apply(.nextStep(at: start + 160))

        // The reviewed swap table still proposes offline; approval is local.
        state.apply(.deliver([substitution()]))
        state.apply(.approveProposal(id: "swap-1"))
        XCTAssertEqual(state.proposals.first?.isApplied, true)

        XCTAssertEqual(state.stage, .complete)
        XCTAssertEqual(state.endedAt, start + 160)
        XCTAssertEqual(state.cookedDurationLine, "Cooked in 2 min · 2 servings")

        // The remember surface saves on this phone, with a receipt.
        state.apply(.setRating(5))
        state.apply(.saveRecord)
        state.apply(.recordSaved)
        XCTAssertTrue(state.showsSaveReceipt)
    }
}

// MARK: - Persistence: no frames, no transcripts, by construction

final class LeChefPersistenceTests: XCTestCase {

    func testThePersistedSnapshotHasExactlyTheDeclaredFields() {
        // The allowlist, asserted: scalars, timer records, applied swap
        // ids, and the explicitly saved rating and note. Nothing else —
        // a new live-only field cannot sneak through.
        let fields = mirrorFields(LeChefPersistedState(
            stage: .cooking, revisionId: "r", dishName: "d", servings: 2,
            stepIndex: 0, startedAt: 0, timers: [], appliedSwapIds: []
        ))
        XCTAssertEqual(fields, [
            "stage", "revisionId", "dishName", "servings", "stepIndex",
            "startedAt", "timers", "appliedSwapIds", "rating", "savedNote",
        ])
    }

    func testALiveSessionFullOfTransientDataRecordsClean() {
        var state = cookingState()
        state.apply(.toggleTranscript)
        state.apply(.sendChat(text: "words I said out loud"))
        state.apply(.transcriptAppended(speaker: .lechef, text: "an answer"))
        state.apply(.requestLook)
        state.apply(.lookCaptured(.singleFrame))
        state.apply(.sendLook)
        state.apply(.lookResultArrived(LeChefViewState.LookResult(observedLines: ["a picture's reading"]), proposalId: "look-1"))
        state.apply(.editNoteDraft("not saved yet"))
        state.apply(.deliver([substitution()]))
        state.apply(.approveProposal(id: "swap-1"))

        let recording = LeChefPersistedState.recording(state)
        XCTAssertNotNil(recording)
        let text = String(describing: recording)
        for leaked in ["words I said out loud", "an answer", "a picture's reading", "not saved yet"] {
            XCTAssertFalse(text.contains(leaked), "the snapshot must not carry: \(leaked)")
        }
        XCTAssertEqual(recording?.appliedSwapIds, ["swap-1"], "approved swaps ride the snapshot")
    }

    func testRecordingIsNilForIdleAndCancelled() {
        XCTAssertNil(LeChefPersistedState.recording(LeChefViewState()))
        var state = cookingState()
        state.apply(.cancelSession)
        XCTAssertNil(LeChefPersistedState.recording(state))
    }

    func testKillAtStepFourReopensToStepFourWithTheTimerStillCounting() {
        var state = cookingState()
        state.apply(.nextStep(at: start + 10))
        state.apply(.nextStep(at: start + 20))
        state.apply(.nextStep(at: start + 30)) // step 4 — the mock's scene
        state.apply(.setTimer(label: "Noodles", seconds: 300, onDoneLine: "Rice done — stir the sauce in"))
        state.apply(.tick(now: start + 40))

        let recording = LeChefPersistedState.recording(state)
        XCTAssertNotNil(recording)
        XCTAssertEqual(recording?.stepIndex, 3)
        XCTAssertEqual(recording?.timers.count, 1)

        // Reopen two minutes later: the same step, the timer still
        // counting from its epoch deadline. Arithmetic: the timer was
        // created after nextStep(at: start+30), and any timestamped
        // intent is a clock reading — so endAt = start+30+300 =
        // start+330; remaining at start+160 is 170.
        let reopened = LeChefViewState(
            restoring: recording!, steps: recipe().steps, at: start + 40 + 120
        )
        XCTAssertEqual(reopened.stage, .cooking)
        XCTAssertEqual(reopened.stepIndex, 3)
        XCTAssertEqual(reopened.timers[0].remainingSeconds(at: start + 160), 170)
        XCTAssertFalse(reopened.isTranscriptOn, "voice is opt-in PER COOK — a reopen starts silent again")
        XCTAssertTrue(reopened.transcript.isEmpty)
        XCTAssertEqual(reopened.checkLines, [], "fired check lines re-earn themselves on the next tick, never restated")
    }

    func testACompletedSessionReopensWithItsExplicitRecord() {
        var state = completeState()
        state.apply(.setRating(5))
        state.apply(.editNoteDraft("Toast the sesame."))
        state.apply(.saveRecord)
        state.apply(.recordSaved)

        let recording = LeChefPersistedState.recording(state)
        XCTAssertEqual(recording?.stage, .complete)
        XCTAssertEqual(recording?.rating, 5)
        XCTAssertEqual(recording?.savedNote, "Toast the sesame.")

        let reopened = LeChefViewState(restoring: recording!, steps: recipe().steps, at: start + 2000)
        XCTAssertEqual(reopened.stage, .complete)
        XCTAssertEqual(reopened.rating, 5)
        XCTAssertEqual(reopened.savedNote, "Toast the sesame.")
        XCTAssertNil(
            reopened.cookedDurationLine,
            "endedAt is live-session state and the snapshot is deliberately minimal — a restored complete surface never restates a duration it did not save")
    }

    func testADraftNoteNeverRidesTheSnapshot() {
        var state = completeState()
        state.apply(.editNoteDraft("still deciding"))
        let recording = LeChefPersistedState.recording(state)
        XCTAssertNil(recording?.savedNote)
        XCTAssertFalse(String(describing: recording).contains("still deciding"))
    }
}

// MARK: - Display grammar

final class LeChefDisplayTests: XCTestCase {

    func testTheHeaderProgressLine() {
        let state = cookingState()
        XCTAssertEqual(state.headerProgressDisplay(at: start + 11 * 60), "Step 1 of 4 · 11 min in")
        XCTAssertNil(LeChefViewState().headerProgressDisplay(at: start), "no line before a session exists")
    }

    func testVoiceHintsAndNotices() {
        let live = cookingState()
        XCTAssertEqual(live.voiceOffDisplay, "Voice off — Just the steps")
        let offline = cookingState(link: .offline)
        XCTAssertEqual(offline.offlineNoticeDisplay, "LeChef is offline. Steps and timers still work.")
        XCTAssertEqual(LeChefViewState().offlineNoticeDisplay, nil)
    }

    func testTimerSuggestionTitlesSpeakInWholeMinutesOrSeconds() {
        let state = cookingState()
        XCTAssertEqual(state.timerSuggestionTitle(seconds: 120), "Set 2 min timer")
        XCTAssertEqual(state.timerSuggestionTitle(seconds: 60), "Set 1 min timer")
        XCTAssertEqual(state.timerSuggestionTitle(seconds: 90), "Set 90 sec timer")
    }

    func testTheLookContractCaptions() {
        let state = cookingState()
        XCTAssertEqual(
            state.lookCaptionDisplay,
            "Camera look: one frame, viewfinder visible, never a safety verdict.")
        XCTAssertEqual(
            state.lookCannotAssessDisplay,
            "A look can't check doneness or safety — the thermometer decides.")
    }

    func testTheCompleteSurfaceCopy() {
        let state = completeState()
        XCTAssertEqual(state.completeSubtitle, "Saved on this phone. Sharing is a separate choice.")
        XCTAssertEqual(state.privacyLine, "Nothing is shared until you choose to.")
        XCTAssertEqual(state.cookedDurationLine, "Cooked in 24 min · 2 servings")
    }

    func testTheNutritionLineIsHostVerbatimNeverDerived() {
        var state = completeState()
        XCTAssertNil(state.nutritionLine)
        let line = "About 520 kcal per serving · logged 9 of your 14 meals this week"
        state.nutritionLine = line
        XCTAssertEqual(state.nutritionLine, line)
    }
}
