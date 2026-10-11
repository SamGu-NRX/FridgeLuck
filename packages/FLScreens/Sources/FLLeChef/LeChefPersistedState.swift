// FLLeChef — the persisted session snapshot.
//
// SPEC §3.4: LeChef keeps no camera frames and no transcript beyond the
// live session unless the user explicitly saves a note. This type is the
// ONLY shape the host may write to disk for resume, and it is built by
// an explicit field-by-field recording from the live state — there is no
// Codable-of-everything path a new live field could sneak through. The
// fields are scalars, timer records, and the explicitly saved rating and
// note. A transcript turn, a look result, or a frame has no field to
// land in — by construction, and asserted by tests (a Mirror walk of the
// declared fields, plus a recording test that fills every live-only
// surface and checks the recording came out clean).
//
// The transcript toggle itself is also deliberately not persisted: voice
// is opt-in PER COOK (SPEC §4), so a restored session starts with "Just
// the steps" again.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLLeChefTests.

import Foundation

/// The on-device resume snapshot for a cook session.
public struct LeChefPersistedState: Equatable, Sendable {

    /// Which live stages a snapshot records. A killed app at `cooking`,
    /// `paused` or `complete` resumes; `idle` and `cancelled` record nil
    /// — nothing to resume.
    public var stage: LeChefViewState.Stage

    public var revisionId: String
    public var dishName: String
    public var servings: Int
    public var stepIndex: Int
    public var startedAt: TimeInterval

    /// One timer's persisted record. Deadlines are epoch seconds —
    /// "the timer still counting" after a reopen.
    public struct TimerRecord: Equatable, Sendable {
        public var id: String
        public var label: String
        public var totalSeconds: Int
        public var endAt: TimeInterval?
        public var pausedRemaining: Int?
        public var fired: Bool
        public var onDoneLine: String?

        public init(
            id: String, label: String, totalSeconds: Int,
            endAt: TimeInterval? = nil, pausedRemaining: Int? = nil,
            fired: Bool = false, onDoneLine: String? = nil
        ) {
            self.id = id
            self.label = label
            self.totalSeconds = totalSeconds
            self.endAt = endAt
            self.pausedRemaining = pausedRemaining
            self.fired = fired
            self.onDoneLine = onDoneLine
        }
    }

    public var timers: [TimerRecord]

    /// Substitution proposals the user approved, so a restored session
    /// still shows what was swapped.
    public var appliedSwapIds: [String]

    /// The explicitly saved rating and one-line note. The note draft is
    /// never here — only an explicit save lands it.
    public var rating: Int?
    public var savedNote: String?

    public init(
        stage: LeChefViewState.Stage, revisionId: String, dishName: String,
        servings: Int, stepIndex: Int, startedAt: TimeInterval,
        timers: [TimerRecord], appliedSwapIds: [String],
        rating: Int? = nil, savedNote: String? = nil
    ) {
        self.stage = stage
        self.revisionId = revisionId
        self.dishName = dishName
        self.servings = servings
        self.stepIndex = stepIndex
        self.startedAt = startedAt
        self.timers = timers
        self.appliedSwapIds = appliedSwapIds
        self.rating = rating
        self.savedNote = savedNote
    }

    /// Record a live session for resume. Returns nil for the stages
    /// that have nothing to resume (idle, cancelled) — the host clears
    /// the snapshot on those.
    public static func recording(_ state: LeChefViewState) -> LeChefPersistedState? {
        switch state.stage {
        case .idle, .cancelled:
            return nil
        case .cooking, .paused, .complete:
            guard let recipe = state.recipe else { return nil }
            return LeChefPersistedState(
                stage: state.stage,
                revisionId: recipe.revisionId,
                dishName: recipe.dishName,
                servings: recipe.servings,
                stepIndex: state.stepIndex,
                startedAt: state.startedAt,
                timers: state.timers.map {
                    TimerRecord(
                        id: $0.id, label: $0.label, totalSeconds: $0.totalSeconds,
                        endAt: $0.endAt, pausedRemaining: $0.pausedRemaining,
                        fired: $0.fired, onDoneLine: $0.onDoneLine
                    )
                },
                appliedSwapIds: state.proposals
                    .filter { $0.isApplied && $0.job == .substitute }
                    .map { $0.id },
                rating: state.rating,
                savedNote: state.savedNote
            )
        }
    }
}
