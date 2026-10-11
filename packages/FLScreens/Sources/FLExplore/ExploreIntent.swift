// FLExplore — typed intents and the reducer.
//
// Same split as Part 2's screens:
//
// - Presentation-logic intents: the reducer applies them here (filter
//   toggling, search text, clearing filters, withdrawing a row in
//   review) so the rules are Linux-testable.
// - Navigation/effect intents: routed to the host through the view's
//   send closure; the reducer returns state unchanged for them, because
//   the outcome (a pushed recipe, the publish flow, the table) arrives
//   as new state from the host, not from this layer.
//
// Ranking is the host's job — no intent recomputes a rank here. Rejections
// and taste data do not exist on this screen at all.

import Foundation

/// Everything the Explore screen can send.
public enum ExploreIntent: Equatable, Sendable {

    // Presentation logic (reducer-owned)

    /// A filter chip was tapped. Toggling is the screen's bookkeeping; the
    /// re-ranked feed arrives as new rows from the host.
    case toggleFilter(ExploreViewState.Filter)
    /// Search typing. An empty query exits search. Zero hits never blank
    /// the page — `showsZeroHits` derives the escape line.
    case search(String)
    /// "Clear" from the zero-hits line: the filters loosen, the query
    /// stands (the user asked for 'tahini'; the filters were the straw).
    case clearFilters

    // Navigation / effects (host-routed; reducer is identity)

    /// A recipe row — pushes the Recipe screen.
    case openRecipe(recipeID: String)
    /// "Publish yours": publishing is a previewed, separate action with a
    /// rights declaration.
    case openPublish
    /// The Community-tables beta entry row. Only rendered behind the flag.
    case openTable
    /// The empty state's escapes.
    case openCookbook
    case openCatalogSearch
    /// "Withdraw" on a row still in moderation review. The host commits
    /// the withdrawal; the reducer drops the row from the feed.
    case withdraw(recipeID: String)
    /// Scan entry — the search-role tab's fallback so scan stays reachable.
    case scanKitchen
}

/// The reducer: pure, total over intents. `ExploreViewState.apply(_:)` is
/// the convenience views use.
public enum ExploreReducer {

    public static func reduced(_ state: ExploreViewState, by intent: ExploreIntent) -> ExploreViewState {
        var next = state
        switch intent {

        case .toggleFilter(let filter):
            if next.activeFilters.contains(filter) {
                next.activeFilters.remove(filter)
            } else {
                next.activeFilters.insert(filter)
            }

        case .search(let query):
            next.query = query

        case .clearFilters:
            next.activeFilters.removeAll()

        case .withdraw(let recipeID):
            next.rows.removeAll { $0.id == recipeID }

        // Navigation and effects: the host owns the outcome.
        case .openRecipe, .openPublish, .openTable, .openCookbook,
             .openCatalogSearch, .scanKitchen:
            break
        }
        return next
    }
}

extension ExploreViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: ExploreIntent) {
        self = ExploreReducer.reduced(self, by: intent)
    }
}
