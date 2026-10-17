import Foundation

// MARK: - Flow errors
// Same boundary discipline as FLDomain: every rejection rule of the flow
// contracts throws one error type, so a caller distinguishes "rejected at the
// boundary" from any other failure. Each rule has a test.

/// Errors thrown by FLFlowCore validated constructors and illegal transitions.
public enum FLFlowError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A field failed validation (empty, out of range, non-finite, ...).
    case validation(target: String, reason: String)

    /// A transition the session phase does not allow (e.g. pause while paused).
    case invalidTransition(phase: String, operation: String)

    /// A step index outside the recipe revision's steps.
    case stepOutOfBounds(stepIndex: Int, stepCount: Int)

    /// The step was already recorded as completed.
    case stepAlreadyCompleted(stepID: String)

    /// A step completion was requested out of order.
    case stepNotCurrent(expectedStepID: String, requestedStepID: String)

    /// No timer with this ID exists in the session.
    case timerNotFound(timerID: String)

    /// The acknowledgment rule (SPEC 4): a timer not created on the device can
    /// never be acknowledged.
    case timerNotCreatedOnDevice(timerID: String)

    /// A stored checkpoint cannot be decoded or contradicts its own contract.
    case checkpointCorrupt(reason: String)

    /// A stored checkpoint is too old, belongs to a different recipe revision,
    /// or disagrees with the revision's steps — resume is refused, never guessed.
    case checkpointStale(reason: String)

    /// The meal-log hand-off refuses to commit (authorization or consistency).
    case mealLogRefused(reason: String)

    public var description: String {
        switch self {
        case let .validation(target, reason):
            return "FLFlow validation failed for \(target): \(reason)"
        case let .invalidTransition(phase, operation):
            return "FLFlow illegal transition: \(operation) is not allowed in phase \(phase)"
        case let .stepOutOfBounds(stepIndex, stepCount):
            return "FLFlow step index \(stepIndex) is out of bounds for \(stepCount) steps"
        case let .stepAlreadyCompleted(stepID):
            return "FLFlow step '\(stepID)' is already completed"
        case let .stepNotCurrent(expectedStepID, requestedStepID):
            return "FLFlow step completion out of order: expected '\(expectedStepID)', got '\(requestedStepID)'"
        case let .timerNotFound(timerID):
            return "FLFlow timer '\(timerID)' not found"
        case let .timerNotCreatedOnDevice(timerID):
            return "FLFlow timer '\(timerID)' was not created on this device and can never be acknowledged"
        case let .checkpointCorrupt(reason):
            return "FLFlow checkpoint is corrupt: \(reason)"
        case let .checkpointStale(reason):
            return "FLFlow checkpoint is stale: \(reason)"
        case let .mealLogRefused(reason):
            return "FLFlow meal log refused: \(reason)"
        }
    }
}
