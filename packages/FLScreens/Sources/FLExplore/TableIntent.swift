// FLExplore — Table's typed intents and the reducer.
//
// The reducer owns the observable presentation transitions: the share
// preview freezing exactly the shareable fields, and its dismissal.
// Everything else is host-routed — table membership, invites, the actual
// share, cooks and challenges are backend truths that arrive as new state.
// No intent here can widen what a share carries: the preview is built only
// from the fields the cook recorded (see `TableViewState.SharePreview`).

import Foundation

/// Everything the Table screen can send.
public enum TableIntent: Equatable, Sendable {

    // Presentation logic (reducer-owned)

    /// "Share" on a cook card: the preview freezes exactly what leaves the
    /// phone before anything leaves it.
    case showSharePreview(cookID: String)
    /// The preview was dismissed without sharing.
    case dismissSharePreview
    /// "Share" on the preview — submits the FROZEN preview payload. The
    /// host publishes exactly what was previewed; nothing is re-derived
    /// at send time, so what the cook approved is what leaves.
    case confirmShare(TableViewState.SharePreview)

    // Navigation / effects (host-routed; reducer is identity)

    /// The header's "Invite" — the share sheet with a code and an
    /// owner-approved link. Invites are revocable; members can leave,
    /// block and report (account features, host-side).
    case invite
    /// The no-table state's two escapes, ranked equal.
    case startTable
    case joinWithCode
    /// The card's one button — "Cook tonight", "Cook with swap" or
    /// "Open recipe"; the title is the state's, the outcome is the host's.
    case cookTonight(cookID: String)
    /// A card's dish, or a notes row — pushes the Recipe screen.
    case openRecipe(recipeID: String)
    case joinChallenge
    /// "Retry" after a failed fetch.
    case retryFetch
    /// Members can leave; the host confirms and commits.
    case leaveTable
}

/// The reducer: pure, total over intents. `TableViewState.apply(_:)` is
/// the convenience views use.
public enum TableReducer {

    public static func reduced(_ state: TableViewState, by intent: TableIntent) -> TableViewState {
        var next = state
        switch intent {

        case .showSharePreview(let cookID):
            // Freeze the preview from the cook's typed record fields
            // only: the dish title AND its revision identity, the
            // day-only when, the recorded substitutions as the typed
            // swap list. `detailDisplay` never feeds the share (it may
            // describe duration, not a substitution). A cook that is not
            // on the table (stale id, other device) opens no preview —
            // nothing is invented to fill one.
            guard let cook = next.cooks.first(where: { $0.id == cookID }) else { break }
            next.sharePreview = TableViewState.SharePreview(
                cookID: cook.id,
                recipeDisplay: cook.dishTitle,
                revisionDisplay: cook.recipeRevisionKey,
                when: cook.when,
                servingsDisplay: "for \(cook.servings)",
                swaps: cook.swaps,
                ratingDisplay: cook.ratingDisplay,
                noteDisplay: cook.note
            )

        case .dismissSharePreview:
            next.sharePreview = nil

        // Navigation and effects: the host owns the outcome.
        case .invite, .startTable, .joinWithCode, .cookTonight, .openRecipe,
             .confirmShare, .joinChallenge, .retryFetch, .leaveTable:
            break
        }
        return next
    }
}

extension TableViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: TableIntent) {
        self = TableReducer.reduced(self, by: intent)
    }
}
