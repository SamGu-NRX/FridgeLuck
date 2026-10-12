// FLKitchen — Kitchen's view state.
//
// "What do I actually have?" The binding rules this state encodes
// (SPEC 3.2 + Direction H's Kitchen state notes):
//
// - Scans observe; purchases add. A shelf scan reconciles what it saw and
//   nothing else — reconciliation prompts ask "Still N?" and the answer is
//   the Still there / Gone pill pair. Only a receipt, "New groceries" or
//   manual entry adds stock.
// - Nothing is auto-expired. Uncertainty becomes a "Needs a look" row, not
//   a silent write-off.
// - Manual entry is first-class; when the kitchen is unknown, Scan
//   groceries and Add by name rank equal.
// - Every item carries its last confirmation and source.
// - Leftovers are inventory: a row named after the dish with its date.
//
// Foundation-only, Sendable, Equatable: Linux-tested in FLKitchenTests.

/// The whole Kitchen screen as a value.
public struct KitchenViewState: Equatable, Sendable {

    /// Row state, shape-first: filled square = confirmed, dashed =
    /// unconfirmed, grey ring = assumed staple (always captioned).
    public enum ItemState: String, Equatable, Sendable {
        case confirmed
        case unconfirmed
        case assumedStaple
    }

    /// One pantry row.
    public struct Item: Equatable, Sendable {

        /// Groceries are stock; leftovers are a cooked meal saved as
        /// portions (named after the dish, with its date).
        public enum Kind: Equatable, Sendable {
            case grocery
            case leftover(cookedOn: String, portions: String)
        }

        public var id: String
        public var name: String
        public var quantityDisplay: String
        /// Age or use-by display, right-aligned in mono ("today", "4 d", "3 wk").
        public var ageDisplay: String?
        public var state: ItemState
        /// "Last confirmed 3 wk ago" — every item carries its evidence.
        public var lastConfirmed: String?
        /// "Scanned once, never confirmed" — where the row's truth came from.
        public var sourceNote: String?
        public var kind: Kind

        public init(
            id: String, name: String, quantityDisplay: String, ageDisplay: String? = nil,
            state: ItemState, lastConfirmed: String? = nil, sourceNote: String? = nil,
            kind: Kind = .grocery
        ) {
            self.id = id
            self.name = name
            self.quantityDisplay = quantityDisplay
            self.ageDisplay = ageDisplay
            self.state = state
            self.lastConfirmed = lastConfirmed
            self.sourceNote = sourceNote
            self.kind = kind
        }
    }

    /// A reconciliation the scan observed and the user must settle. The
    /// pills carry the warm surface fills: the still-there pill rides
    /// `pillIdle`, the gone pill rides `pillGone` (FLDesignTokens).
    public struct ReconcilePrompt: Equatable, Sendable {
        public var itemID: String
        public var itemName: String
        /// The observed question, stated with the quantity: "Still 2 lemons?"
        public var question: String
        /// The confirming answer's label ("Still there", "Still open", "Confirm").
        public var stillThereLabel: String
        /// The negating answer's label ("Gone").
        public var goneLabel: String

        public init(
            itemID: String, itemName: String, question: String,
            stillThereLabel: String, goneLabel: String
        ) {
            self.itemID = itemID
            self.itemName = itemName
            self.question = question
            self.stillThereLabel = stillThereLabel
            self.goneLabel = goneLabel
        }
    }

    /// A location section ("Fridge", "Freezer", "Pantry").
    public struct LocationSection: Equatable, Sendable {
        public var id: String
        public var title: String
        public var items: [Item]

        public init(id: String, title: String, items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    /// Assumed staples are a sentence, not a list — a policy, not inventory.
    public struct AssumedStaples: Equatable, Sendable {
        public var sentence: String
        public var itemNames: [String]

        public init(sentence: String, itemNames: [String]) {
            self.sentence = sentence
            self.itemNames = itemNames
        }
    }

    /// The last-scan staleness notice. Nothing is auto-expired: the notice
    /// is a row the user can act on ("Scan now"), never a silent write-off.
    public struct StaleNotice: Equatable, Sendable {
        public var line: String

        public init(line: String) {
            self.line = line
        }
    }

    /// Search: the inline field replaces the title; sections collapse to
    /// matching rows; when nothing matches, "Add '<query>'" is the last
    /// result — search ends in manual entry, never a dead end.
    public enum SearchPhase: Equatable, Sendable {
        case inactive
        case active(query: String, matchingItemIDs: [String])
        case noMatches(query: String)

        public var isActive: Bool {
            switch self {
            case .inactive: return false
            case .active, .noMatches: return true
            }
        }
    }

    // MARK: State

    /// "Use soon" rows, each tag a word ("2 days", "tomorrow", "today") —
    /// the warning is an action.
    public var useSoon: [Item]
    /// "Needs a look" rows with their reconciliation prompts.
    public var prompts: [ReconcilePrompt]
    /// Location sections in decision order, after Use soon and Needs a look.
    public var locations: [LocationSection]
    public var assumed: AssumedStaples?
    public var stale: StaleNotice?
    /// A failed backup is one line at the bottom, never a modal.
    public var backupNote: String?
    public var search: SearchPhase
    /// True when the kitchen has no content at all (never scanned): the
    /// hero copy replaces the sections and the two entry actions rank equal.
    public var isEmptyKitchen: Bool

    public init(
        useSoon: [Item] = [],
        prompts: [ReconcilePrompt] = [],
        locations: [LocationSection] = [],
        assumed: AssumedStaples? = nil,
        stale: StaleNotice? = nil,
        backupNote: String? = nil,
        search: SearchPhase = .inactive,
        isEmptyKitchen: Bool = false
    ) {
        self.useSoon = useSoon
        self.prompts = prompts
        self.locations = locations
        self.assumed = assumed
        self.stale = stale
        self.backupNote = backupNote
        self.search = search
        self.isEmptyKitchen = isEmptyKitchen
    }

    // MARK: Derived counts (always recomputed, never stored — they cannot
    // drift from the rows)

    /// Every grocery row on the screen, in section order.
    public var allItems: [Item] {
        useSoon + locations.flatMap(\.items)
    }

    /// "58 items · 3 need a look".
    public var summary: String {
        let itemCount = allItems.count
        let needsLook = prompts.count
        var parts = ["\(itemCount) item\(itemCount == 1 ? "" : "s")"]
        if needsLook > 0 {
            parts.append("\(needsLook) need a look")
        }
        return parts.joined(separator: " · ")
    }

    /// Rows matching the active search, across all sections including
    /// use-soon.
    public var searchMatchingItemIDs: [String] {
        switch search {
        case .inactive: return []
        case .noMatches: return []
        case .active(_, let ids): return ids
        }
    }
}
