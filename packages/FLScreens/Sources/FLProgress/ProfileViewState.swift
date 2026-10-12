// FLProgress — Profile, the screen pushed inside Progress.
//
// "Profile inside Progress, per the shell decision" — the shell decision
// already recorded in FLShellConfiguration (`shellS`): no Profile tab, no
// avatars, no display-name field, no gamification frames. The household
// is the account; the phone is the vault. One screen of rows, no cards —
// data controls are first-class rows, never buried settings, because the
// pantry-truth contract needs an explicit Forget (SPEC §3.2).
//
// Binding rules this state encodes (the Shell S Profile mocks, H and P):
//
// - The Evidence rows show their SIZE ("23 cooks of evidence · 4
//   sentences learned") so Forget is an informed choice, not a mystery
//   button. The summaries are host-verbatim display strings — this state
//   holds no structured taste, pantry or health data, and has no field
//   where one could arrive.
// - Forget is the last row, quiet by position, confirmed before it acts,
//   and reversible for exactly one undo window of 5 seconds (the mock's
//   "one undo window of 5 s", driven by host ticks — the state layer
//   owns no clock). "Recipes stay; the profile empties": forgetting
//   clears the taste evidence and nothing else.
// - The privacy line states the learning contract (SPEC §3.3): ranking
//   runs on-device; nothing is shared without a preview you approve.
// - Export writes cooks and pantry history to an on-device file; the
//   share sheet afterwards is the host's.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLProgressTests.

import Foundation

/// The whole Profile screen as a value.
public struct ProfileViewState: Equatable, Sendable {

    /// The Forget flow's phase.
    public enum ForgetPhase: Equatable, Sendable {
        /// Nothing pending.
        case idle
        /// The confirmation is up; nothing is forgotten yet.
        case confirming
        /// Confirmed. The evidence is hidden and the undo window runs
        /// until the stated epoch; when it closes (a host tick past it),
        /// the forget stands.
        case forgotten(undoUntil: TimeInterval)
    }

    // MARK: State

    /// "Flat 4B · 3 people", host-verbatim; nil hides the section (a
    /// household of one, untold, is simply not shown).
    public var householdLine: String?
    /// The taste profile row's size, host-verbatim ("23 cooks of
    /// evidence · 4 sentences learned"). A display string only — the
    /// taste data itself never enters this state.
    public var tasteSummary: String?
    /// The cookbook records row's size, host-verbatim ("84 cooks ·
    /// ratings, swaps, notes").
    public var cookbookSummary: String?
    /// The host's clock, in epoch seconds. The host keeps it current via
    /// `.tick` — the state layer owns no `Date()` (the LeChef
    /// `lastKnownNow` pattern). The undo window's arithmetic reads this.
    public var now: TimeInterval
    public var forgetPhase: ForgetPhase
    /// The receipt after a confirmed forget ("Forgotten."). Stays until
    /// the host replaces the state; the undo row lives beside it.
    public var forgetReceiptLine: String?

    public init(
        householdLine: String? = nil,
        tasteSummary: String? = nil,
        cookbookSummary: String? = nil
    ) {
        self.householdLine = householdLine
        self.tasteSummary = tasteSummary
        self.cookbookSummary = cookbookSummary
        self.now = 0
        self.forgetPhase = .idle
        self.forgetReceiptLine = nil
    }

    // MARK: Derived (always recomputed, never stored)

    /// The undo window's length — the mock's five seconds, as a named
    /// constant the tests pin.
    public static let undoWindowSeconds: TimeInterval = 5

    public var isConfirmingForget: Bool {
        forgetPhase == .confirming
    }

    public var isEvidenceForgotten: Bool {
        guard case .forgotten = forgetPhase else { return false }
        return true
    }

    /// The undo row lives while the window runs: forgotten, and the
    /// host's clock has not passed the deadline yet.
    public var isUndoAvailable: Bool {
        guard case .forgotten(let undoUntil) = forgetPhase else { return false }
        return now <= undoUntil
    }

    /// The confirmation's copy, carrying the size the user is about to
    /// forget: "Forget 23 cooks of evidence · 4 sentences learned?
    /// Recipes stay; the profile empties." nil when there is no taste
    /// evidence to forget.
    public var forgetConfirmLine: String? {
        guard let tasteSummary, !tasteSummary.isEmpty else { return nil }
        return "Forget \(tasteSummary)? Recipes stay; the profile empties."
    }

    /// The rows show the host's summaries until a forget stands.
    public var showsEvidenceRows: Bool {
        // The evidence rows are the TASTE section: hidden while a
        // confirmed forget is undoable and emptied for good at expiry.
        // The cookbook summary is its own row and outlives the forget —
        // recipes stay; the profile empties.
        tasteSummary != nil && !isEvidenceForgotten
    }
}
