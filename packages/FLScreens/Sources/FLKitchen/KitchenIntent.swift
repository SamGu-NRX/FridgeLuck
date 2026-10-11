// FLKitchen — typed intents and the reducer.
//
// The reducer owns the observable presentation transitions: prompt
// resolution, row removal, count recomputation, search filtering, notice
// clearing. Ledger arithmetic (quantities, rates, dates) is the host's —
// where an intent's real effect is a stock change, the reducer removes or
// marks the row and the host commits the ledger event.

import Foundation

/// Everything the Kitchen screen can send.
public enum KitchenIntent: Equatable, Sendable {

    // Reconciliation (scans observe — these settle what a scan saw)

    /// The still-there pill: the observed stock stands; the row is
    /// confirmed.
    case stillThere(itemID: String)
    /// The gone pill: the observed stock is not there; the row leaves the
    /// inventory view (the host reconciles the ledger to zero).
    case gone(itemID: String)

    // Adding stock (purchases add; scans never do)

    /// "Scan groceries" — the receipt path; the only flow that adds stock
    /// by scanning.
    case scanGroceries
    /// "Add by name" — manual entry, first-class everywhere.
    case addByName
    /// "New groceries" after a shop: host presents the receipt/entry flow.
    case newGroceries

    // Navigation and maintenance

    case scanShelf
    /// "Scan now" from the staleness notice.
    case scanNow
    case openItem(itemID: String)
    case editItem(itemID: String)
    /// Swipe right ("Used up"): deducts and teaches the app the real rate.
    case useItem(itemID: String)
    /// Swipe left: remove.
    case removeItem(itemID: String)
    /// The stepper in the row's edit state; the host applies the real
    /// quantity math and returns updated state.
    case adjustQuantity(itemID: String, delta: Int)
    case changeAssumedStaples
    /// Search typing. An empty query exits search.
    case search(String)
}

/// The reducer: pure, total over intents. `KitchenViewState.apply(_:)` is
/// the convenience views use.
public enum KitchenReducer {

    public static func reduced(_ state: KitchenViewState, by intent: KitchenIntent) -> KitchenViewState {
        var next = state
        switch intent {

        case .stillThere(let itemID):
            next.prompts.removeAll { $0.itemID == itemID }
            next.markConfirmed(itemID: itemID)

        case .gone(let itemID):
            next.prompts.removeAll { $0.itemID == itemID }
            next.removeItem(itemID: itemID)

        case .useItem(let itemID):
            next.removeItem(itemID: itemID)

        case .removeItem(let itemID):
            next.removeItem(itemID: itemID)
            next.prompts.removeAll { $0.itemID == itemID }

        case .search(let query):
            next.search = Self.searchPhase(for: query, in: next)

        case .scanNow:
            next.stale = nil

        // Host-routed outcomes: new state arrives from the host.
        case .scanGroceries, .addByName, .newGroceries, .scanShelf,
             .openItem, .editItem, .adjustQuantity, .changeAssumedStaples:
            break
        }
        return next
    }

    private static func searchPhase(
        for query: String, in state: KitchenViewState
    ) -> KitchenViewState.SearchPhase {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .inactive }
        let lowered = trimmed.lowercased()
        let matches = state.allItems
            .filter { $0.name.lowercased().contains(lowered) }
            .map(\.id)
        return matches.isEmpty
            ? .noMatches(query: trimmed)
            : .active(query: trimmed, matchingItemIDs: matches)
    }
}

private extension KitchenViewState {

    mutating func markConfirmed(itemID: String) {
        func confirm(_ item: inout Item) {
            if item.id == itemID {
                item.state = .confirmed
                item.lastConfirmed = "today"
                item.sourceNote = nil
            }
        }
        for index in useSoon.indices { confirm(&useSoon[index]) }
        for sectionIndex in locations.indices {
            for itemIndex in locations[sectionIndex].items.indices {
                confirm(&locations[sectionIndex].items[itemIndex])
            }
        }
    }

    mutating func removeItem(itemID: String) {
        useSoon.removeAll { $0.id == itemID }
        for sectionIndex in locations.indices {
            locations[sectionIndex].items.removeAll { $0.id == itemID }
        }
    }
}

extension KitchenViewState {

    /// The views' dispatch convenience: `state.apply(intent)`.
    public mutating func apply(_ intent: KitchenIntent) {
        self = KitchenReducer.reduced(self, by: intent)
    }
}
