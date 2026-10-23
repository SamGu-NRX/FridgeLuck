import Testing
import Foundation
import FLDomain
import FLFlowCore
import FLAssistantCore
import GRDB
@testable import FLScenarioKit

// S4 — assistant authority invariants at the join (SPEC 3.6): proposals are
// bound to a payload hash and a snapshot revision; approval is explicit; the
// receipts ledger is durable and restart-replay is idempotent. A stale,
// forged, or replayed approval is refused and leaves a decision receipt.

/// A device with no observable side effects: the fixed GRDBActionExecutor
/// writes its effect through the ledger's open transaction connection, so a
/// no-op apply is the honest stand-in for hardware that records nothing of
/// its own. The atomic effect+receipt pairing is the ledger's job.
private struct SilentTimerExecutor: GRDBActionExecutor {
    func apply(_ payload: ActionPayload, proposal: ActionProposal, in db: Database) throws {}
}

@Suite("S4 · Assistant authority invariants at the join")
struct AuthorityInvariantsJoinTests {
    /// A snapshot built against the WORLD's live revision clock: the fixed
    /// authority stamps proposals with the live revision and validates the
    /// approval's snapshot revision against it, so a snapshot minted from a
    /// detached clock can never approve.
    private func makeSnapshot(_ world: HouseholdWorld, sessionID: String, at: Date) async throws -> AssistantContextSnapshot {
        try await AssistantContextBuilder(
            stateSource: WorldStateSource(
                lines: [AssistantPantryLine(canonicalName: "broccoli", quantity: Fixtures.grams(400), lastConfirmedAt: at)],
                recipe: try RecipeKey(source: .catalog, sourceRecipeID: "r-stir", revision: 1),
                step: 1
            ),
            revisionClock: world.revisionClock
        ).buildSnapshot(sessionID: sessionID, now: at)
    }

    private func makePayload(label: String = "Stir-fry the broccoli", seconds: Int = 240) throws -> ActionPayload {
        ActionPayload.timerCreate(label: label, seconds: seconds)
    }

    private func proposeTimer(
        _ authority: AssistantAuthority,
        _ snapshot: AssistantContextSnapshot,
        _ payload: ActionPayload,
        _ now: Date
    ) async throws -> ActionProposal {
        try await authority.propose(
            from: try ToolInvocation(tool: .proposeTimer, payload: payload),
            against: snapshot,
            now: now
        )
    }

    private func approval(_ payload: ActionPayload, proposal: ActionProposal, revision: Int, now: Date) throws -> ActionApproval {
        try ActionApproval(
            proposalID: proposal.id,
            payloadHash: try FLPayloadHashing.payloadHash(payload),
            snapshotRevision: revision,
            approvedAt: now
        )
    }

    @Test("A forged payload hash is refused, leaves a durable receipt, and the refusal is terminal")
    func forgedHashRefusal() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let snapshot = try await makeSnapshot(world, sessionID: "cook-forgery", at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)

        // Forged: the approval claims a hash the proposed payload never had.
        let forged = try approval(makePayload(seconds: 1), proposal: p, revision: snapshot.revision, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(forged, executor: SilentTimerExecutor(), sessionID: "cook-forgery", now: clock.now)
        }
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .rejected, "the refusal is durable: a decision receipt, not silence")

        // A recorded refusal is terminal: the tampered attempt decided the
        // proposal, so even the honest approval is already-decided. The
        // durable receipt is the evidence that nothing was executed.
        let honest = try approval(payload, proposal: p, revision: snapshot.revision, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(honest, executor: SilentTimerExecutor(), sessionID: "cook-forgery", now: clock.now)
        }
        let final = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(final?.state == .rejected, "the refusal receipt stands; the proposal is closed")
    }

    @Test("A stale snapshot revision is refused with a decision receipt")
    func staleRevisionRefusal() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let snapshot = try await makeSnapshot(world, sessionID: "cook-stale", at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)

        // The pantry moved on before the user tapped approve: the approval
        // names a revision the snapshot never had.
        let stale = try approval(payload, proposal: p, revision: snapshot.revision + 1, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(stale, executor: SilentTimerExecutor(), sessionID: "cook-stale", now: clock.now)
        }
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .staleRevision)
    }

    @Test("An expired proposal cannot be approved; the sweep writes expired receipts")
    func expirySweep() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let snapshot = try await makeSnapshot(world, sessionID: "cook-expiry", at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)

        // Default proposal TTL is one hour; step past it.
        var later = clock
        later.advance(minutes: 65)
        let swept = try await authority.sweepExpired(now: later.now)
        #expect(swept.count >= 1, "the sweep finds the abandoned proposal")
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .expired)
        // Approval after expiry: the proposal is decided — refused again.
        let late = try approval(payload, proposal: p, revision: snapshot.revision, now: later.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(late, executor: SilentTimerExecutor(), sessionID: "cook-expiry", now: later.now)
        }
    }

    @Test("A declined proposal is closed for good and the receipt says so")
    func declineIsTerminal() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let snapshot = try await makeSnapshot(world, sessionID: "cook-decline", at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)
        try await authority.decline(proposalID: p.id, now: clock.now)
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .rejected)
        // Replay of the same approval after a decline: already decided.
        let replay = try approval(payload, proposal: p, revision: snapshot.revision, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(replay, executor: SilentTimerExecutor(), sessionID: "cook-decline", now: clock.now)
        }
    }

    @Test("Restart replay is idempotent: a fresh process sees the decision and cannot decide twice")
    func restartReplayIdempotent() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let snapshot = try await makeSnapshot(world, sessionID: "cook-restart", at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)
        let good = try approval(payload, proposal: p, revision: snapshot.revision, now: clock.now)
        let exec = SilentTimerExecutor()
        _ = try await authority.approve(good, executor: exec, sessionID: "cook-restart", now: clock.now)

        // The app restarts: a new authority over the same durable ledger.
        let freshAuthority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let replay = try approval(payload, proposal: p, revision: snapshot.revision, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await freshAuthority.approve(replay, executor: exec, sessionID: "cook-restart", now: clock.now)
        }
        #expect(try await world.receiptLedger.latestReceipt(proposalID: p.id)?.state == .executed)

        // Arrival + decision receipts, both durable across restart, and the
        // replay added no new rows.
        let receipts = try await world.receiptLedger.allReceipts().filter { $0.proposalID == p.id }
        #expect(receipts.count == 2, "restart replay adds no receipts")
    }

    @Test("Read tools never create proposals; only mutation tools enter the authority path")
    func readToolCannotPropose() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let snapshot = try await makeSnapshot(world, sessionID: "cook-read", at: clock.now)
        let reads: [ToolInvocation] = [
            try ToolInvocation(tool: .readPantry, payload: nil),
            try ToolInvocation(tool: .readRecipeContext, payload: nil),
        ]
        for read in reads {
            await #expect(throws: FLAssistantError.self) {
                try await authority.propose(from: read, against: snapshot, now: clock.now)
            }
        }
        #expect(try await world.receiptLedger.allReceipts().isEmpty, "reads write no receipts")
    }

    @Test("An approval presented from another session is refused and the proposal stays open for its own session")
    func wrongSessionApprovalRefused() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger, revisionClock: world.revisionClock)
        let sessionID = "cook-session-a"
        let snapshot = try await makeSnapshot(world, sessionID: sessionID, at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)
        let honest = try approval(payload, proposal: p, revision: snapshot.revision, now: clock.now)

        // The identical, correctly-hashed approval reaches the authority
        // from a DIFFERENT cook session: refused, and nothing is recorded —
        // a session mismatch is a refusal, not a decision.
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(
                honest, executor: SilentTimerExecutor(),
                sessionID: "cook-session-b", now: clock.now
            )
        }
        let afterWrongSession = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(afterWrongSession?.state == .pendingApproval, "a session mismatch records nothing")

        // The very same approval presented by its own session then executes:
        // the binding is to the caller session, not to the payload alone.
        let receipt = try await authority.approve(
            honest, executor: SilentTimerExecutor(),
            sessionID: sessionID, now: clock.now
        )
        #expect(receipt.state == .executed)
    }
}
