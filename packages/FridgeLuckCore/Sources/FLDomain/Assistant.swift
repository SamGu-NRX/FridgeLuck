import Foundation

// MARK: - Assistant authority contracts
// SPEC 4 + engineering plan Goal 3 option A: the phone is authoritative for
// pantry, cook sessions and logs. The backend reads bounded snapshots and
// proposes typed actions; the phone checks revision and approval, executes, and
// returns a receipt. The model cannot manufacture approval, and a voice
// transcript alone never authorizes a meal log or a share.

/// A bounded, versioned view of app state the assistant may read. Revision
/// increases monotonically with every app-state change the snapshot covers;
/// proposals bind to the exact revision they were computed from.
public struct AssistantContextSnapshot: Hashable, Sendable {
    /// The Live session this snapshot was built for. Never empty.
    public let sessionID: String
    /// Monotonically increasing, at least 1.
    public let revision: Int
    public let capturedAt: Date
    /// Bounded pantry summary. Quantity evidence may be unknown — that is
    /// information too, and must reach the model as unknown.
    public let pantrySummary: [PantrySummaryLine]
    /// The recipe the session is attached to, when any.
    public let recipeContext: RecipeKey?
    /// Current 0-based step index when a cook session is attached.
    public let stepIndex: Int?

    public struct PantrySummaryLine: Hashable, Sendable {
        public let canonicalName: String
        public let quantity: QuantityEvidence
        public let lastConfirmedAt: Date?

        /// Validated construction: the canonical name is never empty. Public
        /// so callers outside the module (and tests without `@testable`) build
        /// lines through the same validation as decoding.
        public init(canonicalName: String, quantity: QuantityEvidence, lastConfirmedAt: Date?) throws {
            let trimmed = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FLDomainError.validation(target: "AssistantContextSnapshot.PantrySummaryLine.canonicalName", reason: "must not be empty")
            }
            self.canonicalName = trimmed
            self.quantity = quantity
            self.lastConfirmedAt = lastConfirmedAt
        }
    }

    public init(
        sessionID: String,
        revision: Int,
        capturedAt: Date,
        pantrySummary: [PantrySummaryLine],
        recipeContext: RecipeKey? = nil,
        stepIndex: Int? = nil
    ) throws {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "AssistantContextSnapshot.sessionID", reason: "must not be empty")
        }
        guard revision >= 1 else {
            throw FLDomainError.validation(target: "AssistantContextSnapshot.revision", reason: "must be >= 1 (got \(revision))")
        }
        if let stepIndex {
            guard stepIndex >= 0 else {
                throw FLDomainError.validation(target: "AssistantContextSnapshot.stepIndex", reason: "must be >= 0 (got \(stepIndex))")
            }
        }
        self.sessionID = trimmed
        self.revision = revision
        self.capturedAt = capturedAt
        self.pantrySummary = pantrySummary
        self.recipeContext = recipeContext
        self.stepIndex = stepIndex
    }
}

/// The tools the assistant may call. Typed: never free text, never a generic
/// "run command".
public enum AssistantTool: String, Codable, Sendable, CaseIterable {
    case readPantry
    case readRecipeContext
    case proposeStepAdvance
    case proposeTimer
    case proposePantryCorrection
    case proposeMealLog
}

/// The typed payload of a proposed action.
public enum ActionPayload: Hashable, Sendable {
    /// Advance the cook session to this 0-based step index.
    case stepAdvance(stepIndex: Int)
    /// Create a device timer with a persisted absolute deadline.
    case timerCreate(label: String, seconds: Int)
    /// Correct one pantry line's quantity evidence.
    case pantryCorrection(canonicalName: String, quantity: QuantityEvidence)
    /// Commit a meal log (the cook record). A transcript alone never executes
    /// this — approval is checked against proposal and snapshot revision.
    case mealLog(cook: Cook)
}

extension ActionPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, stepIndex, label, seconds, canonicalName, quantity, cook
    }

    private enum Kind: String, Codable, Sendable {
        case stepAdvance, timerCreate, pantryCorrection, mealLog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stepAdvance:
            self = .stepAdvance(stepIndex: try container.decode(Int.self, forKey: .stepIndex))
        case .timerCreate:
            self = .timerCreate(
                label: try container.decode(String.self, forKey: .label),
                seconds: try container.decode(Int.self, forKey: .seconds)
            )
        case .pantryCorrection:
            self = .pantryCorrection(
                canonicalName: try container.decode(String.self, forKey: .canonicalName),
                quantity: try container.decode(QuantityEvidence.self, forKey: .quantity)
            )
        case .mealLog:
            self = .mealLog(cook: try container.decode(Cook.self, forKey: .cook))
        }
        // Review round 2, item 3: the decoded form obeys the same value rules
        // as a payload built in code — one rule, no separate fast path.
        try self.validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stepAdvance(stepIndex):
            try container.encode(Kind.stepAdvance, forKey: .kind)
            try container.encode(stepIndex, forKey: .stepIndex)
        case let .timerCreate(label, seconds):
            try container.encode(Kind.timerCreate, forKey: .kind)
            try container.encode(label, forKey: .label)
            try container.encode(seconds, forKey: .seconds)
        case let .pantryCorrection(canonicalName, quantity):
            try container.encode(Kind.pantryCorrection, forKey: .kind)
            try container.encode(canonicalName, forKey: .canonicalName)
            try container.encode(quantity, forKey: .quantity)
        case let .mealLog(cook):
            try container.encode(Kind.mealLog, forKey: .kind)
            try container.encode(cook, forKey: .cook)
        }
    }
}

public extension ActionPayload {
    /// The one value-rule for every payload, whether it was decoded off the
    /// wire or built in code (review round 2, item 3: no separate fast path).
    /// Error targets are frozen — receipts and the backend may match on them.
    /// `mealLog` adds no check here: Cook validated itself at construction
    /// and at decode, and internal types are trusted (boundary discipline).
    func validate() throws {
        switch self {
        case let .stepAdvance(stepIndex):
            guard stepIndex >= 0 else {
                throw FLDomainError.validation(target: "ActionPayload.stepAdvance.stepIndex", reason: "must be >= 0 (got \(stepIndex))")
            }
        case let .timerCreate(label, seconds):
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FLDomainError.validation(target: "ActionPayload.timerCreate.label", reason: "must not be empty")
            }
            guard seconds > 0 else {
                throw FLDomainError.validation(target: "ActionPayload.timerCreate.seconds", reason: "must be > 0 (got \(seconds))")
            }
        case let .pantryCorrection(canonicalName, _):
            guard !canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FLDomainError.validation(target: "ActionPayload.pantryCorrection.canonicalName", reason: "must not be empty")
            }
        case .mealLog:
            break
        }
    }
}

/// The SHA-256 of the canonical payload JSON, lowercase hex — the format this
/// domain validates. Computing the hash is the assistant core's policy (it owns
/// the canonical encoding), not FLDomain's; FLDomain binds fields together and
/// validates format.
public enum FLHashFormat {
    public static func validateSHA256Hex(_ hash: String, target: String) throws {
        guard hash.count == 64 else {
            throw FLDomainError.validation(target: target, reason: "payload hash must be 64 hex characters (got \(hash.count))")
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard hash.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw FLDomainError.validation(target: target, reason: "payload hash must be lowercase hex")
        }
    }
}

/// A proposed action, bound to the exact snapshot revision it was computed from
/// and to the hash of its payload, so an approval approves exactly what was shown.
public struct ActionProposal: Hashable, Sendable {
    /// Stable proposal identity. Never empty.
    public let id: String
    public let tool: AssistantTool
    public let payload: ActionPayload
    /// SHA-256 hex of the canonical payload encoding. Binds approval to content.
    public let payloadHash: String
    /// The snapshot revision the payload was computed against.
    public let snapshotRevision: Int
    public let createdAt: Date
    /// When the proposal expires if never approved.
    public let expiresAt: Date?

    public init(
        id: String,
        tool: AssistantTool,
        payload: ActionPayload,
        payloadHash: String,
        snapshotRevision: Int,
        createdAt: Date,
        expiresAt: Date? = nil
    ) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "ActionProposal.id", reason: "must not be empty")
        }
        try FLHashFormat.validateSHA256Hex(payloadHash, target: "ActionProposal.payloadHash")
        guard snapshotRevision >= 1 else {
            throw FLDomainError.validation(target: "ActionProposal.snapshotRevision", reason: "must be >= 1 (got \(snapshotRevision))")
        }
        // Review round 2, item 3: a payload built in code passes through the
        // same validation as a decoded payload — this init is the boundary
        // where a payload becomes an approvable action.
        try payload.validate()
        if let expiresAt {
            guard expiresAt >= createdAt else {
                throw FLDomainError.validation(target: "ActionProposal.expiresAt", reason: "must be at or after createdAt")
            }
        }
        // Review round 1, item 7: the tool and the payload must agree, and
        // only propose* tools produce proposals. A read is not an action — it
        // needs no approval, so it never travels as an ActionProposal — and a
        // timer proposal carrying a step-advance payload would let one thing
        // be approved while another executes.
        switch tool {
        case .proposeStepAdvance:
            guard case .stepAdvance = payload else {
                throw FLDomainError.validation(target: "ActionProposal.tool", reason: "proposeStepAdvance requires a stepAdvance payload")
            }
        case .proposeTimer:
            guard case .timerCreate = payload else {
                throw FLDomainError.validation(target: "ActionProposal.tool", reason: "proposeTimer requires a timerCreate payload")
            }
        case .proposePantryCorrection:
            guard case .pantryCorrection = payload else {
                throw FLDomainError.validation(target: "ActionProposal.tool", reason: "proposePantryCorrection requires a pantryCorrection payload")
            }
        case .proposeMealLog:
            guard case .mealLog = payload else {
                throw FLDomainError.validation(target: "ActionProposal.tool", reason: "proposeMealLog requires a mealLog payload")
            }
        case .readPantry, .readRecipeContext:
            throw FLDomainError.validation(target: "ActionProposal.tool", reason: "read tools do not produce proposals; only propose* tools are actions that require approval")
        }
        self.id = trimmed
        self.tool = tool
        self.payload = payload
        self.payloadHash = payloadHash
        self.snapshotRevision = snapshotRevision
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// The user's consent, captured by the phone — never by the model. An approval
/// is only usable for the exact payload hash and snapshot revision it shows.
public struct ActionApproval: Hashable, Sendable {
    public let proposalID: String
    /// The payload hash the user actually approved.
    public let payloadHash: String
    /// The snapshot revision the user actually saw.
    public let snapshotRevision: Int
    public let approvedAt: Date

    public init(proposalID: String, payloadHash: String, snapshotRevision: Int, approvedAt: Date) throws {
        let trimmed = proposalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "ActionApproval.proposalID", reason: "must not be empty")
        }
        try FLHashFormat.validateSHA256Hex(payloadHash, target: "ActionApproval.payloadHash")
        guard snapshotRevision >= 1 else {
            throw FLDomainError.validation(target: "ActionApproval.snapshotRevision", reason: "must be >= 1 (got \(snapshotRevision))")
        }
        self.proposalID = trimmed
        self.payloadHash = payloadHash
        self.snapshotRevision = snapshotRevision
        self.approvedAt = approvedAt
    }
}

/// The lifecycle of one proposal's execution, recorded by the phone:
/// pendingApproval / executed / rejected / expired / staleRevision / duplicate.
public enum ActionReceiptState: String, Codable, Sendable, CaseIterable {
    /// Recorded when a proposal arrives, before any decision.
    case pendingApproval
    /// The phone executed the action.
    case executed
    /// The user declined.
    case rejected
    /// The proposal expired before a decision.
    case expired
    /// The snapshot revision moved on; the proposal can no longer be applied.
    case staleRevision
    /// This proposal was already decided; the earlier receipt stands.
    case duplicate
}

/// The phone's structured answer for one proposal. A receipt is the only
/// execution evidence anyone may trust; prose in a transcript never is.
public struct ActionReceipt: Hashable, Sendable {
    public let proposalID: String
    public let state: ActionReceiptState
    /// The payload hash of the proposal, when the receipt is bound to one.
    public let payloadHash: String?
    public let snapshotRevision: Int?
    public let recordedAt: Date

    public init(proposalID: String, state: ActionReceiptState, payloadHash: String?, snapshotRevision: Int?, recordedAt: Date) throws {
        let trimmed = proposalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "ActionReceipt.proposalID", reason: "must not be empty")
        }
        if let payloadHash {
            try FLHashFormat.validateSHA256Hex(payloadHash, target: "ActionReceipt.payloadHash")
        }
        if let snapshotRevision {
            guard snapshotRevision >= 1 else {
                throw FLDomainError.validation(target: "ActionReceipt.snapshotRevision", reason: "must be >= 1 (got \(snapshotRevision))")
            }
        }
        self.proposalID = trimmed
        self.state = state
        self.payloadHash = payloadHash
        self.snapshotRevision = snapshotRevision
        self.recordedAt = recordedAt
    }
}

/// Durable cook-session state, written so a killed app can resume deliberately.
/// Timers carry persisted absolute deadlines independent of the Live session;
/// a timer is acknowledged only after the device created it.
public struct CookingSessionCheckpoint: Hashable, Sendable {
    public struct TimerRecord: Hashable, Sendable {
        public let id: String
        /// Never empty.
        public let label: String
        /// Persisted absolute deadline (epoch seconds, finite).
        public let deadlineEpochSeconds: Double
        /// True only when the device itself created the timer.
        public let createdOnDevice: Bool
        /// True only after the device created it (acknowledged implies createdOnDevice).
        public let acknowledged: Bool

        public init(id: String, label: String, deadlineEpochSeconds: Double, createdOnDevice: Bool, acknowledged: Bool) throws {
            let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else {
                throw FLDomainError.validation(target: "CookingSessionCheckpoint.TimerRecord.id", reason: "must not be empty")
            }
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else {
                throw FLDomainError.validation(target: "CookingSessionCheckpoint.TimerRecord.label", reason: "must not be empty")
            }
            guard deadlineEpochSeconds.isFinite else {
                throw FLDomainError.validation(target: "CookingSessionCheckpoint.TimerRecord.deadlineEpochSeconds", reason: "must be finite (got \(deadlineEpochSeconds))")
            }
            guard !acknowledged || createdOnDevice else {
                throw FLDomainError.validation(target: "CookingSessionCheckpoint.TimerRecord.acknowledged", reason: "a timer is acknowledged only after the device created it")
            }
            self.id = trimmedID
            self.label = trimmedLabel
            self.deadlineEpochSeconds = deadlineEpochSeconds
            self.createdOnDevice = createdOnDevice
            self.acknowledged = acknowledged
        }
    }

    /// Never empty.
    public let sessionID: String
    public let recipeRevision: RecipeKey
    /// Current 0-based step index. At least 0.
    public let stepIndex: Int
    /// Completed step IDs. Unique.
    public let completedStepIDs: [String]
    public let timers: [TimerRecord]
    public let updatedAt: Date

    public init(
        sessionID: String,
        recipeRevision: RecipeKey,
        stepIndex: Int,
        completedStepIDs: [String],
        timers: [TimerRecord],
        updatedAt: Date
    ) throws {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FLDomainError.validation(target: "CookingSessionCheckpoint.sessionID", reason: "must not be empty")
        }
        guard stepIndex >= 0 else {
            throw FLDomainError.validation(target: "CookingSessionCheckpoint.stepIndex", reason: "must be >= 0 (got \(stepIndex))")
        }
        let completed = completedStepIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for completedID in completed {
            guard !completedID.isEmpty else {
                throw FLDomainError.validation(target: "CookingSessionCheckpoint.completedStepIDs", reason: "step IDs must not be empty")
            }
        }
        guard Set(completed).count == completed.count else {
            throw FLDomainError.validation(target: "CookingSessionCheckpoint.completedStepIDs", reason: "must be unique")
        }
        self.sessionID = trimmed
        self.recipeRevision = recipeRevision
        self.stepIndex = stepIndex
        self.completedStepIDs = completed
        self.timers = timers
        self.updatedAt = updatedAt
    }
}

// MARK: - Codable: decode through validation, encode through FLTimestamp
// Review round 1, items 1 and 2. The synthesized Codable implementations
// bypassed every throwing initializer — JSON could carry an invalid payload
// hash, a non-positive revision, or a timer acknowledged without device
// creation — and encoded `Date` as bare seconds since the 2001 reference
// epoch, contradicting the ISO 8601 contract. Every assistant type now
// decodes through its throwing initializer and encodes timestamps through
// FLTimestamp, so the wire form and the constructed form obey one rule set.

extension AssistantContextSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case sessionID, revision, capturedAt, pantrySummary, recipeContext, stepIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: try container.decode(String.self, forKey: .sessionID),
            revision: try container.decode(Int.self, forKey: .revision),
            capturedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .capturedAt),
                target: "AssistantContextSnapshot.capturedAt"
            ),
            pantrySummary: try container.decode([PantrySummaryLine].self, forKey: .pantrySummary),
            recipeContext: try container.decodeIfPresent(RecipeKey.self, forKey: .recipeContext),
            stepIndex: try container.decodeIfPresent(Int.self, forKey: .stepIndex)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(revision, forKey: .revision)
        try container.encode(FLTimestamp.encode(capturedAt), forKey: .capturedAt)
        try container.encode(pantrySummary, forKey: .pantrySummary)
        try container.encodeIfPresent(recipeContext, forKey: .recipeContext)
        try container.encodeIfPresent(stepIndex, forKey: .stepIndex)
    }
}

extension AssistantContextSnapshot.PantrySummaryLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case canonicalName, quantity, lastConfirmedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canonicalName: try container.decode(String.self, forKey: .canonicalName),
            quantity: try container.decode(QuantityEvidence.self, forKey: .quantity),
            lastConfirmedAt: {
                guard let raw = try container.decodeIfPresent(String.self, forKey: .lastConfirmedAt) else { return nil }
                return try FLTimestamp.decode(raw, target: "PantrySummaryLine.lastConfirmedAt")
            }()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalName, forKey: .canonicalName)
        try container.encode(quantity, forKey: .quantity)
        try container.encodeIfPresent(lastConfirmedAt.map(FLTimestamp.encode), forKey: .lastConfirmedAt)
    }
}

extension ActionProposal: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, tool, payload, payloadHash, snapshotRevision, createdAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            tool: try container.decode(AssistantTool.self, forKey: .tool),
            payload: try container.decode(ActionPayload.self, forKey: .payload),
            payloadHash: try container.decode(String.self, forKey: .payloadHash),
            snapshotRevision: try container.decode(Int.self, forKey: .snapshotRevision),
            createdAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .createdAt),
                target: "ActionProposal.createdAt"
            ),
            expiresAt: {
                guard let raw = try container.decodeIfPresent(String.self, forKey: .expiresAt) else { return nil }
                return try FLTimestamp.decode(raw, target: "ActionProposal.expiresAt")
            }()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tool, forKey: .tool)
        try container.encode(payload, forKey: .payload)
        try container.encode(payloadHash, forKey: .payloadHash)
        try container.encode(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(FLTimestamp.encode(createdAt), forKey: .createdAt)
        try container.encodeIfPresent(expiresAt.map(FLTimestamp.encode), forKey: .expiresAt)
    }
}

extension ActionApproval: Codable {
    private enum CodingKeys: String, CodingKey {
        case proposalID, payloadHash, snapshotRevision, approvedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            proposalID: try container.decode(String.self, forKey: .proposalID),
            payloadHash: try container.decode(String.self, forKey: .payloadHash),
            snapshotRevision: try container.decode(Int.self, forKey: .snapshotRevision),
            approvedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .approvedAt),
                target: "ActionApproval.approvedAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proposalID, forKey: .proposalID)
        try container.encode(payloadHash, forKey: .payloadHash)
        try container.encode(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(FLTimestamp.encode(approvedAt), forKey: .approvedAt)
    }
}

extension ActionReceipt: Codable {
    private enum CodingKeys: String, CodingKey {
        case proposalID, state, payloadHash, snapshotRevision, recordedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            proposalID: try container.decode(String.self, forKey: .proposalID),
            state: try container.decode(ActionReceiptState.self, forKey: .state),
            payloadHash: try container.decodeIfPresent(String.self, forKey: .payloadHash),
            snapshotRevision: try container.decodeIfPresent(Int.self, forKey: .snapshotRevision),
            recordedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .recordedAt),
                target: "ActionReceipt.recordedAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proposalID, forKey: .proposalID)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(payloadHash, forKey: .payloadHash)
        try container.encodeIfPresent(snapshotRevision, forKey: .snapshotRevision)
        try container.encode(FLTimestamp.encode(recordedAt), forKey: .recordedAt)
    }
}

extension CookingSessionCheckpoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case sessionID, recipeRevision, stepIndex, completedStepIDs, timers, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: try container.decode(String.self, forKey: .sessionID),
            recipeRevision: try container.decode(RecipeKey.self, forKey: .recipeRevision),
            stepIndex: try container.decode(Int.self, forKey: .stepIndex),
            completedStepIDs: try container.decodeIfPresent([String].self, forKey: .completedStepIDs) ?? [],
            timers: try container.decodeIfPresent([TimerRecord].self, forKey: .timers) ?? [],
            updatedAt: try FLTimestamp.decode(
                try container.decode(String.self, forKey: .updatedAt),
                target: "CookingSessionCheckpoint.updatedAt"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(recipeRevision, forKey: .recipeRevision)
        try container.encode(stepIndex, forKey: .stepIndex)
        try container.encode(completedStepIDs, forKey: .completedStepIDs)
        try container.encode(timers, forKey: .timers)
        try container.encode(FLTimestamp.encode(updatedAt), forKey: .updatedAt)
    }
}

extension CookingSessionCheckpoint.TimerRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, deadlineEpochSeconds, createdOnDevice, acknowledged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            deadlineEpochSeconds: try container.decode(Double.self, forKey: .deadlineEpochSeconds),
            createdOnDevice: try container.decode(Bool.self, forKey: .createdOnDevice),
            acknowledged: try container.decode(Bool.self, forKey: .acknowledged)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(deadlineEpochSeconds, forKey: .deadlineEpochSeconds)
        try container.encode(createdOnDevice, forKey: .createdOnDevice)
        try container.encode(acknowledged, forKey: .acknowledged)
    }
}
