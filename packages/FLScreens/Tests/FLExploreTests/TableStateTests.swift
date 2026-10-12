// FLExplore tests — the Table screen's binding rules, as tests.
//
// The unit is a COOK, cards in time order with no ranking, the viewer's
// own fit meter and one button per card (none on their own cook), no
// likes/comments/followers (no fields), the share preview that freezes
// exactly the shareable fields, and the phases' honesty. Fixtures are
// synthetic.

import XCTest
@testable import FLExplore
@testable import FLScreenSupport

final class TableStateTests: XCTestCase {

    // MARK: Fixtures (synthetic copy — no real user data)

    private func cook(
        id: String = "c-1", name: String = "Maya", own: Bool = false,
        when: TableCookedDay = .monday, servings: Int = 2, dish: String = "Ginger noodles",
        note: String? = nil, rating: String? = "5 of 5", detail: String? = nil,
        photo: String? = nil, have: Int = 10, total: Int = 10, swaps: Int = 0,
        shortfallNames: [String] = [], covered: [String] = [],
        swapList: [TableViewState.Swap] = []
    ) -> TableViewState.Cook {
        TableViewState.Cook(
            id: id, cookName: name, isOwn: own, when: when,
            servings: servings, recipeID: "r-1",
            recipeRevisionKey: "prawn-linguine-v4", dishTitle: dish, note: note,
            ratingDisplay: rating, detailDisplay: detail, photoCaption: photo,
            swaps: swapList,
            fit: FLFitSummary(
                have: have, total: total, swapsNeeded: swaps,
                shortfallNames: shortfallNames, swapCoveredNames: covered)
        )
    }

    private func state(
        cooks: [TableViewState.Cook], memberCount: Int = 3,
        notes: [TableViewState.NoteRow] = [], asOf: String? = nil,
        phase: TableViewState.Phase = .active
    ) -> TableViewState {
        TableViewState(
            phase: phase, tableName: "Flat 4B", memberCount: memberCount,
            cooks: cooks, notes: notes, asOf: asOf
        )
    }

    // MARK: The one button per card

    func testOwnCookHasNoButton() {
        XCTAssertNil(cook(own: true).buttonTitle)
    }

    func testCompleteFitOffersCookTonightAsPrimary() {
        let card = cook()
        XCTAssertEqual(card.buttonTitle, "Cook tonight")
        XCTAssertTrue(card.buttonIsPrimary)
    }

    func testValidatedSwapCoverageOffersCookWithSwapQuietly() {
        let card = cook(have: 9, total: 10, swaps: 1,
                        shortfallNames: ["eggs"], covered: ["eggs"])
        XCTAssertEqual(card.buttonTitle, "Cook with swap")
        XCTAssertFalse(card.buttonIsPrimary)
    }

    func testBareSwapCountNeverPromisesACookWithSwap() {
        // A positive swap count that covers no named shortfall promises
        // nothing: "Open recipe" states what the kitchen can do today.
        let card = cook(have: 7, total: 10, swaps: 1,
                        shortfallNames: ["eggs", "oil", "butter"])
        XCTAssertEqual(card.buttonTitle, "Open recipe")
        XCTAssertFalse(card.buttonIsPrimary)
    }

    func testRealShortfallNeverPromisesACook() {
        let card = cook(have: 2, total: 10)
        XCTAssertEqual(card.buttonTitle, "Open recipe")
        XCTAssertFalse(card.buttonIsPrimary)
    }

    // MARK: Time order, no ranking

    func testCardsPreserveHostOrderThroughUnrelatedIntents() {
        var state = state(cooks: [
            cook(id: "later"), cook(id: "earlier"),
        ])
        state.apply(.showSharePreview(cookID: "later"))
        state.apply(.dismissSharePreview)
        XCTAssertEqual(state.cooks.map { $0.id }, ["later", "earlier"])
    }

    // MARK: The share preview — exactly what leaves the phone

    func testSharePreviewFreezesOnlyTheRecordedFields() {
        var state = state(cooks: [
            cook(id: "c-1", servings: 2, note: "Worked at 2 servings",
                 rating: "5 of 5", detail: "18 min",
                 swapList: [TableViewState.Swap(replaces: "spinach", with: "kale")]),
        ])
        state.apply(.showSharePreview(cookID: "c-1"))
        let preview = state.sharePreview
        XCTAssertEqual(preview?.recipeDisplay, "Ginger noodles")
        XCTAssertEqual(preview?.servingsDisplay, "for 2")
        // Swaps come from the TYPED list: the card's detail line ("18
        // min", a duration) never masquerades as a substitution.
        XCTAssertEqual(preview?.swapsDisplay, "swapped spinach for kale")
        XCTAssertEqual(preview?.ratingDisplay, "5 of 5")
        XCTAssertEqual(preview?.noteDisplay, "Worked at 2 servings")
        // The privacy contract is the struct's shape: SharePreview has no
        // field for pantry, health, taste data, or exact times — enforced
        // by the Part 3 raw-source lint.
    }

    func testSharePreviewFromAMinimalCookCarriesOnlyWhatWasRecorded() {
        var state = state(cooks: [cook(id: "c-2", note: nil, rating: nil, detail: nil)])
        state.apply(.showSharePreview(cookID: "c-2"))
        XCTAssertEqual(state.sharePreview?.servingsDisplay, "for 2")
        XCTAssertNil(state.sharePreview?.swapsDisplay)
        XCTAssertNil(state.sharePreview?.ratingDisplay)
        XCTAssertNil(state.sharePreview?.noteDisplay)
    }

    func testSharePreviewCarriesRevisionIdentityAndTheDayOnlyWhen() {
        var state = state(cooks: [cook(id: "c-1", when: .thursday)])
        state.apply(.showSharePreview(cookID: "c-1"))
        // The revision key travels with the dish title, and the cook day
        // is the typed day-only value — no exact time can hide in it.
        XCTAssertEqual(state.sharePreview?.revisionDisplay, "prawn-linguine-v4")
        XCTAssertEqual(state.sharePreview?.when, .thursday)
        XCTAssertEqual(state.sharePreview?.when.display, "Thu")
    }

    func testSharePreviewForAnUnknownCookOpensNothing() {
        var state = state(cooks: [cook(id: "c-1")])
        state.apply(.showSharePreview(cookID: "ghost"))
        XCTAssertNil(state.sharePreview)
    }

    func testDismissSharePreview() {
        var state = state(cooks: [cook()])
        state.apply(.showSharePreview(cookID: "c-1"))
        XCTAssertNotNil(state.sharePreview)
        state.apply(.dismissSharePreview)
        XCTAssertNil(state.sharePreview)
    }

    // MARK: Header and phases

    func testSubtitleCarriesTheNoRankingPromise() {
        let subtitle = state(cooks: [cook()]).subtitleDisplay
        XCTAssertEqual(subtitle, "Flat 4B · 3 people · in time order, no ranking")
    }

    func testAloneViewerSeesTheInviteRow() {
        XCTAssertTrue(state(cooks: [], memberCount: 1).viewerIsAlone)
        XCTAssertFalse(state(cooks: [cook(), cook()], memberCount: 3).viewerIsAlone)
    }

    func testNotesHideOfflineButCardsStay() {
        let offline = state(cooks: [cook()], asOf: "As of 18:40")
        XCTAssertFalse(offline.showsNotes)
        XCTAssertEqual(offline.cooks.count, 1)
        XCTAssertTrue(state(cooks: [cook()]).showsNotes)
    }

    func testNotesHideOnFetchFailureToo() {
        let failed = state(cooks: [], phase: .fetchFailed)
        XCTAssertFalse(failed.showsNotes)
    }

    // MARK: Notes rows — the ten-cook rule again

    func testCookCountsFollowTheTenRule() {
        XCTAssertEqual(
            TableViewState.NoteRow(id: "n", dish: "d", noteLine: "x", cookCount: 212).cooksDisplay,
            "212 cooks")
        XCTAssertEqual(
            TableViewState.NoteRow(id: "n", dish: "d", noteLine: "x", cookCount: 9).cooksDisplay,
            "under 10")
        XCTAssertNil(TableViewState.NoteRow(id: "n", dish: "d", noteLine: "x").cooksDisplay)
    }

    // MARK: Card rate line

    func testRateDisplayJoinsOnlyRecordedParts() {
        XCTAssertEqual(cook(rating: "5 of 5", detail: "18 min").rateDisplay, "5 of 5 · 18 min")
        XCTAssertEqual(cook(rating: nil, detail: "18 min").rateDisplay, "18 min")
        XCTAssertNil(cook(rating: nil, detail: nil).rateDisplay)
    }

    // MARK: Reducer — effects stay host-side

    func testNavigationIntentsLeaveStateUntouched() {
        var state = state(cooks: [cook()])
        let before = state
        let frozen = TableViewState.SharePreview(
            cookID: "c-1", recipeDisplay: "Ginger noodles",
            revisionDisplay: "prawn-linguine-v4", when: .monday,
            servingsDisplay: "for 2")
        let effects: [TableIntent] = [
            .invite, .startTable, .joinWithCode, .cookTonight(cookID: "c-1"),
            .openRecipe(recipeID: "r-1"), .confirmShare(frozen),
            .joinChallenge, .retryFetch, .leaveTable,
        ]
        for intent in effects {
            state.apply(intent)
            XCTAssertEqual(state, before, "host effects must not mutate state: \(intent)")
        }
    }
}
