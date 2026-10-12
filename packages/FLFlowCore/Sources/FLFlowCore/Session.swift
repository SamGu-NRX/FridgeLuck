import Foundation
import FLDomain

// MARK: - Cook session
// SPEC 3.3: a durable cook session over FLDomain's CookingSessionCheckpoint —
// step advance, timers (device-created vs proposal-side), pause and resume,
// and recovery from a bare checkpoint after a restart. The checkpoint is the
// durable record; every transition revalidates and produces a new value.

/// Where a session stands. `finished` is the meal-log hand-off state.
public enum SessionStage: Hashable, Sendable {
    case cooking
    case paused
    case finished
}

/// One cooking session: legal transitions over a durable checkpoint.
///
/// Timer rule (FLDomain invariant): a timer not created on this device can
/// never be acknowledged here. It may ring and be displayed; acknowledging
/// is reserved for the device that created it.
public struct CookSession: Hashable, Sendable {
    public let stage: SessionStage
    public let checkpoint: CookingSessionCheckpoint
    /// Step IDs of the revision being cooked, in bill order.
    public let stepIDs: [String]
    /// Substitutions the user accepted during this cook, in acceptance order
    /// (SPEC 3.3: the cook records what was swapped and why). App-side
    /// session state like pause: it does not ride the FLDomain checkpoint
    /// (the checkpoint is FLDomain's cross-language contract), so it does
    /// not survive a restart kill — the join layer's mid-cook persistence
    /// (PR #119) gives app-side state its durable home.
    public let acceptedSubstitutions: [CookSubstitution]

    public var stepCount: Int { stepIDs.count }
    /// The step currently being worked, while cooking.
    public var currentStepID: String? {
        guard stage == .cooking, checkpoint.stepIndex < stepIDs.count else { return nil }
        return stepIDs[checkpoint.stepIndex]
    }
    /// Internal memberwise construction. Every live transition carries the
    /// accepted substitutions through — only `start` and `reinstate` begin
    /// without any (app-side state is born with the session).
    init(
        stage: SessionStage,
        checkpoint: CookingSessionCheckpoint,
        stepIDs: [String],
        acceptedSubstitutions: [CookSubstitution] = []
    ) {
        self.stage = stage
        self.checkpoint = checkpoint
        self.stepIDs = stepIDs
        self.acceptedSubstitutions = acceptedSubstitutions
    }

    /// Timers whose deadline has passed but that were never acknowledged.
    /// Surfaced for the user; never acknowledged implicitly.
    public func expiredTimerIDs(now: Date) -> [String] {
        let deadline = now.timeIntervalSince1970
        return checkpoint.timers
            .filter { !$0.acknowledged && $0.deadlineEpochSeconds <= deadline }
            .map(\.id)
    }

    // MARK: Start

    /// Starts a session for a revision at its first step.
    public static func start(sessionID: String, revision: RecipeRevision, now: Date) throws -> CookSession {
        let stepIDs = revision.steps.map(\.stepID)
        guard !stepIDs.isEmpty else {
            throw FLFlowError.validation(target: "CookSession.start", reason: "a cooking session needs at least one step")
        }
        let checkpoint = try CookingSessionCheckpoint(
            sessionID: sessionID,
            recipeRevision: revision.key,
            stepIndex: 0,
            completedStepIDs: [],
            timers: [],
            updatedAt: now
        )
        return CookSession(stage: .cooking, checkpoint: checkpoint, stepIDs: stepIDs)
    }

    // MARK: Steps

    /// Completes the current step. On the last step this finishes the
    /// session — the meal-log hand-off state.
    public func completeStep(now: Date) throws -> CookSession {
        guard stage == .cooking else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "completeStep")
        }
        let index = checkpoint.stepIndex
        guard index < stepIDs.count else {
            throw FLFlowError.stepOutOfBounds(stepIndex: index, stepCount: stepIDs.count)
        }
        var completed = checkpoint.completedStepIDs
        completed.append(stepIDs[index])
        // stepIndex always advances to the next step to work — past the end
        // when this was the last one.
        let finished = index + 1 == stepIDs.count
        let next = try CookingSessionCheckpoint(
            sessionID: checkpoint.sessionID,
            recipeRevision: checkpoint.recipeRevision,
            stepIndex: index + 1,
            completedStepIDs: completed,
            timers: checkpoint.timers,
            updatedAt: now
        )
        return CookSession(
            stage: finished ? .finished : .cooking,
            checkpoint: next,
            stepIDs: stepIDs,
            acceptedSubstitutions: acceptedSubstitutions
        )
    }

    /// Advances to a later step without completing the current one
    /// (skipping ahead). Steps enter the completed list only through
    /// `completeStep`.
    public func advanceTo(stepIndex: Int, now: Date) throws -> CookSession {
        guard stage == .cooking else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "advanceTo")
        }
        guard stepIndex > checkpoint.stepIndex, stepIndex < stepIDs.count else {
            throw FLFlowError.stepOutOfBounds(stepIndex: stepIndex, stepCount: stepIDs.count)
        }
        let next = try CookingSessionCheckpoint(
            sessionID: checkpoint.sessionID,
            recipeRevision: checkpoint.recipeRevision,
            stepIndex: stepIndex,
            completedStepIDs: checkpoint.completedStepIDs,
            timers: checkpoint.timers,
            updatedAt: now
        )
        return CookSession(
            stage: .cooking,
            checkpoint: next,
            stepIDs: stepIDs,
            acceptedSubstitutions: acceptedSubstitutions
        )
    }

    // MARK: Timers

    /// Starts a timer on this device. Created here, so it is acknowledgeable
    /// here; nothing else ever sets createdOnDevice.
    public func addTimer(id: String, label: String, deadline: Date, now: Date) throws -> CookSession {
        guard stage != .finished else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "addTimer")
        }
        guard !checkpoint.timers.contains(where: { $0.id == id }) else {
            throw FLFlowError.validation(target: "CookSession.addTimer", reason: "timer id already exists in this session")
        }
        let record = try CookingSessionCheckpoint.TimerRecord(
            id: id,
            label: label,
            deadlineEpochSeconds: deadline.timeIntervalSince1970,
            createdOnDevice: true,
            acknowledged: false
        )
        let next = try CookingSessionCheckpoint(
            sessionID: checkpoint.sessionID,
            recipeRevision: checkpoint.recipeRevision,
            stepIndex: checkpoint.stepIndex,
            completedStepIDs: checkpoint.completedStepIDs,
            timers: checkpoint.timers + [record],
            updatedAt: now
        )
        return CookSession(
            stage: stage,
            checkpoint: next,
            stepIDs: stepIDs,
            acceptedSubstitutions: acceptedSubstitutions
        )
    }

    /// Acknowledges a timer. A timer not created on this device can never be
    /// acknowledged — the rule survives every path because the checkpoint
    /// itself refuses the constructed state. Acknowledging twice is a no-op.
    public func acknowledgeTimer(id: String, now: Date) throws -> CookSession {
        guard stage != .finished else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "acknowledgeTimer")
        }
        guard let index = checkpoint.timers.firstIndex(where: { $0.id == id }) else {
            throw FLFlowError.timerNotFound(timerID: id)
        }
        let record = checkpoint.timers[index]
        guard record.createdOnDevice else {
            throw FLFlowError.timerNotCreatedOnDevice(timerID: id)
        }
        guard !record.acknowledged else { return self }
        let updated = try CookingSessionCheckpoint.TimerRecord(
            id: record.id,
            label: record.label,
            deadlineEpochSeconds: record.deadlineEpochSeconds,
            createdOnDevice: record.createdOnDevice,
            acknowledged: true
        )
        var timers = checkpoint.timers
        timers[index] = updated
        let next = try CookingSessionCheckpoint(
            sessionID: checkpoint.sessionID,
            recipeRevision: checkpoint.recipeRevision,
            stepIndex: checkpoint.stepIndex,
            completedStepIDs: checkpoint.completedStepIDs,
            timers: timers,
            updatedAt: now
        )
        return CookSession(
            stage: stage,
            checkpoint: next,
            stepIDs: stepIDs,
            acceptedSubstitutions: acceptedSubstitutions
        )
    }

    // MARK: Pause and resume

    public func pause(now: Date) throws -> CookSession {
        guard stage == .cooking else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "pause")
        }
        let next = try CookingSessionCheckpoint(
            sessionID: checkpoint.sessionID,
            recipeRevision: checkpoint.recipeRevision,
            stepIndex: checkpoint.stepIndex,
            completedStepIDs: checkpoint.completedStepIDs,
            timers: checkpoint.timers,
            updatedAt: now
        )
        return CookSession(
            stage: .paused,
            checkpoint: next,
            stepIDs: stepIDs,
            acceptedSubstitutions: acceptedSubstitutions
        )
    }

    public func resume(now: Date) throws -> CookSession {
        guard stage == .paused else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "resume")
        }
        let next = try CookingSessionCheckpoint(
            sessionID: checkpoint.sessionID,
            recipeRevision: checkpoint.recipeRevision,
            stepIndex: checkpoint.stepIndex,
            completedStepIDs: checkpoint.completedStepIDs,
            timers: checkpoint.timers,
            updatedAt: now
        )
        return CookSession(
            stage: .cooking,
            checkpoint: next,
            stepIDs: stepIDs,
            acceptedSubstitutions: acceptedSubstitutions
        )
    }

    // MARK: Accepted substitutions

    /// Records a substitution the user accepted mid-cook (SPEC 3.3: the cook
    /// records what was swapped and why). Allowed while the cook is live —
    /// cooking or paused; a finished cook's record is complete and takes no
    /// new swaps.
    public func accept(substitution: CookSubstitution) throws -> CookSession {
        guard stage != .finished else {
            throw FLFlowError.invalidTransition(phase: String(describing: stage), operation: "accept(substitution:)")
        }
        var accepted = acceptedSubstitutions
        accepted.append(substitution)
        return CookSession(
            stage: stage,
            checkpoint: checkpoint,
            stepIDs: stepIDs,
            acceptedSubstitutions: accepted
        )
    }

    // MARK: Recovery after a restart
    // SPEC 3.3: after a kill the app holds a bare checkpoint. The decision
    // below is pure: what to show, and which timers ring unanswered.

    /// How stale a checkpoint may be before its step position is no longer
    /// trusted. `staleAbandonSeconds` bounds the whole window: past it, the
    /// session is abandoned — what happened meanwhile is unknowable, and
    /// pretending otherwise would invent progress.
    public struct RecoveryPolicy: Hashable, Sendable {
        public var freshWindowSeconds: Double
        public var staleAbandonSeconds: Double

        public init(freshWindowSeconds: Double = 120, staleAbandonSeconds: Double = 6 * 3600) {
            self.freshWindowSeconds = freshWindowSeconds
            self.staleAbandonSeconds = staleAbandonSeconds
        }

        public static let standard = RecoveryPolicy()
    }

    /// What a restart does with a bare checkpoint.
    public enum RecoveryDecision: Hashable, Sendable {
        /// Every step was completed before the interruption: go straight to
        /// the meal-log hand-off.
        case finished
        /// Resume at the step the checkpoint holds, re-presenting it.
        /// Expired, unacknowledged timers are surfaced for the user — never
        /// acknowledged implicitly.
        case resume(stepIndex: Int, expiredTimerIDs: [String])
        /// The checkpoint is too old to trust. The session is abandoned;
        /// the same revision can be cooked again from the start.
        case abandoned
    }

    /// Decides what a restart does with a checkpoint.
    public static func recover(
        checkpoint: CookingSessionCheckpoint,
        stepIDs: [String],
        now: Date,
        policy: RecoveryPolicy = .standard
    ) throws -> RecoveryDecision {
        try reinstate(checkpoint: checkpoint, stepIDs: stepIDs, now: now, policy: policy).intoDecision(now: now, policy: policy)
    }

    /// Rebuilds a live session from a bare checkpoint (restart path). Pause
    /// state is app-side and does not survive a kill: an un-finished session
    /// comes back cooking.
    public static func reinstate(
        checkpoint: CookingSessionCheckpoint,
        stepIDs: [String],
        now: Date,
        policy: RecoveryPolicy = .standard
    ) throws -> CookSession {
        guard !stepIDs.isEmpty else {
            throw FLFlowError.validation(target: "CookSession.reinstate", reason: "a cooking session needs at least one step")
        }
        let unknown = checkpoint.completedStepIDs.filter { !stepIDs.contains($0) }
        guard unknown.isEmpty else {
            throw FLFlowError.checkpointCorrupt(reason: "checkpoint names completed steps outside this revision: \(unknown.joined(separator: ", "))")
        }
        let finished = checkpoint.completedStepIDs.count == stepIDs.count
        if !finished {
            guard checkpoint.stepIndex < stepIDs.count else {
                throw FLFlowError.stepOutOfBounds(stepIndex: checkpoint.stepIndex, stepCount: stepIDs.count)
            }
        }
        let stage: SessionStage = finished ? .finished : .cooking
        return CookSession(stage: stage, checkpoint: checkpoint, stepIDs: stepIDs)
    }

    private func intoDecision(now: Date, policy: RecoveryPolicy) -> RecoveryDecision {
        guard stage != .finished else { return .finished }
        let elapsed = now.timeIntervalSince(checkpoint.updatedAt)
        guard elapsed <= policy.staleAbandonSeconds else { return .abandoned }
        return .resume(stepIndex: checkpoint.stepIndex, expiredTimerIDs: expiredTimerIDs(now: now))
    }
}
