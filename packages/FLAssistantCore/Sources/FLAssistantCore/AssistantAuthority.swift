import Foundation
import FLDomain

// MARK: - Authority facade
// The AssistantAuthority is the phone's single authority object for the
// assistant loop. Everything the model can reach funnels through it; the
// invariants the spec demands are enforced here, in one place:
//
// 1. The assistant proposes — via the engine, bound to a snapshot revision.
// 2. Only an approval matching proposalID + payloadHash + snapshotRevision
//    executes — the broker's rule, checked on every approval.
// 3. Expired or revision-stale proposals refuse — with a receipt recording
//    why (expired / staleRevision / rejected).
// 4. Every executed action leaves a receipt — committed in the SAME
//    transaction as the effects (the foundation's paired-write pattern), so
//    "executed" is never claimed for work that did not happen, and no effect
//    survives without its receipt.
// 5. Transcript-only authorization is structurally impossible: no API accepts
//    model bytes and produces an executed receipt. An ActionApproval value is
//    minted only by the host's approval UI, never from model output.

/// Records the receipt lifecycle. The GRDB-backed production ledger lands
/// with its own milestone; `InMemoryReceiptLedger` serves tests and previews.
/// Requirements are async so implementations may be actors or locked classes.
public protocol ReceiptLedger: Sendable {
    /// Append one receipt row.
    func record(_ receipt: ActionReceipt) async throws
    /// The most recent receipt for a proposal, if any.
    func latestReceipt(proposalID: String) async throws -> ActionReceipt?
}

/// Thread-safe in-memory ledger. Receipt rows are kept in arrival order per
/// proposal.
public actor InMemoryReceiptLedger: ReceiptLedger {
    private var receipts: [String: [ActionReceipt]] = [:]

    public init() {}

    public func record(_ receipt: ActionReceipt) throws {
        receipts[receipt.proposalID, default: []].append(receipt)
    }

    public func latestReceipt(proposalID: String) throws -> ActionReceipt? {
        receipts[proposalID]?.last
    }

    /// All rows, in insertion order — test and diagnostics convenience.
    public func allReceipts() -> [ActionReceipt] {
        receipts.values.flatMap { $0 }.sorted { $0.recordedAt < $1.recordedAt }
    }
}

/// One minted proposal and the session it was computed for. Kept private to
/// the authority; proposals cross to callers as FLDomain values.
private struct OpenProposal: Sendable {
    let proposal: ActionProposal
    let sessionID: String
}

/// The phone-side authority. One instance serves all sessions; proposals are
/// keyed by ID and remember the session they were computed against, so an
/// approval presented from another session is refused.
public actor AssistantAuthority {
    private let engine: ActionProposalEngine
    private let ledger: any ReceiptLedger
    private let revisionClock: AssistantRevisionClock
    private var openProposals: [String: OpenProposal] = [:]

    /// - Parameters:
    ///   - revisionClock: the live source of snapshot revisions. Round 2,
    ///     item 2: the authority re-reads it immediately before executing an
    ///     approval, so an approval granted against a snapshot that has since
    ///     advanced refuses at the execution gate. Required — without the
    ///     live clock the authority could not tell current from stale state.
    public init(
        engine: ActionProposalEngine = ActionProposalEngine(),
        ledger: any ReceiptLedger,
        revisionClock: AssistantRevisionClock
    ) {
        self.engine = engine
        self.ledger = ledger
        self.revisionClock = revisionClock
    }

    // MARK: Proposing

    /// Mint a proposal from a validated model invocation against `snapshot`.
    /// The proposal is stored as `pendingApproval` — the arrival receipt —
    /// before the caller sees it, so every proposal leaves an evidence trail
    /// even if it is never approved.
    public func propose(
        from invocation: ToolInvocation,
        against snapshot: AssistantContextSnapshot,
        now: Date
    ) async throws -> ActionProposal {
        let proposal = try engine.propose(from: invocation, against: snapshot, now: now)
        try await storePending(proposal, sessionID: snapshot.sessionID)
        return proposal
    }

    /// Mint a proposal directly (host-initiated flows use the same authority
    /// path, so receipts stay complete).
    public func propose(
        tool: AssistantTool,
        payload: ActionPayload,
        against snapshot: AssistantContextSnapshot,
        now: Date,
        expiresAt: Date? = nil
    ) async throws -> ActionProposal {
        let proposal = try engine.propose(
            tool: tool, payload: payload, against: snapshot, now: now, expiresAt: expiresAt
        )
        try await storePending(proposal, sessionID: snapshot.sessionID)
        return proposal
    }

    private func storePending(_ proposal: ActionProposal, sessionID: String) async throws {
        try await ledger.record(try ActionReceipt(
            proposalID: proposal.id,
            state: .pendingApproval,
            payloadHash: proposal.payloadHash,
            snapshotRevision: proposal.snapshotRevision,
            recordedAt: proposal.createdAt
        ))
        openProposals[proposal.id] = OpenProposal(proposal: proposal, sessionID: sessionID)
    }

    // MARK: Deciding

    /// Shared pre-execution validation for approval: the proposal must be
    /// open (or decided, which refuses with `alreadyDecided`), and the
    /// approval must pass the broker's full rule — checked against the
    /// CALLER's session (round 2, item 1: the stored session was once passed
    /// as both broker arguments, so a wrong-session call passed the guard by
    /// comparing the stored session with itself). A broker refusal records
    /// its receipt (`rejected` / `staleRevision` / `expired`) before throwing;
    /// a session mismatch records nothing — the proposal stays open for the
    /// session it belongs to.
    private func validateForExecution(
        _ approval: ActionApproval,
        callerSessionID: String,
        now: Date
    ) async throws -> OpenProposal {
        guard let entry = openProposals[approval.proposalID] else {
            // Not open: either it never existed here, or it was decided and
            // closed. The ledger decides which refusal is true — a receipt
            // means the proposal was minted and the earlier receipt stands.
            if (try await ledger.latestReceipt(proposalID: approval.proposalID)) != nil {
                throw FLAssistantError.alreadyDecided(proposalID: approval.proposalID)
            }
            throw FLAssistantError.unknownProposal(proposalID: approval.proposalID)
        }
        // A decided proposal never re-executes. The earlier receipt stands;
        // this attempt is refused and leaves no new row.
        if let latest = try await ledger.latestReceipt(proposalID: entry.proposal.id),
           latest.state != .pendingApproval {
            throw FLAssistantError.alreadyDecided(proposalID: entry.proposal.id)
        }
        do {
            try ApprovalBroker.authorize(
                proposal: entry.proposal,
                approval: approval,
                inSession: callerSessionID,
                proposalSessionID: entry.sessionID,
                now: now
            )
        } catch let error as FLAssistantError {
            // Record the refusal reason as a receipt — the evidence trail
            // shows the forgery attempt and what was NOT executed.
            let state: ActionReceiptState
            switch error {
            case .snapshotRevisionMismatch:
                state = .staleRevision
            case .proposalExpired:
                state = .expired
            case .sessionMismatch:
                // Round 2, item 1: a wrong-session call does not get to
                // decide the proposal either way — the ledger is device-wide
                // and the proposal's own session may still approve it.
                throw error
            default:
                // Hash mismatch — a user-facing refusal of the presented
                // approval.
                state = .rejected
            }
            try await ledger.record(try ActionReceipt(
                proposalID: entry.proposal.id,
                state: state,
                payloadHash: entry.proposal.payloadHash,
                snapshotRevision: entry.proposal.snapshotRevision,
                recordedAt: now
            ))
            throw error
        }
        return entry
    }

    /// Round 2, item 2 — the execution gate: the CURRENT revision, read here,
    /// after every other check and immediately before effects run. An
    /// approval granted against a snapshot that has since advanced refuses
    /// at this gate with a stale-revision receipt, even though the
    /// approval-time binding still held when it was granted.
    private func refuseIfSnapshotAdvanced(
        _ proposal: ActionProposal,
        now: Date
    ) async throws {
        let currentRevision = await revisionClock.current()
        guard currentRevision == proposal.snapshotRevision else {
            try await ledger.record(try ActionReceipt(
                proposalID: proposal.id,
                state: .staleRevision,
                payloadHash: proposal.payloadHash,
                snapshotRevision: proposal.snapshotRevision,
                recordedAt: now
            ))
            throw FLAssistantError.snapshotRevisionMismatch(
                proposalID: proposal.id,
                approved: proposal.snapshotRevision,
                actual: currentRevision
            )
        }
    }

    /// Apply an approval presented by session `sessionID`. Runs the broker's
    /// full rule against the caller's session (ID + hash + revision + expiry
    /// + session), re-checks the CURRENT revision at the execution gate, then
    /// executes the effects and records the `.executed` receipt — the effects
    /// and the receipt commit in ONE transaction, so a failure in either
    /// rolls both back (review round 2, item 4: a receipt failure after the
    /// effect can never be retried into a second mutation, because no effect
    /// survives without its receipt). A refused approval records the refusal
    /// receipt (`rejected` / `staleRevision` / `expired`) and throws — except
    /// a session mismatch, which records nothing and leaves the proposal
    /// open for its own session. An executor failure propagates without
    /// recording — the proposal stays pending and can be retried;
    /// "executed" is only claimed for work that actually happened and
    /// committed.
    ///
    /// There is no non-transactional approval path: every propose* tool
    /// mutates device state, so every approval requires the durable
    /// effect/receipt pairing. Requires a `GRDBReceiptLedger`; any other
    /// ledger refuses with `.ledgerCannotExecuteAtomically` and nothing runs.
    @discardableResult
    public func approve(
        _ approval: ActionApproval,
        executor: any GRDBActionExecutor,
        sessionID: String,
        now: Date
    ) async throws -> ActionReceipt {
        let entry = try await validateForExecution(
            approval, callerSessionID: sessionID, now: now
        )
        try await refuseIfSnapshotAdvanced(entry.proposal, now: now)
        guard let grdbLedger = ledger as? GRDBReceiptLedger else {
            throw FLAssistantError.ledgerCannotExecuteAtomically
        }
        let receipt = try await grdbLedger.executeAndRecord(
            proposal: entry.proposal,
            executor: executor,
            recordedAt: now
        )
        openProposals[entry.proposal.id] = nil
        return receipt
    }

    /// Record an explicit user decline for an open proposal.
    @discardableResult
    public func decline(proposalID: String, now: Date) async throws -> ActionReceipt {
        guard let entry = openProposals[proposalID] else {
            if (try await ledger.latestReceipt(proposalID: proposalID)) != nil {
                throw FLAssistantError.alreadyDecided(proposalID: proposalID)
            }
            throw FLAssistantError.unknownProposal(proposalID: proposalID)
        }
        if let latest = try await ledger.latestReceipt(proposalID: proposalID),
           latest.state != .pendingApproval {
            throw FLAssistantError.alreadyDecided(proposalID: proposalID)
        }
        let receipt = try ActionReceipt(
            proposalID: proposalID,
            state: .rejected,
            payloadHash: entry.proposal.payloadHash,
            snapshotRevision: entry.proposal.snapshotRevision,
            recordedAt: now
        )
        try await ledger.record(receipt)
        openProposals[proposalID] = nil
        return receipt
    }

    /// Expire every open proposal past its validity window at `now` and
    /// return the receipts recorded. The host calls this when a session ends
    /// or periodically, so stale proposals cannot linger as approvable.
    public func sweepExpired(now: Date) async throws -> [ActionReceipt] {
        var expired: [ActionReceipt] = []
        for (id, entry) in openProposals {
            guard let expiresAt = entry.proposal.expiresAt, now > expiresAt else { continue }
            let receipt = try ActionReceipt(
                proposalID: id,
                state: .expired,
                payloadHash: entry.proposal.payloadHash,
                snapshotRevision: entry.proposal.snapshotRevision,
                recordedAt: now
            )
            try await ledger.record(receipt)
            openProposals[id] = nil
            expired.append(receipt)
        }
        return expired.sorted { $0.proposalID < $1.proposalID }
    }

    /// The most recent receipt for a proposal, if any.
    public func latestReceipt(proposalID: String) async throws -> ActionReceipt? {
        try await ledger.latestReceipt(proposalID: proposalID)
    }
}
