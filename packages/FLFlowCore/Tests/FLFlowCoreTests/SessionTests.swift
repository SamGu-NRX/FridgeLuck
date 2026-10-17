import XCTest
import Foundation
import FLDomain
@testable import FLFlowCore

// MARK: - Cook session
// Legality of every transition, the timer acknowledgment invariant, and
// recovery from a bare checkpoint after a restart. The acknowledgment rule
// is the assistant-authority core: a timer not created on this device can
// never be acknowledged here.

final class SessionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeRevision(steps: [Step]? = nil) -> RecipeRevision {
        TestBuilders.revision(
            "galette",
            lines: [TestBuilders.line("l1", "flour", TestBuilders.grams(250))],
            steps: steps
        )
    }

    private func startSession(steps: [Step]? = nil, at now: Date? = nil) throws -> CookSession {
        try CookSession.start(
            sessionID: "sess-1",
            revision: makeRevision(steps: steps),
            now: now ?? t0
        )
    }

    // MARK: Start

    func testStartBeginsAtFirstStepWithNothingCompleted() throws {
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        XCTAssertEqual(session.stage, .cooking)
        XCTAssertEqual(session.checkpoint.stepIndex, 0)
        XCTAssertEqual(session.currentStepID, "s1")
        XCTAssertEqual(session.checkpoint.completedStepIDs, [])
        XCTAssertEqual(session.checkpoint.updatedAt, t0)
    }

    func testStartRefusesRecipeWithoutSteps() {
        // FLDomain itself refuses a stepless revision at construction, so
        // start's guard is defense in depth; the reachable contract is that
        // every session begins from a validated revision.
        XCTAssertThrowsError(try RecipeRevision(
            key: TestBuilders.recipeKey("r-empty"),
            title: "No steps",
            servingBasis: try! ServingBasis(servings: 2),
            ingredientLines: [],
            steps: [],
            source: RecipeSourceEvidence(origin: .catalog, attribution: nil, license: TestBuilders.clearLicense())
        ))
    }

    func testTransitionsLeaveTheOriginalSessionUntouched() throws {
        // The session is a value: every transition returns a new one.
        let original = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        _ = try original.completeStep(now: t0.addingTimeInterval(10))
        _ = try original.pause(now: t0.addingTimeInterval(20))
        XCTAssertEqual(original.stage, .cooking)
        XCTAssertEqual(original.checkpoint.completedStepIDs, [])
        XCTAssertEqual(original.checkpoint.stepIndex, 0)
    }

    // MARK: Steps

    func testCompleteStepAdvancesAndRecordsTheCompletedStep() throws {
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        let next = try session.completeStep(now: t0.addingTimeInterval(300))
        XCTAssertEqual(next.stage, .cooking)
        XCTAssertEqual(next.checkpoint.stepIndex, 1)
        XCTAssertEqual(next.checkpoint.completedStepIDs, ["s1"])
        XCTAssertEqual(next.currentStepID, "s2")
        XCTAssertEqual(next.checkpoint.updatedAt, t0.addingTimeInterval(300))
    }

    func testCompletingTheLastStepFinishesTheSession() throws {
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        let afterFirst = try session.completeStep(now: t0.addingTimeInterval(300))
        let afterLast = try afterFirst.completeStep(now: t0.addingTimeInterval(600))
        XCTAssertEqual(afterLast.stage, .finished)
        XCTAssertEqual(afterLast.checkpoint.completedStepIDs, ["s1", "s2"])
        XCTAssertNil(afterLast.currentStepID)
    }

    func testCompleteStepIsRefusedWhenPaused() throws {
        let paused = try startSession().pause(now: t0.addingTimeInterval(10))
        XCTAssertThrowsError(try paused.completeStep(now: t0.addingTimeInterval(20))) { error in
            XCTAssertEqual(error as? FLFlowError, .invalidTransition(phase: "paused", operation: "completeStep"))
        }
    }

    func testCompleteStepIsRefusedAfterFinish() throws {
        let finished = try startSession(steps: [TestBuilders.step("s1")]).completeStep(now: t0.addingTimeInterval(10))
        XCTAssertThrowsError(try finished.completeStep(now: t0.addingTimeInterval(20))) { error in
            XCTAssertEqual(error as? FLFlowError, .invalidTransition(phase: "finished", operation: "completeStep"))
        }
    }

    func testSkippingAheadMovesWithoutCompletingTheSkippedStep() throws {
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2"), TestBuilders.step("s3")])
        let skipped = try session.advanceTo(stepIndex: 2, now: t0.addingTimeInterval(60))
        XCTAssertEqual(skipped.checkpoint.stepIndex, 2)
        XCTAssertEqual(skipped.checkpoint.completedStepIDs, [])
        // Backwards and out of range are refused.
        XCTAssertThrowsError(try skipped.advanceTo(stepIndex: 0, now: t0.addingTimeInterval(70))) { error in
            XCTAssertEqual(error as? FLFlowError, .stepOutOfBounds(stepIndex: 0, stepCount: 3))
        }
        XCTAssertThrowsError(try session.advanceTo(stepIndex: 3, now: t0.addingTimeInterval(70))) { error in
            XCTAssertEqual(error as? FLFlowError, .stepOutOfBounds(stepIndex: 3, stepCount: 3))
        }
    }

    // MARK: Pause and resume

    func testPauseAndResumeRoundTrip() throws {
        let paused = try startSession().pause(now: t0.addingTimeInterval(10))
        XCTAssertEqual(paused.stage, .paused)
        let resumed = try paused.resume(now: t0.addingTimeInterval(60))
        XCTAssertEqual(resumed.stage, .cooking)
        XCTAssertEqual(resumed.checkpoint.completedStepIDs, [])
    }

    func testResumeIsRefusedWhenNotPaused() {
        XCTAssertThrowsError(try startSession().resume(now: t0.addingTimeInterval(10))) { error in
            XCTAssertEqual(error as? FLFlowError, .invalidTransition(phase: "cooking", operation: "resume"))
        }
    }

    func testPauseIsRefusedAfterFinish() throws {
        let finished = try startSession(steps: [TestBuilders.step("s1")]).completeStep(now: t0.addingTimeInterval(10))
        XCTAssertThrowsError(try finished.pause(now: t0.addingTimeInterval(20))) { error in
            XCTAssertEqual(error as? FLFlowError, .invalidTransition(phase: "finished", operation: "pause"))
        }
    }

    // MARK: Timers

    func testDeviceCreatedTimerCanBeAcknowledgedOnceIdempotently() throws {
        let session = try startSession()
        let withTimer = try session.addTimer(
            id: "t1",
            label: "bake",
            deadline: t0.addingTimeInterval(600),
            now: t0.addingTimeInterval(5)
        )
        XCTAssertFalse(withTimer.checkpoint.timers[0].acknowledged)
        let acked = try withTimer.acknowledgeTimer(id: "t1", now: t0.addingTimeInterval(60))
        XCTAssertTrue(acked.checkpoint.timers[0].acknowledged)
        XCTAssertTrue(acked.checkpoint.timers[0].createdOnDevice)
        // A second acknowledgment changes nothing.
        let again = try acked.acknowledgeTimer(id: "t1", now: t0.addingTimeInterval(70))
        XCTAssertEqual(again, acked)
    }

    func testForeignTimerCanNeverBeAcknowledged() throws {
        // A timer synced from another device: createdOnDevice is false, and
        // no path in this engine may acknowledge it.
        let revision = makeRevision()
        let foreignTimer = try CookingSessionCheckpoint.TimerRecord(
            id: "t1",
            label: "chill",
            deadlineEpochSeconds: t0.addingTimeInterval(600).timeIntervalSince1970,
            createdOnDevice: false,
            acknowledged: false
        )
        let checkpoint = try CookingSessionCheckpoint(
            sessionID: "sess-1",
            recipeRevision: revision.key,
            stepIndex: 0,
            completedStepIDs: [],
            timers: [foreignTimer],
            updatedAt: t0
        )
        let reinstated = try CookSession.reinstate(checkpoint: checkpoint, stepIDs: ["s1"], now: t0.addingTimeInterval(5))
        XCTAssertEqual(reinstated.stage, .cooking)
        XCTAssertThrowsError(try reinstated.acknowledgeTimer(id: "t1", now: t0.addingTimeInterval(10))) { error in
            XCTAssertEqual(error as? FLFlowError, .timerNotCreatedOnDevice(timerID: "t1"))
        }
    }

    func testUnknownTimerAcknowledgmentThrows() throws {
        XCTAssertThrowsError(try startSession().acknowledgeTimer(id: "ghost", now: t0.addingTimeInterval(10))) { error in
            XCTAssertEqual(error as? FLFlowError, .timerNotFound(timerID: "ghost"))
        }
    }

    func testDuplicateTimerIDIsRefused() throws {
        let session = try startSession()
        let withTimer = try session.addTimer(id: "t1", label: "bake", deadline: t0.addingTimeInterval(600), now: t0.addingTimeInterval(5))
        XCTAssertThrowsError(try withTimer.addTimer(id: "t1", label: "again", deadline: t0.addingTimeInterval(900), now: t0.addingTimeInterval(6))) { error in
            XCTAssertEqual(error as? FLFlowError, .validation(target: "CookSession.addTimer", reason: "timer id already exists in this session"))
        }
    }

    func testTimersCanStartWhilePausedButNotAfterFinish() throws {
        let paused = try startSession().pause(now: t0.addingTimeInterval(10))
        let withTimer = try paused.addTimer(id: "t1", label: "rest", deadline: t0.addingTimeInterval(600), now: t0.addingTimeInterval(15))
        XCTAssertEqual(withTimer.stage, .paused)
        XCTAssertEqual(withTimer.checkpoint.timers.count, 1)
        let finished = try startSession(steps: [TestBuilders.step("s1")]).completeStep(now: t0.addingTimeInterval(10))
        XCTAssertThrowsError(try finished.addTimer(id: "t2", label: "late", deadline: t0.addingTimeInterval(600), now: t0.addingTimeInterval(15))) { error in
            XCTAssertEqual(error as? FLFlowError, .invalidTransition(phase: "finished", operation: "addTimer"))
        }
    }

    // MARK: Recovery after a restart

    func testRecoveryOfAFreshCheckpointResumesAtTheSameStep() throws {
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        let midCook = try session.completeStep(now: t0.addingTimeInterval(300))
        let decision = try CookSession.recover(
            checkpoint: midCook.checkpoint,
            stepIDs: ["s1", "s2"],
            now: t0.addingTimeInterval(330),
            policy: .standard
        )
        XCTAssertEqual(decision, .resume(stepIndex: 1, expiredTimerIDs: []))
    }

    func testRecoverySurfacesExpiredTimersWithoutAcknowledgingThem() throws {
        let session = try startSession()
        let withTimer = try session.addTimer(
            id: "t1",
            label: "bake",
            deadline: t0.addingTimeInterval(60),
            now: t0.addingTimeInterval(5)
        )
        // Restart 90 seconds in: the timer rang unanswered during the outage.
        let decision = try CookSession.recover(
            checkpoint: withTimer.checkpoint,
            stepIDs: ["s1", "s2"],
            now: t0.addingTimeInterval(90),
            policy: .standard
        )
        XCTAssertEqual(decision, .resume(stepIndex: 0, expiredTimerIDs: ["t1"]))
        // The expired timer is still unacknowledged — surfacing is not
        // acknowledging. The user decides.
        let reinstated = try CookSession.reinstate(checkpoint: withTimer.checkpoint, stepIDs: ["s1", "s2"], now: t0.addingTimeInterval(90))
        XCTAssertFalse(reinstated.checkpoint.timers[0].acknowledged)
        XCTAssertTrue(reinstated.expiredTimerIDs(now: t0.addingTimeInterval(90)).contains("t1"))
    }

    func testRecoveryAbandonsAStaleCheckpoint() throws {
        let session = try startSession()
        let midCook = try session.completeStep(now: t0.addingTimeInterval(300))
        let decision = try CookSession.recover(
            checkpoint: midCook.checkpoint,
            stepIDs: ["s1", "s2"],
            now: t0.addingTimeInterval(300 + 6 * 3600 + 1),
            policy: .standard
        )
        XCTAssertEqual(decision, .abandoned)
    }

    func testRecoveryOfAFinishedCheckpointGoesToTheMealLogHandoff() throws {
        let session = try startSession(steps: [TestBuilders.step("s1")])
        let finished = try session.completeStep(now: t0.addingTimeInterval(600))
        let decision = try CookSession.recover(
            checkpoint: finished.checkpoint,
            stepIDs: ["s1"],
            now: t0.addingTimeInterval(700),
            policy: .standard
        )
        XCTAssertEqual(decision, .finished)
    }

    func testReinstateRefusesCompletedStepsOutsideTheRevision() throws {
        let revision = makeRevision()
        let checkpoint = try CookingSessionCheckpoint(
            sessionID: "sess-1",
            recipeRevision: revision.key,
            stepIndex: 0,
            completedStepIDs: ["ghost"],
            timers: [],
            updatedAt: t0
        )
        XCTAssertThrowsError(try CookSession.reinstate(checkpoint: checkpoint, stepIDs: ["s1"], now: t0)) { error in
            guard let flowError = error as? FLFlowError, case let .checkpointCorrupt(reason) = flowError else {
                return XCTFail("expected checkpointCorrupt, got \(error)")
            }
            XCTAssertTrue(reason.contains("ghost"))
        }
    }

    func testRecoveredSessionCanContinueToCompletion() throws {
        // The restart path end to end: cook, die, reinstate, finish.
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        let midCook = try session.completeStep(now: t0.addingTimeInterval(300))
        let backToLife = try CookSession.reinstate(
            checkpoint: midCook.checkpoint,
            stepIDs: ["s1", "s2"],
            now: t0.addingTimeInterval(320)
        )
        XCTAssertEqual(backToLife.stage, .cooking)
        let finished = try backToLife.completeStep(now: t0.addingTimeInterval(600))
        XCTAssertEqual(finished.stage, .finished)
        XCTAssertEqual(finished.checkpoint.completedStepIDs, ["s1", "s2"])
    }

    // MARK: Accepted substitutions

    /// SPEC 3.3: the cook records what was swapped and why. The session
    /// carries the user's mid-cook accepts so the meal-log hand-off can put
    /// them on the Cook record.

    private func makeSwap(
        from: String = "butter",
        to: String = "olive oil",
        necessity: CookSubstitution.Necessity = .necessary
    ) throws -> CookSubstitution {
        try CookSubstitution(
            from: try IngredientReference(canonicalName: from),
            to: try IngredientReference(canonicalName: to),
            necessity: necessity
        )
    }

    func testAcceptedSubstitutionRidesLaterTransitions() throws {
        let session = try startSession(steps: [TestBuilders.step("s1"), TestBuilders.step("s2")])
        let swap = try makeSwap()
        let accepted = try session.accept(substitution: swap)
        let afterStep = try accepted.completeStep(now: t0.addingTimeInterval(10))
        let paused = try afterStep.pause(now: t0.addingTimeInterval(20))
        let resumed = try paused.resume(now: t0.addingTimeInterval(30))
        XCTAssertEqual(accepted.acceptedSubstitutions, [swap])
        XCTAssertEqual(afterStep.acceptedSubstitutions, [swap])
        XCTAssertEqual(paused.acceptedSubstitutions, [swap])
        XCTAssertEqual(resumed.acceptedSubstitutions, [swap])
    }

    func testAcceptsAreOrderedAndValueSemantic() throws {
        let session = try startSession()
        let first = try makeSwap()
        let second = try makeSwap(from: "salt", to: "kosher salt", necessity: .preferred)
        let one = try session.accept(substitution: first)
        let two = try one.accept(substitution: second)
        XCTAssertEqual(two.acceptedSubstitutions, [first, second])
        XCTAssertEqual(one.acceptedSubstitutions, [first])
        XCTAssertEqual(session.acceptedSubstitutions, [])
    }

    func testAcceptRefusedAfterFinish() throws {
        // A finished cook's record is complete: no new swaps.
        let single = try startSession(steps: [TestBuilders.step("s1")])
        let finished = try single.completeStep(now: t0.addingTimeInterval(10))
        XCTAssertEqual(finished.stage, .finished)
        XCTAssertThrowsError(try finished.accept(substitution: makeSwap())) { error in
            guard let flowError = error as? FLFlowError, case let .invalidTransition(phase, operation) = flowError else {
                return XCTFail("expected invalidTransition, got \(error)")
            }
            XCTAssertEqual(operation, "accept(substitution:)")
            XCTAssertTrue(phase.contains("finished"))
        }
    }

    func testReinstateStartsWithoutSubstitutions() throws {
        // App-side state does not ride the FLDomain checkpoint: a restart
        // rebuilds from the bare checkpoint, so accepted substitutions begin
        // empty again. The join layer's mid-cook persistence gives them a
        // durable home (PR #119).
        let session = try startSession()
        let accepted = try session.accept(substitution: makeSwap())
        let reinstated = try CookSession.reinstate(
            checkpoint: session.checkpoint,
            stepIDs: session.stepIDs,
            now: t0.addingTimeInterval(10)
        )
        XCTAssertEqual(accepted.acceptedSubstitutions.count, 1)
        XCTAssertEqual(reinstated.acceptedSubstitutions, [])
    }
}
