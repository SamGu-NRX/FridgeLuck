// FLExplore — Explore's view state.
//
// "What could I cook that others made?" (Direction H's Explore note). The
// binding rules this state encodes:
//
// - Ranked by what you can make now: every row carries the viewer's own
//   fit line, in mono. The screen derives the rank bands from the fit —
//   they are presentation logic, not host data.
// - Social proof is honest: "cooked by 37 people" appears only at ten
//   distinct cooks or more, and only from opted-in data. Under ten, the
//   row says "Be the first to cook this"; with no opted-in count it says
//   nothing at all. No like counts, no follower counts — the state has no
//   field for either.
// - User recipes and catalog recipes share the list without a visual
//   caste. A LeChef draft keeps its own section ("Made for your fridge")
//   and carries no cook notes until tested.
// - Search never dead-ends: zero hits state the query and offer fewer
//   filters — never a blank page.
// - A published recipe pending moderation shows "In review — only you can
//   see it" and can be withdrawn at any time.
// - Table is INSIDE Explore behind its beta flag: the "Community tables"
//   entry row renders only while the flag is on. Table is not a tab.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLExploreTests.

import FLScreenSupport

/// The whole Explore screen as a value. SwiftUI views render exactly this;
/// typed intents (`ExploreIntent`) flow back through the host's send
/// closure and the reducer (`ExploreReducer`) applies the presentation-
/// logic ones.
public struct ExploreViewState: Equatable, Sendable {

    /// One recipe row in the feed. The host supplies the recipe's truth
    /// (publisher, cook count, minutes, fit); the screen derives every
    /// display string under the honesty rules.
    public struct Row: Equatable, Sendable, Identifiable {

        public var id: String
        public var title: String
        /// The publisher clause: "Maya", "Published by Tom", "Catalog".
        public var publisherDisplay: String
        /// Distinct cooks, opted-in data only. Nil when nobody opted in —
        /// the display rules never invent a number from absence.
        public var distinctCooks: Int?
        /// Total minutes; the display derives ("35 min"). Numeric so the
        /// under-30 filter stays testable — a display string would not be.
        public var minutes: Int
        public var fit: FLFitSummary
        public var isVegetarian: Bool
        /// A LeChef draft: its own section, no cook notes until tested.
        public var isLeChefDraft: Bool
        /// The viewer's own published recipe, still in moderation review.
        public var isPendingReview: Bool
        /// The row thumbnail's working caption, when the recipe has a
        /// photo. Thumbnails obey the 3:2 photo rule like every surface.
        public var photoCaption: String?

        public init(
            id: String, title: String, publisherDisplay: String, distinctCooks: Int? = nil,
            minutes: Int, fit: FLFitSummary, isVegetarian: Bool = false,
            isLeChefDraft: Bool = false, isPendingReview: Bool = false,
            photoCaption: String? = nil
        ) {
            self.id = id
            self.title = title
            self.publisherDisplay = publisherDisplay
            self.distinctCooks = distinctCooks
            self.minutes = minutes
            self.fit = fit
            self.isVegetarian = isVegetarian
            self.isLeChefDraft = isLeChefDraft
            self.isPendingReview = isPendingReview
            self.photoCaption = photoCaption
        }

        /// "35 min".
        public var minutesDisplay: String { "\(minutes) min" }

        /// The ten-cook minimum (the mock's note: "cooked by 37 people"
        /// appears only above ten distinct cooks). At or above ten, the
        /// count; under ten, the invitation; with no opted-in data, nothing.
        public var socialDisplay: String? {
            switch distinctCooks {
            case nil: return nil
            case .some(let count) where count >= 10: return "cooked by \(count) people"
            default: return "Be the first to cook this"
            }
        }

        /// The caption under the title. A row in review says exactly that
        /// and nothing else — the moderation state outranks social proof.
        public var captionDisplay: String {
            if isPendingReview { return "In review — only you can see it" }
            let social = socialDisplay.map { " · \($0)" } ?? ""
            return "\(publisherDisplay)\(social)"
        }

        /// Rank band membership (see `Section.Band`). Drafts always go to
        /// their own section first, whatever their fit says.
        public var band: Section.Band {
            if isLeChefDraft { return .madeForYourFridge }
            if fit.isComplete { return .canCookNow }
            if fit.swapsNeeded > 0 { return .oneSwapAway }
            return .moreToCook
        }
    }

    /// The filter chips. The RANKING effect of each filter is the host's;
    /// this layer owns the selection bookkeeping and the two rules the
    /// screen can compute (minutes and vegetarian) so the feed logic is
    /// testable. "Any cuisine" is the absence of a cuisine filter — it is
    /// not a case here.
    public enum Filter: String, Equatable, Sendable, CaseIterable {
        case canCookNow
        case underThirtyMinutes
        case vegetarian

        public var title: String {
            switch self {
            case .canCookNow: return "Can cook now"
            case .underThirtyMinutes: return "Under 30 min"
            case .vegetarian: return "Vegetarian"
            }
        }

        /// Whether the row passes this filter.
        func accepts(_ row: Row) -> Bool {
            switch self {
            case .canCookNow: return row.fit.isComplete
            case .underThirtyMinutes: return row.minutes < 30
            case .vegetarian: return row.isVegetarian
            }
        }
    }

    /// A derived feed section. The bands are the mock's structure: drafts,
    /// then what you can cook now, then what is one swap away. A band the
    /// mock does not draw ("moreToCook") catches rows that are neither
    /// complete nor swap-covered — the screen never silently drops a row.
    public struct Section: Equatable, Sendable, Identifiable {

        public enum Band: String, Equatable, Sendable, CaseIterable {
            case madeForYourFridge
            case canCookNow
            case oneSwapAway
            case moreToCook

            /// The section heading, in the mock's voice.
            public var title: String {
                switch self {
                case .madeForYourFridge: return "Made for your fridge"
                case .canCookNow: return "Can cook now"
                case .oneSwapAway: return "One swap away"
                case .moreToCook: return "More to cook"
                }
            }
        }

        public var band: Band
        public var rows: [Row]

        public var id: String { band.rawValue }
    }

    // MARK: State

    /// Every known row, in the host's ranking. The screen never re-ranks;
    /// grouping preserves this order inside each band.
    public var rows: [Row]
    /// The live search text. An empty query means no search is running.
    public var query: String
    /// The selected filter chips.
    public var activeFilters: Set<Filter>
    /// The beta flag: the Community-tables entry row renders only while
    /// this is on (Sam's round decision — Table is not a tab).
    public var tablesEnabled: Bool
    /// Provenance for cached rows while offline ("As of 18:40"). Fit still
    /// computes on device — nothing here waits on the network.
    public var asOf: String?
    /// Rows arrive late: one indeterminate line while they load, over the
    /// last valid list (which may be empty).
    public var rowsLoading: Bool

    public init(
        rows: [Row] = [], query: String = "", activeFilters: Set<Filter> = [],
        tablesEnabled: Bool = false, asOf: String? = nil, rowsLoading: Bool = false
    ) {
        self.rows = rows
        self.query = query
        self.activeFilters = activeFilters
        self.tablesEnabled = tablesEnabled
        self.asOf = asOf
        self.rowsLoading = rowsLoading
    }

    // MARK: Derived feed

    /// Rows after the selected filters and the search query. The search
    /// matches title or publisher, case-insensitive; an empty query
    /// matches everything.
    public var visibleRows: [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            activeFilters.allSatisfy { $0.accepts(row) }
                && (trimmed.isEmpty
                    || row.title.localizedCaseInsensitiveContains(trimmed)
                    || row.publisherDisplay.localizedCaseInsensitiveContains(trimmed))
        }
    }

    /// The feed's sections: bands in rank order, each with the visible
    /// rows that belong to it. Empty bands are omitted — the mock never
    /// draws a section heading over nothing.
    public var sections: [Section] {
        Section.Band.allCases.compactMap { band in
            let bandRows = visibleRows.filter { $0.band == band }
            return bandRows.isEmpty ? nil : Section(band: band, rows: bandRows)
        }
    }

    /// Search ran, and nothing survived the filters or the query — the
    /// zero-hits state: "Nothing matched '<query>'. Fewer filters? Clear".
    public var showsZeroHits: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && visibleRows.isEmpty
            && !rowsLoading
    }

    /// Nothing published at all and no search running: the empty state —
    /// "Nothing published yet. Be the first…" with the cookbook and
    /// catalog escapes.
    public var showsEmptyState: Bool {
        rows.isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The beta entry row renders only behind the flag, and only while the
    /// feed is not mid-search (the More section is browse furniture, not a
    /// search result).
    public var showsTableEntry: Bool {
        tablesEnabled && !showsZeroHits && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The zero-hits line, stating the query verbatim.
    public var zeroHitsMessage: String {
        "Nothing matched '\(query.trimmingCharacters(in: .whitespacesAndNewlines))'. Fewer filters? Clear"
    }
}
