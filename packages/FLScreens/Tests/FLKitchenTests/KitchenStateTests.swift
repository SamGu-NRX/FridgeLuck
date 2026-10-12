// FLKitchen tests — the pantry-truth rules the screen must encode.
//
// Scans observe and never add; the pills settle a scan's observations;
// counts are recomputed and cannot drift; search ends in manual entry;
// nothing is auto-expired.

import XCTest
@testable import FLKitchen

final class KitchenStateTests: XCTestCase {

    // MARK: Fixtures (synthetic copy — no real user data)

    private func state() -> KitchenViewState {
        KitchenViewState(
            useSoon: [
                .init(id: "spinach", name: "Spinach", quantityDisplay: "1 bag", ageDisplay: "2 days", state: .confirmed),
            ],
            prompts: [
                .init(itemID: "milk", itemName: "Milk, semi-skimmed", question: "Still 1 L?",
                      stillThereLabel: "Still open", goneLabel: "Gone"),
                .init(itemID: "cream", itemName: "Double cream", question: "Still 150 ml?",
                      stillThereLabel: "Confirm", goneLabel: "Gone"),
            ],
            locations: [
                .init(id: "fridge", title: "Fridge", items: [
                    .init(id: "thighs", name: "Chicken thighs", quantityDisplay: "4", ageDisplay: "today", state: .confirmed),
                    .init(id: "eggs", name: "Eggs", quantityDisplay: "6", ageDisplay: "today", state: .confirmed),
                    .init(id: "milk", name: "Milk, semi-skimmed", quantityDisplay: "1 L",
                          state: .unconfirmed, lastConfirmed: "Last confirmed 3 wk ago"),
                    .init(id: "cream", name: "Double cream", quantityDisplay: "150 ml",
                          state: .unconfirmed, lastConfirmed: "Last confirmed 2 wk ago",
                          sourceNote: "Scanned once, never confirmed"),
                ]),
                .init(id: "freezer", title: "Freezer", items: [
                    .init(id: "curry", name: "Butter bean curry", quantityDisplay: "1 portion",
                          state: .confirmed, kind: .leftover(cookedOn: "28 Sept", portions: "1 portion")),
                ]),
            ],
            assumed: .init(
                sentence: "Olive oil, salt, pepper, rice, pasta, sesame oil, honey. Recipes count these as here.",
                itemNames: ["Olive oil", "Salt", "Pepper", "Rice", "Pasta", "Sesame oil", "Honey"]
            )
        )
    }

    // MARK: The summary cannot drift from the rows

    func testSummaryCountsAreRecomputedFromRows() {
        let s = state()
        // 1 use-soon + 4 fridge + 1 freezer = 6 rows, 2 prompts.
        XCTAssertEqual(s.summary, "6 items · 2 need a look")
    }

    func testSummarySingularAndNoPromptClause() {
        var s = KitchenViewState(
            locations: [.init(id: "fridge", title: "Fridge", items: [
                .init(id: "eggs", name: "Eggs", quantityDisplay: "6", state: .confirmed),
            ])]
        )
        XCTAssertEqual(s.summary, "1 item")
        s.apply(.removeItem(itemID: "eggs"))
        XCTAssertEqual(s.summary, "0 items")
    }

    // MARK: The pills settle a scan's observation (scans observe, never add)

    func testStillThereConfirmsTheRowAndClearsItsPrompt() {
        var s = state()
        s.apply(.stillThere(itemID: "milk"))

        XCTAssertEqual(s.prompts.count, 1, "only the answered prompt clears")
        XCTAssertFalse(s.prompts.contains { $0.itemID == "milk" })

        let milk = s.allItems.first { $0.id == "milk" }
        XCTAssertEqual(milk?.state, .confirmed, "the row is confirmed")
        XCTAssertEqual(milk?.lastConfirmed, "today")
        XCTAssertNil(milk?.sourceNote, "the uncertainty note is gone")
        // The row count is unchanged — confirming observes, it does not
        // remove or add stock.
        XCTAssertEqual(s.allItems.count, 6)
    }

    func testGoneRemovesTheRowAndClearsItsPrompt() {
        var s = state()
        let before = s.allItems.count
        s.apply(.gone(itemID: "cream"))

        XCTAssertTrue(s.prompts.allSatisfy { $0.itemID != "cream" })
        XCTAssertNil(s.allItems.first { $0.id == "cream" }, "gone stock leaves the inventory view")
        XCTAssertEqual(s.allItems.count, before - 1)
        // The summary recomputes: gone settles cream's prompt; milk's
        // prompt still stands.
        XCTAssertEqual(s.summary, "5 items · 1 need a look")
    }

    func testGoneOnAUseSoonRowAlsoRemovesIt() {
        var s = state()
        s.apply(.gone(itemID: "spinach"))
        XCTAssertTrue(s.useSoon.isEmpty)
    }

    // MARK: Used up / remove (swipes)

    func testUsedUpRemovesTheRow() {
        var s = state()
        s.apply(.useItem(itemID: "thighs"))
        XCTAssertNil(s.allItems.first { $0.id == "thighs" })
    }

    func testRemoveAlsoDropsAnyPromptForThatItem() {
        var s = state()
        s.apply(.removeItem(itemID: "milk"))
        XCTAssertTrue(s.prompts.allSatisfy { $0.itemID != "milk" })
        XCTAssertNil(s.allItems.first { $0.id == "milk" })
    }

    // MARK: Search ends in manual entry, never a dead end

    func testSearchFiltersAcrossAllSections() {
        var s = state()
        s.apply(.search("chi"))
        // "Chicken thighs" matches; so does "Chickpeas" if present (it is not).
        guard case .active(let query, let ids) = s.search else { return XCTFail("expected active search") }
        XCTAssertEqual(query, "chi")
        XCTAssertEqual(Set(ids), ["thighs"])
    }

    func testSearchIsCaseInsensitiveAndWhitespaceTrimmed() {
        var s = state()
        s.apply(.search("  EGGS  "))
        XCTAssertEqual(s.searchMatchingItemIDs, ["eggs"])
    }

    func testSearchWithNoMatchesOffersAddByName() {
        var s = state()
        s.apply(.search("tahini"))
        guard case .noMatches(let query) = s.search else { return XCTFail("expected no-matches phase") }
        XCTAssertEqual(query, "tahini", "the view offers Add 'tahini' as the last result")
    }

    func testEmptyQueryExitsSearch() {
        var s = state()
        s.apply(.search("eggs"))
        s.apply(.search(""))
        XCTAssertEqual(s.search, .inactive)
    }

    // MARK: Staleness — nothing is auto-expired

    func testScanRequestKeepsTheStaleNoticeUntilAReconciliationSettles() {
        // FIX: a scan that is merely REQUESTED must not clear the
        // warning — a cancelled or failed scan would otherwise leave the
        // notice falsely gone. `.scanNow` is host-routed; the notice
        // clears when a reconciliation settles (Still there / Gone).
        var s = state()
        s.stale = .init(line: "Last scan 9 days ago. Tonight's picks may be off.")
        s.apply(.scanNow)
        XCTAssertEqual(
            s.stale?.line, "Last scan 9 days ago. Tonight's picks may be off.",
            "a requested scan is not a successful reconciliation"
        )
        XCTAssertEqual(s.allItems.count, 6, "the request never touches rows")
    }

    func testSettledReconciliationClearsTheStaleNotice() {
        // Still-there and gone answers are the settled observations: the
        // warning is answered by what the scan saw.
        var still = state()
        still.stale = .init(line: "Last scan 9 days ago. Tonight's picks may be off.")
        still.apply(.stillThere(itemID: "eggs"))
        XCTAssertNil(still.stale)

        var gone = state()
        gone.stale = .init(line: "Last scan 9 days ago. Tonight's picks may be off.")
        gone.apply(.gone(itemID: "eggs"))
        XCTAssertNil(gone.stale)
        XCTAssertNil(gone.allItems.first { $0.id == "eggs" }, "the gone answer still removes the row")
    }

    // MARK: Host-routed intents are identity

    func testHostRoutedIntentsAreIdentity() {
        let base = state()
        let identity: [KitchenIntent] = [
            .scanGroceries, .addByName, .newGroceries, .scanShelf, .scanNow,
            .openItem(itemID: "eggs"), .editItem(itemID: "eggs"),
            .adjustQuantity(itemID: "eggs", delta: 1), .changeAssumedStaples,
        ]
        for intent in identity {
            XCTAssertEqual(KitchenReducer.reduced(base, by: intent), base, "\(intent) is host-routed")
        }
    }

    // MARK: Adding stock — the reducer never adds

    func testNoIntentAddsStockRows() {
        // The add paths are host-routed; assert the reducer's add-shaped
        // intents leave the row set untouched (scans observe; purchases
        // add through the host's ledger, then arrive as new state).
        var s = state()
        let before = s.allItems.count
        s.apply(.scanGroceries)
        s.apply(.addByName)
        s.apply(.newGroceries)
        XCTAssertEqual(s.allItems.count, before)
    }

    // MARK: Assumed staples are a sentence, not rows

    func testAssumedStaplesAreNotCountedAsItems() {
        let s = state()
        XCTAssertEqual(s.assumed?.itemNames.count, 7)
        XCTAssertFalse(
            s.allItems.contains { $0.state == .assumedStaple },
            "assumed staples never appear as inventory rows"
        )
    }
}
