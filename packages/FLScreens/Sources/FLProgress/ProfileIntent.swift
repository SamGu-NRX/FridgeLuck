// FLProgress — Profile's typed intents and the reducer.
//
// The reducer owns the Forget flow's phase machine: confirm, cancel,
// forget, undo within the window, expiry by host tick. Navigation rows
// (taste profile, cookbook records, export, sign out) are host-routed —
// the state layer records nothing for them, exactly like Kitchen's
// ingredient taps.
//
// The clock is the state's: the host keeps `now` current via `.tick`
// (the LeChef `lastKnownNow` pattern). Confirm and undo therefore carry
// no epoch — they are judged on the state's own clock, and a confirm
// without a recent tick simply arms the window from a stale `now`, a
// host bug the tests can pin rather than a silent reordering.

import Foundation

/// Everything the Profile screen can send.
public enum ProfileIntent: Equatable, Sendable {

    // The Forget flow

    /// Ask to forget: shows the confirmation with the size baked into
    /// its copy. Refused when there is no taste evidence to forget.
    case requestForget
    case cancelForget
    /// Confirmed — the undo window arms from the state's clock (`now`).
    case confirmForget
    /// Undo; only within the window, judged on the state's clock.
    case undoForget
    /// The host's clock tick: refreshes `now`, then judges expiry.
    case tick(at: TimeInterval)

    // Host-routed rows (the host owns the destinations)

    case openTasteProfile
    case openCookbookRecords
    case requestExport
    case requestSignOut
}

/// The reducer: pure, total over intents. `ProfileViewState.apply(_:)`
/// is the convenience views use.
public enum ProfileReducer {

    public static func reduced(_ state: ProfileViewState, by intent: ProfileIntent) -> ProfileViewState {
        var next = state
        switch intent {

        case .requestForget:
            // No taste evidence, nothing to forget — the flow does not
            // open. (The row hides with the evidence too; this guard is
            // the state-layer backstop.)
            guard next.tasteSummary != nil else { break }
            next.forgetPhase = .confirming

        case .cancelForget:
            next.forgetPhase = .idle

        case .confirmForget:
            next.forgetPhase = .forgotten(
                undoUntil: next.now + ProfileViewState.undoWindowSeconds
            )
            next.forgetReceiptLine = "Forgotten."

        case .undoForget:
            // Within the window the forget reverses and the evidence is
            // exactly as it was. Past it, the undo is refused — the
            // window has closed, the forget stands.
            guard case .forgotten(let undoUntil) = next.forgetPhase,
                  next.now <= undoUntil
            else { break }
            next.forgetPhase = .idle
            next.forgetReceiptLine = nil

        case .tick(let at):
            // The clock refreshes first: every later judgement in this
            // reduction sees the tick's instant, never the stale one.
            next.now = at
            // Past the undo window the forget stands: the phase closes
            // and the taste evidence is cleared for good. The cookbook
            // summary survives ("Recipes stay; the profile empties").
            if case .forgotten(let undoUntil) = next.forgetPhase, at > undoUntil {
                next.tasteSummary = nil
                next.forgetPhase = .idle
            }

        // Host-routed rows: no local state.
        case .openTasteProfile, .openCookbookRecords, .requestExport, .requestSignOut:
            break
        }
        return next
    }
}

extension ProfileViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: ProfileIntent) {
        self = ProfileReducer.reduced(self, by: intent)
    }
}
