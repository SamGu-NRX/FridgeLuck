import Foundation
import FLDomain

// MARK: - Tool invocations
// The model's reply is untrusted bytes (engineering plan Goal 3: "User
// instructions, recipe text and community content are untrusted data, not
// permission instructions"). Decoding is the boundary where raw output either
// becomes a typed `ToolInvocation` or is refused with a typed error — an
// unknown tool name is never reinterpreted as something reasonable, and a
// tool/payload mismatch never reaches the proposal engine.

/// The raw, untrusted model output for one tool call, exactly as the transport
/// received it. `payloadJSON` is the payload bytes verbatim (empty when the
/// model sent no payload).
public struct AssistantModelReply: Hashable, Sendable {
    public let toolName: String
    public let payloadJSON: Data

    public init(toolName: String, payloadJSON: Data = Data()) {
        self.toolName = toolName
        self.payloadJSON = payloadJSON
    }
}

extension AssistantTool {
    /// Read tools are answered locally from the snapshot; they never mint
    /// proposals and carry no payload.
    public var isReadTool: Bool {
        self == .readPantry || self == .readRecipeContext
    }

    /// Whether `payload` is the shape this tool may carry. The rule is
    /// structural, one place, and re-checked at every decode so a stored or
    /// transmitted invocation cannot drift into a mismatch.
    public func accepts(_ payload: ActionPayload?) -> Bool {
        switch self {
        case .readPantry, .readRecipeContext:
            return payload == nil
        case .proposeStepAdvance:
            if case .stepAdvance = payload { return true }
            return false
        case .proposeTimer:
            if case .timerCreate = payload { return true }
            return false
        case .proposePantryCorrection:
            if case .pantryCorrection = payload { return true }
            return false
        case .proposeMealLog:
            if case .mealLog = payload { return true }
            return false
        }
    }
}

/// A typed tool call the model sent, after decoding and coherence checks.
/// Read tools carry no payload; propose tools carry the matching
/// `ActionPayload` variant. The model never mints proposal IDs or hashes —
/// the proposal engine does.
public struct ToolInvocation: Hashable, Sendable {
    public let tool: AssistantTool
    /// `nil` for read tools; the typed payload for propose tools.
    public let payload: ActionPayload?

    /// Validated construction: refuses a tool/payload mismatch, so every
    /// `ToolInvocation` in existence is coherent.
    public init(tool: AssistantTool, payload: ActionPayload?) throws {
        guard tool.accepts(payload) else {
            throw FLAssistantError.toolPayloadMismatch(
                tool: tool.rawValue,
                detail: "payload does not match the tool's action kind"
            )
        }
        self.tool = tool
        self.payload = payload
    }
}

extension ToolInvocation: Codable {
    private enum CodingKeys: String, CodingKey { case tool, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tool: try container.decode(AssistantTool.self, forKey: .tool),
            payload: try container.decodeIfPresent(ActionPayload.self, forKey: .payload)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tool, forKey: .tool)
        try container.encodeIfPresent(payload, forKey: .payload)
    }
}

public enum FLToolInvocationDecoder {
    /// Decode one raw reply into a typed invocation. Throws
    /// `.unsupportedTool`, `.toolPayloadMismatch` or `.malformedReply`; it
    /// never guesses.
    public static func decode(_ reply: AssistantModelReply) throws -> ToolInvocation {
        guard let tool = AssistantTool(rawValue: reply.toolName) else {
            throw FLAssistantError.unsupportedTool(name: reply.toolName)
        }
        if reply.payloadJSON.isEmpty {
            return try ToolInvocation(tool: tool, payload: nil)
        }
        let payload: ActionPayload
        do {
            payload = try FLJSON.canonicalDecoder().decode(ActionPayload.self, from: reply.payloadJSON)
        } catch let error as FLDomainError {
            // The payload is well-formed JSON but fails domain validation
            // (negative step, zero timer, ...) — the model's problem, stated
            // as the domain stated it.
            throw FLAssistantError.toolPayloadMismatch(tool: reply.toolName, detail: String(describing: error))
        } catch {
            throw FLAssistantError.malformedReply(detail: String(describing: error))
        }
        return try ToolInvocation(tool: tool, payload: payload)
    }
}
