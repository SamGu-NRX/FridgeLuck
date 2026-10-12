// FLExplore tests — Explore's binding rules, as tests.
//
// The ten-cook social-proof rule, fit-derived rank bands, filter and
// search logic, the zero-hits escape, the review/withdraw loop, and the
// beta gate that keeps Table inside Explore. Fixtures are synthetic.

import XCTest
@testable import FLExplore
@testable import FLScreenSupport

final class ExploreStateTests: XCTestCase {

    // MARK: Fixtures (synthetic copy — no real user data)

    private func row(
        id: String = "r-1", title: String = "Ginger chicken udon noodles",
        publisher: String = "Maya", distinctCooks: Int? = nil, minutes: Int = 35,
        have: Int = 10, total: Int = 10, swaps: Int = 0,
        names: [String] = [], vegetarian: Bool = false,
        draft: Bool = false, pendingReview: Bool = false
    ) -> ExploreViewState.Row {
        ExploreViewState.Row(
            id: id, title: title, publisherDisplay: publisher,
            distinctCooks: distinctCooks, minutes: minutes,
            fit: FLFitSummary(have: have, total: total, swapsNeeded: swaps, shortfallNames: names),
            isVegetarian: vegetarian, isLeChefDraft: draft, isPendingReview: pendingReview
        )
    }

    // MARK: Social proof — the ten-cook rule

    func testTenOrMoreDistinctCooksShowTheCount() {
        XCTAssertEqual(row(distinctCooks: 37).socialDisplay, "cooked by 37 people")
        XCTAssertEqual(row(distinctCooks: 10).socialDisplay, "cooked by 10 people")
    }

    func testUnderTenCooksInvitesInsteadOfCounting() {
        XCTAssertEqual(row(distinctCooks: 3).socialDisplay, "Be the first to cook this")
    }

    func testNoOptedInDataSaysNothing() {
        XCTAssertNil(row(distinctCooks: nil).socialDisplay)
        XCTAssertFalse(row(distinctCooks: nil).captionDisplay.contains("cooked by"))
    }

    func testPendingReviewOutranksSocialProof() {
        let pending = row(distinctCooks: 37, pendingReview: true)
        XCTAssertEqual(pending.captionDisplay, "In review — only you can see it")
    }

    // MARK: Rank bands

    func testCompleteRowsRankAsCanCookNow() {
        XCTAssertEqual(row().band, .canCookNow)
    }

    func testSwapCoveredShortfallsRankOneSwapAway() {
        XCTAssertEqual(
            row(have: 9, total: 10, swaps: 1, names: ["eggs"]).band, .oneSwapAway)
    }

    func testRealShortfallsLandInMoreToCookRatherThanVanishing() {
        XCTAssertEqual(row(have: 2, total: 10).band, .moreToCook)
        let state = ExploreViewState(rows: [row(have: 2, total: 10)])
        XCTAssertTrue(state.sections.contains { $0.band == .moreToCook })
    }

    func testLeChefDraftsHoldTheirOwnSectionWhateverTheFit() {
        XCTAssertEqual(
            row(have: 10, total: 10, draft: true).band, .madeForYourFridge)
    }

    func testSectionsInRankOrderWithEmptyBandsOmitted() {
        let state = ExploreViewState(rows: [
            row(id: "draft", draft: true),
            row(id: "now"),
            row(id: "swap", have: 9, total: 10, swaps: 1, names: ["eggs"]),
        ])
        XCTAssertEqual(state.sections.map { $0.band }, [.madeForYourFridge, .canCookNow, .oneSwapAway])
    }

    // MARK: Filters

    func testUnderThirtyIsStrictlyUnder() {
        XCTAssertFalse(ExploreViewState.Filter.underThirtyMinutes.accepts(row(minutes: 30)))
        XCTAssertTrue(ExploreViewState.Filter.underThirtyMinutes.accepts(row(minutes: 29)))
    }

    func testCanCookNowRequiresACompleteFit() {
        XCTAssertTrue(ExploreViewState.Filter.canCookNow.accepts(row()))
        XCTAssertFalse(ExploreViewState.Filter.canCookNow.accepts(row(have: 9, total: 10, swaps: 1, names: ["eggs"])))
    }

    func testFiltersComposeAndToggleOff() {
        var state = ExploreViewState(rows: [
            row(id: "veg-fast", minutes: 20, vegetarian: true),
            row(id: "meat-slow", minutes: 45),
        ], activeFilters: [.vegetarian, .underThirtyMinutes])
        XCTAssertEqual(state.visibleRows.map { $0.id }, ["veg-fast"])
        state.apply(.toggleFilter(.underThirtyMinutes))
        // Vegetarian alone still excludes the slow meat dish.
        XCTAssertEqual(state.visibleRows.map { $0.id }, ["veg-fast"])
        state.apply(.toggleFilter(.vegetarian))
        XCTAssertEqual(Set(state.visibleRows.map { $0.id }), Set(["veg-fast", "meat-slow"]))
    }

    // MARK: Search

    func testSearchMatchesTitleOrPublisherCaseInsensitively() {
        let state = ExploreViewState(rows: [
            row(id: "a", title: "Ginger chicken udon noodles"),
            row(id: "b", title: "Roast tomato soup", publisher: "Tomato Tom"),
        ], query: "GINger")
        XCTAssertEqual(state.visibleRows.map { $0.id }, ["a"])
        let byPublisher = ExploreViewState(rows: [
            row(id: "a", title: "Ginger chicken udon noodles"),
            row(id: "b", title: "Roast tomato soup", publisher: "Tomato Tom"),
        ], query: "tomato")
        XCTAssertEqual(byPublisher.visibleRows.map { $0.id }, ["b"])
    }

    // MARK: Zero hits and empty states

    func testZeroHitsStateTheQueryAndNeverBlankThePage() {
        var state = ExploreViewState(rows: [row()], query: "tahini")
        state.apply(.search("tahini"))
        XCTAssertTrue(state.showsZeroHits)
        XCTAssertEqual(state.zeroHitsMessage, "Nothing matched 'tahini'. Fewer filters? Clear")
    }

    func testClearingFiltersKeepsTheQuery() {
        var state = ExploreViewState(rows: [row(id: "meat", minutes: 45)])
        state.apply(.search("noodles"))
        XCTAssertFalse(state.showsZeroHits)
        state.apply(.toggleFilter(.vegetarian)) // the meat row fails the filter — zero hits
        XCTAssertTrue(state.showsZeroHits)
        state.apply(.clearFilters)
        XCTAssertFalse(state.showsZeroHits)
        XCTAssertEqual(state.query, "noodles", "clearing filters keeps the query")
        XCTAssertEqual(state.visibleRows.map { $0.id }, ["meat"])
    }

    func testEmptyStateOnlyWithoutASearch() {
        XCTAssertTrue(ExploreViewState().showsEmptyState)
        var state = ExploreViewState()
        state.apply(.search("tahini"))
        XCTAssertFalse(state.showsEmptyState)
        XCTAssertTrue(state.showsZeroHits)
    }

    // MARK: The beta gate — Table inside Explore

    func testTableEntryRendersOnlyBehindTheFlag() {
        var state = ExploreViewState(rows: [row()])
        XCTAssertFalse(state.showsTableEntry)
        state.tablesEnabled = true
        XCTAssertTrue(state.showsTableEntry)
    }

    func testTableEntryHidesDuringSearch() {
        var state = ExploreViewState(rows: [row()], tablesEnabled: true)
        state.apply(.search("tahini"))
        XCTAssertFalse(state.showsTableEntry)
    }

    // MARK: Reducer — presentation logic vs host effects

    func testNavigationIntentsLeaveStateUntouched() {
        var state = ExploreViewState(rows: [row()], tablesEnabled: true)
        let before = state
        let navigation: [ExploreIntent] = [
            .openRecipe(recipeID: "r-1"), .openPublish, .openTable,
            .openCookbook, .openCatalogSearch, .scanKitchen,
        ]
        for intent in navigation {
            state.apply(intent)
            XCTAssertEqual(state, before, "navigation must not mutate state: \(intent)")
        }
    }

    func testWithdrawRemovesThePendingRow() {
        var state = ExploreViewState(rows: [
            row(id: "mine", pendingReview: true), row(id: "other"),
        ])
        state.apply(.withdraw(recipeID: "mine"))
        XCTAssertEqual(state.rows.map { $0.id }, ["other"])
    }

    func testSearchTrimsBeforeDeriving() {
        var state = ExploreViewState(rows: [row()])
        state.apply(.search("   ginger   "))
        XCTAssertFalse(state.showsZeroHits)
        XCTAssertEqual(state.visibleRows.count, 1)
    }
}
