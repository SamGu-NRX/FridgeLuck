import Testing
import Foundation
import FLDomain
import FLFlowCore
import FLAssistantCore
@testable import FLScenarioKit

// S4 — assistant authority invariants at the join (SPEC 3.6): proposals are
// bound to a payload hash and a snapshot revision; approval is explicit; the
// receipts ledger is durable and restart-replay is idempotent. A stale,
// forged, or replayed approval is refused and leaves a decision receipt.

private actor SilentTimerExecutor: ActionExecutor {
    func apply(_ payload: ActionPayload, proposal: ActionProposal) async throws {}
}

@Suite("S4 · Assistant authority invariants at the join")
struct AuthorityInvariantsJoinTests {
    private func makeSnapshot(sessionID: String, revision: Int, at: Date) async throws -> AssistantContextSnapshot {
        try await AssistantContextBuilder(
            stateSource: WorldStateSource(
                lines: [AssistantPantryLine(canonicalName: "broccoli", quantity: Fixtures.grams(400), lastConfirmedAt: at)],
                recipe: try RecipeKey(source: .catalog, sourceRecipeID: "r-stir", revision: 1),
                step: 1
            ),
            revisionClock: try AssistantRevisionClock(revision: revision)
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
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let snapshot = try await makeSnapshot(sessionID: "cook-forgery", revision: 7, at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)

        // Forged: the approval claims a hash the proposed payload never had.
        let forged = try approval(makePayload(seconds: 1), proposal: p, revision: 7, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(forged, executor: SilentTimerExecutor(), now: clock.now)
        }
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .rejected, "the refusal is durable: a decision receipt, not silence")

        // A recorded refusal is terminal: the tampered attempt decided the
        // proposal, so even the honest approval is already-decided. The
        // durable receipt is the evidence that nothing was executed.
        let honest = try approval(payload, proposal: p, revision: 7, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(honest, executor: SilentTimerExecutor(), now: clock.now)
        }
        let final = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(final?.state == .rejected, "the refusal receipt stands; the proposal is closed")
    }

    @Test("A stale snapshot revision is refused with a decision receipt")
    func staleRevisionRefusal() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let snapshot = try await makeSnapshot(sessionID: "cook-stale", revision: 21, at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)

        // The pantry moved on before the user tapped approve: the approval
        // names a revision the snapshot never had.
        let stale = try approval(payload, proposal: p, revision: snapshot.revision + 1, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(stale, executor: SilentTimerExecutor(), now: clock.now)
        }
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .staleRevision)
    }

    @Test("An expired proposal cannot be approved; the sweep writes expired receipts")
    func expirySweep() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let snapshot = try await makeSnapshot(sessionID: "cook-expiry", revision: 3, at: clock.now)
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
        let late = try approval(payload, proposal: p, revision: 3, now: later.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(late, executor: SilentTimerExecutor(), now: later.now)
        }
    }

    @Test("A declined proposal is closed for good and the receipt says so")
    func declineIsTerminal() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let snapshot = try await makeSnapshot(sessionID: "cook-decline", revision: 3, at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)
        try await authority.decline(proposalID: p.id, now: clock.now)
        let receipt = try await world.receiptLedger.latestReceipt(proposalID: p.id)
        #expect(receipt?.state == .rejected)
        // Replay of the same approval after a decline: already decided.
        let replay = try approval(payload, proposal: p, revision: 3, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await authority.approve(replay, executor: SilentTimerExecutor(), now: clock.now)
        }
    }

    @Test("Restart replay is idempotent: a fresh process sees the decision and cannot decide twice")
    func restartReplayIdempotent() async throws {
        let world = try HouseholdWorld()
        let clock = WeekClock(startingAt: Week.day(2, hour: 18))
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let snapshot = try await makeSnapshot(sessionID: "cook-restart", revision: 5, at: clock.now)
        let payload = try makePayload()
        let p = try await proposeTimer(authority, snapshot, payload, clock.now)
        let good = try approval(payload, proposal: p, revision: 5, now: clock.now)
        let exec = SilentTimerExecutor()
        _ = try await authority.approve(good, executor: exec, now: clock.now)

        // The app restarts: a new authority over the same durable ledger.
        let freshAuthority = AssistantAuthority(ledger: world.receiptLedger)
        let replay = try approval(payload, proposal: p, revision: 5, now: clock.now)
        await #expect(throws: FLAssistantError.self) {
            try await freshAuthority.approve(replay, executor: exec, now: clock.now)
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
        let authority = AssistantAuthority(ledger: world.receiptLedger)
        let snapshot = try await makeSnapshot(sessionID: "cook-read", revision: 2, at: clock.now)
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
}
