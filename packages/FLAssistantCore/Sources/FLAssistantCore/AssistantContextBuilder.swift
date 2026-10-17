import Foundation
import FLDomain

// MARK: - Context builder
// SPEC §4: "The backend reads bounded snapshots and proposes typed actions."
// The builder assembles an `AssistantContextSnapshot` from the app's state
// through an injectable source (the host's stores own the data; Parts 2 and 3
// land their own types, so this layer reads through this seam, never theirs).
//
// Two authority invariants live here:
// - Bounded: pantry summaries are capped (`maxPantryLines`); the provider owns
//   the relevance order, the builder enforces the bound.
// - Honest about the unknown: lines carry `QuantityEvidence` through untouched.
//   `.unknown` never becomes a number — recognition confidence is not quantity
//   confidence (SPEC §3.2).

/// The app state a snapshot is built from. The host injects an adapter over
/// its own stores; this package never reaches into them.
public protocol AssistantStateSource: Sendable {
    /// Pantry lines in the provider's own relevance order (e.g. soonest
    /// expiring first). The builder caps the count; ordering is the provider's
    /// contract, never the builder's guess.
    func pantryLines() throws -> [AssistantPantryLine]

    /// The recipe the session is attached to, when any.
    func recipeContext() throws -> RecipeKey?

    /// The current 0-based step index, when a cook session is attached.
    func currentStepIndex() throws -> Int?
}

/// Assembles bounded `AssistantContextSnapshot` values. Stateless itself —
/// the revision clock (an actor) is what serializes concurrent state changes
/// and reads.
public struct AssistantContextBuilder: Sendable {
    /// The hard cap on pantry lines. SPEC §4: snapshots are bounded; a
    /// provider returning more than this is truncated in the provider's own
    /// order — the snapshot never grows with the pantry.
    public static let defaultMaxPantryLines = 40

    private let stateSource: any AssistantStateSource
    private let revisionClock: AssistantRevisionClock
    private let maxPantryLines: Int

    public init(
        stateSource: any AssistantStateSource,
        revisionClock: AssistantRevisionClock,
        maxPantryLines: Int = AssistantContextBuilder.defaultMaxPantryLines
    ) {
        self.stateSource = stateSource
        self.revisionClock = revisionClock
        self.maxPantryLines = max(1, maxPantryLines)
    }

    /// Build a snapshot for `sessionID`, stamped with the clock's current
    /// revision and `now`. Unknown quantity evidence passes through as unknown;
    /// the builder invents nothing.
    public func buildSnapshot(sessionID: String, now: Date) async throws -> AssistantContextSnapshot {
        let lines = try stateSource.pantryLines()
        let recipe = try stateSource.recipeContext()
        let step = try stateSource.currentStepIndex()
        let summary = try lines.prefix(maxPantryLines).map {
            try AssistantContextSnapshot.makePantryLine(
                canonicalName: $0.canonicalName,
                quantity: $0.quantity,
                lastConfirmedAt: $0.lastConfirmedAt
            )
        }
        let revision = await revisionClock.current()
        return try AssistantContextSnapshot(
            sessionID: sessionID,
            revision: revision,
            capturedAt: now,
            pantrySummary: summary,
            recipeContext: recipe,
            stepIndex: step
        )
    }
}
