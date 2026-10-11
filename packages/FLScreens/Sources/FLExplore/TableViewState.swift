// FLExplore — the Table screen's view state.
//
// A table is 2 to 8 people who eat together or near each other (Direction
// H's Table note). The binding rules this state encodes:
//
// - The unit is a COOK, created by finishing one: dish, who, when, the
//   one-line note, rating, substitutions, optional photo. Nobody writes a
//   post — the state has no field for one.
// - Cards are in TIME ORDER, no ranking. The screen preserves the host's
//   order exactly; a sort here would be a ranking, which the mock bans.
// - Every card ends with the viewer's OWN fit meter and one button. Your
//   own cook has no button — it is here so the table sees what you see.
// - No likes, no comments, no follower counts. The state has no field for
//   any of them.
// - The table is beta: it is reached from Explore's "Community tables —
//   Beta" row, never from a tab. The flag itself lives on ExploreViewState
//   (`tablesEnabled`); this screen is what that row opens.
// - Before any share, a preview states exactly what leaves the phone:
//   recipe revision, servings, swaps, rating, one-line note — and never
//   pantry, health, taste data or exact times. The `SharePreview` struct
//   has no fields for the never-list, so a preview cannot leak them.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLExploreTests.

import FLScreenSupport

/// The whole Table screen as a value.
public struct TableViewState: Equatable, Sendable {

    /// One cook card: what a member actually cooked.
    public struct Cook: Equatable, Sendable, Identifiable {

        public var id: String
        /// Who cooked it: "Maya", "Dev", or "You" (see `isOwn`).
        public var cookName: String
        /// The viewer cooked this one — no button renders on it.
        public var isOwn: Bool
        /// "Mon 21:40" — the day precision the share rule allows. Exact
        /// times beyond the day never leave the phone; display is host's.
        public var whenDisplay: String
        /// Servings the cook actually made — part of the cook record, and
        /// the only source for the share preview's "for 2" clause.
        public var servings: Int
        /// The dish that was cooked — pushed to Recipe by the button.
        public var recipeID: String
        public var dishTitle: String
        /// The one-line note, when the cook wrote one.
        public var note: String?
        /// "5 of 5" — the cook's own rating of the result.
        public var ratingDisplay: String?
        /// "swapped spinach for kale", "18 min" — the trailing clause.
        public var detailDisplay: String?
        /// The 1:1 thumbnail's working caption, when a photo exists.
        public var photoCaption: String?
        public var fit: FLFitSummary

        public init(
            id: String, cookName: String, isOwn: Bool, whenDisplay: String,
            servings: Int, recipeID: String, dishTitle: String, note: String? = nil,
            ratingDisplay: String? = nil, detailDisplay: String? = nil,
            photoCaption: String? = nil, fit: FLFitSummary
        ) {
            self.id = id
            self.cookName = cookName
            self.isOwn = isOwn
            self.whenDisplay = whenDisplay
            self.servings = max(1, servings)
            self.recipeID = recipeID
            self.dishTitle = dishTitle
            self.note = note
            self.ratingDisplay = ratingDisplay
            self.detailDisplay = detailDisplay
            self.photoCaption = photoCaption
            self.fit = fit
        }

        /// "5 of 5 · swapped spinach for kale" — the mono line under the
        /// note. Parts the cook actually recorded; nothing invented.
        public var rateDisplay: String? {
            let parts = [ratingDisplay, detailDisplay].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The one button per card, derived from the viewer's own fit:
        /// complete → "Cook tonight"; a real swap → "Cook with swap";
        /// neither → "Open recipe" (never a promise the kitchen cannot
        /// keep). The viewer's own cook has no button at all.
        public var buttonTitle: String? {
            guard !isOwn else { return nil }
            if fit.isComplete { return "Cook tonight" }
            if fit.swapsNeeded > 0 { return "Cook with swap" }
            return "Open recipe"
        }

        /// The button's kind: primary when the kitchen covers the dish,
        /// quiet when a swap stands between.
        public var buttonIsPrimary: Bool { fit.isComplete }
    }

    /// A "Notes on recipes you've cooked" row — the table's accumulated
    /// wisdom about dishes this table has cooked, from the cooks' notes.
    public struct NoteRow: Equatable, Sendable, Identifiable {

        public var id: String
        public var dish: String
        /// The community note: "Add the ginger late or it burns." or
        /// "38% add lemon. You and Maya both do."
        public var noteLine: String
        /// Distinct cooks of this dish across the table. Nil when unknown.
        public var cookCount: Int?

        public init(id: String, dish: String, noteLine: String, cookCount: Int? = nil) {
            self.id = id
            self.dish = dish
            self.noteLine = noteLine
            self.cookCount = cookCount
        }

        /// "212 cooks" at ten or more; "under 10" below — the count is
        /// never invented into prominence (the mock's c3 styling).
        public var cooksDisplay: String? {
            switch cookCount {
            case nil: return nil
            case .some(let count) where count >= 10: return "\(count) cooks"
            default: return "under 10"
            }
        }
    }

    /// The week's community challenge — rendered quietly, entries reward
    /// cooks made and food saved, never opens.
    public struct Challenge: Equatable, Sendable {

        public var id: String
        /// "Three ingredients, what can you make?"
        public var title: String
        /// "Rice, eggs, frozen peas · works alone · share your result"
        public var detailDisplay: String
        /// "Join"
        public var actionTitle: String

        public init(id: String, title: String, detailDisplay: String, actionTitle: String) {
            self.id = id
            self.title = title
            self.detailDisplay = detailDisplay
            self.actionTitle = actionTitle
        }
    }

    /// Exactly what leaves the phone on a share, frozen at preview time.
    /// The struct's shape is the privacy contract: there is no field for
    /// pantry, health, taste data, or times beyond the day, so a preview
    /// cannot be widened by a bug. No photo in the first release.
    public struct SharePreview: Equatable, Sendable {

        public var cookID: String
        public var recipeDisplay: String
        public var servingsDisplay: String
        public var swapsDisplay: String?
        public var ratingDisplay: String?
        /// The one-line note, only if the cook wrote one.
        public var noteDisplay: String?

        public init(
            cookID: String, recipeDisplay: String, servingsDisplay: String,
            swapsDisplay: String? = nil, ratingDisplay: String? = nil,
            noteDisplay: String? = nil
        ) {
            self.cookID = cookID
            self.recipeDisplay = recipeDisplay
            self.servingsDisplay = servingsDisplay
            self.swapsDisplay = swapsDisplay
            self.ratingDisplay = ratingDisplay
            self.noteDisplay = noteDisplay
        }
    }

    /// The screen's phase. Cached cards render instantly in every phase
    /// that has them; the host owns the fetch, this layer owns honesty
    /// about what the user is looking at.
    public enum Phase: Equatable, Sendable {
        /// No table yet — the start/join state. The notes section still
        /// renders from the viewer's own cooks.
        case noTable
        /// The normal state.
        case active
        /// Fetch failed with nothing cached. The cooks are safe on this
        /// phone; "Retry" is the way back.
        case fetchFailed
    }

    // MARK: State

    public var phase: Phase
    /// "Flat 4B" — nil in the no-table phase.
    public var tableName: String?
    /// Members of the table, viewer included. A table works from 2.
    public var memberCount: Int
    /// The cooks, in TIME ORDER as the host supplies them. Never re-ordered.
    public var cooks: [Cook]
    /// The notes rows for dishes this table has cooked.
    public var notes: [NoteRow]
    /// This week's challenge, when there is one.
    public var challenge: Challenge?
    /// "Nobody's cooked this week. Your last was Sunday." — the quiet
    /// week, stated instead of an empty silence.
    public var weekSummary: String?
    /// The share preview while it is up; nil when not sharing.
    public var sharePreview: SharePreview?
    /// Provenance for cached content while offline ("As of 18:40"). Fit
    /// still computes on device. Notes hide offline.
    public var asOf: String?
    /// One 2 pt line under the week row while fetching (cached cards stay).
    public var isFetching: Bool

    public init(
        phase: Phase = .noTable, tableName: String? = nil, memberCount: Int = 1,
        cooks: [Cook] = [], notes: [NoteRow] = [], challenge: Challenge? = nil,
        weekSummary: String? = nil, sharePreview: SharePreview? = nil,
        asOf: String? = nil, isFetching: Bool = false
    ) {
        self.phase = phase
        self.tableName = tableName
        self.memberCount = memberCount
        self.cooks = cooks
        self.notes = notes
        self.challenge = challenge
        self.weekSummary = weekSummary
        self.sharePreview = sharePreview
        self.asOf = asOf
        self.isFetching = isFetching
    }

    // MARK: Derived

    /// The line under the header: "Flat 4B · 3 people · in time order,
    /// no ranking" — the no-ranking promise is part of the furniture.
    public var subtitleDisplay: String? {
        guard phase == .active, let tableName else { return nil }
        let people = memberCount == 1 ? "1 person" : "\(memberCount) people"
        return "\(tableName) · \(people) · in time order, no ranking"
    }

    /// Alone in a table (or not yet in one): the invite row shows —
    /// "Invite someone. Tables work from 2."
    public var viewerIsAlone: Bool { memberCount <= 1 }

    /// Notes hide offline (the mock's states note) — they are the one
    /// section the device cannot compute. Cards, fits and the challenge
    /// stay.
    public var showsNotes: Bool {
        phase != .fetchFailed && asOf == nil
    }
}
