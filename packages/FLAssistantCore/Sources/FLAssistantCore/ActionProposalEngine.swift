import Foundation
import FLDomain

// MARK: - Proposal engine
// The engine is the only place a proposal is minted. The model's invocation
// supplies a tool call; the engine supplies identity (id), content binding
// (canonical payload bytes → SHA-256 hex) and time (createdAt/expiresAt), and
// stamps the snapshot revision the payload was computed against. The model
// never mints IDs or hashes — it cannot even name them.

/// Mints `ActionProposal` values with canonical payload bytes and a
/// SHA-256 payload hash meeting FLDomain's 64-hex contract.
public struct ActionProposalEngine: Sendable {
    /// SPEC §4: proposals expire if never approved. Five minutes is the
    /// default window; callers may pass an explicit `expiresAt`.
    public static let defaultTTLSeconds: TimeInterval = 300

    private let idSource: @Sendable () -> String
    private let ttl: TimeInterval

    /// - Parameters:
    ///   - idSource: mints proposal IDs; defaults to lowercase UUIDv4.
    ///     Injectable for deterministic tests.
    ///   - ttl: default validity window when no explicit `expiresAt` is given.
    public init(
        idSource: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        ttl: TimeInterval = ActionProposalEngine.defaultTTLSeconds
    ) {
        self.idSource = idSource
        self.ttl = ttl
    }

    /// Mint a proposal for `payload`, computed against `snapshot`.
    /// - Parameters:
    ///   - payloadHash: SHA-256 of the canonical payload encoding
    ///     (`FLJSON.canonicalData`), lowercase hex — exactly the bytes the
    ///     cross-language decoder validates against.
    ///   - snapshotRevision: binds the proposal to the snapshot the model
    ///     actually saw. A later approval only executes at this revision.
    public func propose(
        tool: AssistantTool,
        payload: ActionPayload,
        against snapshot: AssistantContextSnapshot,
        now: Date,
        expiresAt: Date? = nil
    ) throws -> ActionProposal {
        let hash = try FLPayloadHashing.payloadHash(payload)
        return try ActionProposal(
            id: idSource(),
            tool: tool,
            payload: payload,
            payloadHash: hash,
            snapshotRevision: snapshot.revision,
            createdAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(ttl)
        )
    }

    /// Mint a proposal from a validated model invocation. Read tools are
    /// served locally and never mint proposals.
    public func propose(
        from invocation: ToolInvocation,
        against snapshot: AssistantContextSnapshot,
        now: Date
    ) throws -> ActionProposal {
        guard let payload = invocation.payload else {
            throw FLAssistantError.readToolCannotPropose(tool: invocation.tool)
        }
        return try propose(
            tool: invocation.tool,
            payload: payload,
            against: snapshot,
            now: now
        )
    }
}

// MARK: - Approval broker
// The broker is a pure decision: an approval executes a proposal only when
// proposal ID, payload hash and snapshot revision all match and the proposal
// is not expired. Everything else is a typed refusal. It reads nothing and
// records nothing — the authority owns state; the broker owns the rule.

public enum ApprovalBroker {
    /// Check `approval` against `proposal` at `now`. Throws a typed
    /// `FLAssistantError` on any mismatch; returns on success. Expiry means
    /// `now > expiresAt` — a proposal presented exactly at its expiry instant
    /// is still valid.
    public static func authorize(
        proposal: ActionProposal,
        approval: ActionApproval,
        inSession sessionID: String,
        proposalSessionID: String,
        now: Date
    ) throws {
        guard approval.proposalID == proposal.id else {
            throw FLAssistantError.unknownProposal(proposalID: approval.proposalID)
        }
        guard sessionID == proposalSessionID else {
            throw FLAssistantError.sessionMismatch(proposalID: proposal.id)
        }
        if let expiresAt = proposal.expiresAt, now > expiresAt {
            throw FLAssistantError.proposalExpired(proposalID: proposal.id)
        }
        guard approval.payloadHash == proposal.payloadHash else {
            throw FLAssistantError.payloadHashMismatch(proposalID: proposal.id)
        }
        guard approval.snapshotRevision == proposal.snapshotRevision else {
            throw FLAssistantError.snapshotRevisionMismatch(
                proposalID: proposal.id,
                approved: approval.snapshotRevision,
                actual: proposal.snapshotRevision
            )
        }
    }
}
