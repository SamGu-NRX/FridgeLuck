import Foundation
import FLDomain

/// Errors thrown by the assistant authority layer.
///
/// Every refusal of SPEC §4's authority rules throws this type, so a caller can
/// distinguish "the model's input was refused, nothing changed" from any other
/// failure. Refusals of untrusted input (forged approvals, unsupported tools,
/// malformed replies) never mutate durable state: no receipt is written, no
/// effect is executed. A refusal is not a user decision.
public enum FLAssistantError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No proposal with this ID is stored. An approval cannot name a proposal
    /// the phone never minted.
    case unknownProposal(proposalID: String)

    /// A stored proposal already owns this ID with different content. IDs are
    /// minted by the phone; a collision with different content is corruption
    /// or a bug, never a silent overwrite.
    case proposalConflict(proposalID: String)

    /// The approval's payload hash differs from the proposal's stored hash.
    /// The user did not approve what is being presented — refuse and change
    /// nothing.
    case payloadHashMismatch(proposalID: String)

    /// The approval names a snapshot revision other than the one the proposal
    /// was computed from. What the user saw is not what the model proposed.
    case snapshotRevisionMismatch(proposalID: String, approved: Int, actual: Int)

    /// The approval is presented from a session other than the one the
    /// proposal was minted in. A proposal never crosses sessions.
    case sessionMismatch(proposalID: String)

    /// The model called a tool name this build does not know. Unknown tools
    /// are refused, never reinterpreted as something reasonable.
    case unsupportedTool(name: String)

    /// The model's tool name and payload disagree — a read tool carrying a
    /// payload, or a propose tool carrying the wrong payload variant.
    case toolPayloadMismatch(tool: String, detail: String)

    /// The raw reply could not be decoded as the wire contract (broken bytes,
    /// or a payload that failed FLDomain validation).
    case malformedReply(detail: String)

    /// A read tool cannot be turned into a proposal: reads are served locally,
    /// they propose nothing.
    case readToolCannotPropose(tool: AssistantTool)

    /// A revision below the domain floor (at least 1) was requested.
    case revisionBelowFloor(value: Int)

    public var description: String {
        switch self {
        case let .unknownProposal(id):
            return "FLAssistant refused: no stored proposal with id '\(id)'"
        case let .proposalConflict(id):
            return "FLAssistant refused: proposal id '\(id)' already stored with different content"
        case let .payloadHashMismatch(id):
            return "FLAssistant refused: approval payload hash does not match proposal '\(id)'"
        case let .snapshotRevisionMismatch(id, approved, actual):
            return "FLAssistant refused: approval for proposal '\(id)' names snapshot revision \(approved); the proposal was computed at revision \(actual)"
        case let .sessionMismatch(id):
            return "FLAssistant refused: approval for proposal '\(id)' presented from a different session"
        case let .unsupportedTool(name):
            return "FLAssistant refused: unsupported tool '\(name)'"
        case let .toolPayloadMismatch(tool, detail):
            return "FLAssistant refused: tool '\(tool)' payload mismatch: \(detail)"
        case let .malformedReply(detail):
            return "FLAssistant refused: malformed model reply: \(detail)"
        case let .readToolCannotPropose(tool):
            return "FLAssistant refused: read tool '\(tool.rawValue)' cannot propose an action"
        case let .revisionBelowFloor(value):
            return "FLAssistant refused: revision must be at least 1 (got \(value))"
        }
    }
}
