import Foundation

/// Practice sessions write no real meal log and never consume Kitchen stock.
public enum CookingMode: String, Codable, Equatable {
    case practice
    case real
}

public enum CookingSessionPhase: String, Codable, Equatable {
    /// User is mid-cook; checkpoints can be saved and resumed.
    case active
    /// Finished: real mode only when the logging API returned a receipt
    /// (stored in `CookingCheckpoint.receipt`); practice completion records
    /// the phase locally and writes no meal.
    case completed
    /// User explicitly abandoned; kept for audit, never auto-resumed.
    case abandoned
}

/// Progress positions are indices into the parsed steps the session was
/// started with, and are never re-applied to different text without the
/// user's deliberate reconciliation.
public struct CookingProgress: Codable, Equatable {
    /// Indices into the parsed steps of the fingerprinted instructions, sorted.
    public var completedSteps: [Int]
    /// Checklist item id -> done.
    public var checklist: [String: Bool]
    /// Ingredient id -> substitute id chosen for this cook.
    public var substitutions: [String: String]

    public init(
        completedSteps: [Int] = [],
        checklist: [String: Bool] = [:],
        substitutions: [String: String] = [:]
    ) {
        self.completedSteps = completedSteps.sorted()
        self.checklist = checklist
        self.substitutions = substitutions
    }

    public mutating func toggleStep(_ index: Int) {
        if let i = completedSteps.firstIndex(of: index) {
            completedSteps.remove(at: i)
        } else {
            completedSteps.append(index)
            completedSteps.sort()
        }
    }
}

/// Identity of one cooking run. `planID` carries the accepted-plan identity
/// from the planning flow for real-mode sessions; practice sessions have none
/// and must never write one.
public struct CookingSessionIdentity: Codable, Equatable {
    public var sessionID: UUID
    public var mode: CookingMode
    public var planID: String?
    public var fingerprint: RecipeFingerprint
    public var startedAt: Date

    public init(
        sessionID: UUID = UUID(),
        mode: CookingMode,
        planID: String?,
        fingerprint: RecipeFingerprint,
        startedAt: Date
    ) {
        self.sessionID = sessionID
        self.mode = mode
        self.planID = planID
        self.fingerprint = fingerprint
        self.startedAt = startedAt
    }
}

/// Receipt returned by the accepted-plan logging API when a real-mode
/// completion is accepted. Its presence — never optimism or a pending flag
/// alone — is the only proof a meal was logged and stock consumed.
public struct AcceptanceReceipt: Codable, Equatable {
    public var receiptID: String
    public var planID: String
    public var sessionID: UUID
    public var loggedAt: Date

    public init(receiptID: String, planID: String, sessionID: UUID, loggedAt: Date) {
        self.receiptID = receiptID
        self.planID = planID
        self.sessionID = sessionID
        self.loggedAt = loggedAt
    }
}

/// One versioned checkpoint of a cooking session.
///
/// Completion states, exactly:
/// - `phase == .active`                     → in progress, resumable.
/// - `phase == .active, completionPending`  → finish attempted, logging API
///   has NOT confirmed; on relaunch the app must finish-or-reconcile, never
///   claim success and never log twice.
/// - `phase == .completed, receipt != nil`  → real completion accepted.
/// - `phase == .completed, receipt == nil`  → practice completion only; no
///   meal was logged and no stock consumed.
public struct CookingCheckpoint: Codable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var identity: CookingSessionIdentity
    public var phase: CookingSessionPhase
    public var progress: CookingProgress
    public var completionPending: Bool
    public var receipt: AcceptanceReceipt?
    public var savedAt: Date

    public init(
        identity: CookingSessionIdentity,
        phase: CookingSessionPhase = .active,
        progress: CookingProgress = CookingProgress(),
        completionPending: Bool = false,
        receipt: AcceptanceReceipt? = nil,
        savedAt: Date = Date(),
        schemaVersion: Int = CookingCheckpoint.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.phase = phase
        self.progress = progress
        self.completionPending = completionPending
        self.receipt = receipt
        self.savedAt = savedAt
    }
}
