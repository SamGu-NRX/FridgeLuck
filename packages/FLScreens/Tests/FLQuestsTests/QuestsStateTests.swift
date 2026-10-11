// FLQuestsTests — the weekly quests CANDIDATE, Linux-tested.
//
// The state layer is Foundation-only, so every observable behaviour is
// tested here on Linux: the candidate flag's gating (a flag-off screen
// renders nothing and joins nothing), host-ordered quest and counter
// arrivals, offline join queuing with the reconnect receipt, leave's
// quietness, the saved-food display grammar shared with Progress, and
// the share preview — the only path to a QuestSharePayload, projected
// from the host's cook record through the SPEC §3.4 allowlist.
//
// The SwiftUI views are Apple-gated and unverified on Linux by design
// (UNVERIFIED-NATIVE); the raw-source lint (Part6RawSourceLintTests)
// pins their conventions.

import XCTest
@testable import FLQuests

final class QuestsStateTests: XCTestCase {

    private var sampleQuests: [QuestsViewState.Quest] {
        [
            QuestsViewState.Quest(
                id: "cook-2", title: "Cook twice this week",
                brief: "Any recipe, any day.",
                rulesLine: "Works alone · any method · ends Sunday",
                cooksDisplay: "14 cooking",
                rewardChip: "under 30 min"),
            QuestsViewState.Quest(
                id: "swap-1", title: "One substitution",
                rulesLine: "Any recipe, any day.",
                cooksDisplay: "9 cooking"),
        ]
    }

    private var sampleRecord: QuestCookRecord {
        QuestCookRecord(
            revisionId: "r-88", servings: 2, swapsUsed: 1, rating: 5,
            noteLine: "Fed two, no leftovers.")
    }

    // MARK: The candidate ships off

    func testTheCandidateShipsOffAndJoinsNothing() {
        var state = QuestsViewState()
        XCTAssertFalse(state.enabled, "the candidate flag ships OFF")
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.showsEmpty)

        // Host arrivals still land in the value (the state renders what
        // it holds — the same philosophy as Explore's feed), but the
        // screen stays dark and guarded intents do nothing.
        state.apply(.questsArrived(sampleQuests))
        XCTAssertFalse(state.isActive, "a flag-off candidate renders nothing")
        state.apply(.join(id: "cook-2"))
        XCTAssertFalse(state.quests[0].isJoined, "a flag-off candidate joins nothing")
        XCTAssertTrue(state.joinReceipt == nil && state.pendingJoinIds.isEmpty)
        state.apply(.shareResult(id: "cook-2", record: sampleRecord))
        XCTAssertNil(state.sharePreview, "no payload path exists while the flag is off")
    }

    func testFlagOnWithNoQuestsShowsTheEmptyState() {
        let state = QuestsViewState(enabled: true)
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.showsEmpty, "enabled and empty is the empty state")
    }

    func testFlagOnWithQuestsIsNotEmpty() {
        let state = QuestsViewState(enabled: true, quests: sampleQuests)
        XCTAssertFalse(state.showsEmpty)
        // The featured quest is the host's first; the rest are "Also
        // this week". Order is the host's statement, not a ranking.
        XCTAssertEqual(state.featuredQuest?.id, "cook-2")
        XCTAssertEqual(state.alsoQuests.map(\.id), ["swap-1"])
    }

    // MARK: Host arrivals

    func testQuestsArriveInTheHostsOrder() {
        var state = QuestsViewState(enabled: true)
        state.apply(.questsArrived(sampleQuests))
        XCTAssertEqual(state.quests.map(\.id), ["cook-2", "swap-1"], "never re-sorted")
    }

    func testQuestLookupById() {
        let state = QuestsViewState(enabled: true, quests: sampleQuests)
        XCTAssertEqual(state.quest(id: "swap-1")?.title, "One substitution")
        XCTAssertNil(state.quest(id: "nope"))
    }

    func testWeekCaptionCountsTheHostsQuests() {
        let state = QuestsViewState(enabled: true, quests: sampleQuests)
        XCTAssertEqual(state.weekCaption, "2 this week")
    }

    func testCountersArriveFromTheHostVerbatim() {
        var state = QuestsViewState(enabled: true)
        state.apply(.countersArrived(cooksMade: 4, swapsUsed: 2, savedGrams: 620))
        XCTAssertEqual(state.weekCooksMade, 4)
        XCTAssertEqual(state.weekSwapsUsed, 2)
        XCTAssertEqual(state.weekSavedGrams, 620)
    }

    func testSavedDisplayUsesTheSharedGrammar() {
        var state = QuestsViewState(enabled: true)
        state.apply(.countersArrived(cooksMade: 0, swapsUsed: 0, savedGrams: 620))
        XCTAssertEqual(state.weekSavedDisplay, "620 g")
        state.apply(.countersArrived(cooksMade: 0, swapsUsed: 0, savedGrams: 1200))
        XCTAssertEqual(state.weekSavedDisplay, "1.2 kg", "the same grammar as Progress — they cannot drift")
    }

    // MARK: Joining — online and offline

    func testJoinOnlineGivesTheQuietReceipt() {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.apply(.join(id: "cook-2"))
        XCTAssertTrue(state.quests[0].isJoined)
        XCTAssertEqual(state.joinReceipt, "You're in.")
        XCTAssertTrue(state.pendingJoinIds.isEmpty)
    }

    func testJoinOfflineQueuesWithAnHonestReceipt() {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.asOf = "As of 18:40"  // the host writes provenance directly
        state.apply(.join(id: "cook-2"))
        XCTAssertEqual(state.pendingJoinIds, ["cook-2"], "the join queues")
        XCTAssertEqual(
            state.joinReceipt, "You're in — this queued while offline.",
            "a visible receipt, never a spinner pretending to have joined")
    }

    func testConnectionRestoredAppliesQueuedJoinsAndConfirms() {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.asOf = "As of 18:40"
        state.apply(.join(id: "cook-2"))
        state.apply(.connectionRestored)
        XCTAssertTrue(state.quests[0].isJoined)
        XCTAssertTrue(state.pendingJoinIds.isEmpty, "the queue drains")
        XCTAssertEqual(state.joinReceipt, "You're in — confirmed.")
    }

    func testLeaveIsQuietAndDropsAQueuedJoin() {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.apply(.join(id: "cook-2"))
        state.apply(.leave(id: "cook-2"))
        XCTAssertFalse(state.quests[0].isJoined)
        XCTAssertNil(state.joinReceipt, "leave is quiet — no error, no confirmation")
        XCTAssertTrue(state.pendingJoinIds.isEmpty)

        // Leaving offline also drops the queued join.
        var offline = QuestsViewState(enabled: true, quests: sampleQuests)
        offline.asOf = "As of 18:40"
        offline.apply(.join(id: "swap-1"))
        offline.apply(.leave(id: "swap-1"))
        XCTAssertTrue(offline.pendingJoinIds.isEmpty)
        offline.apply(.connectionRestored)
        XCTAssertNil(offline.joinReceipt, "nothing queued, nothing to confirm")
    }

    func testDoneQuestsDoNotRejoin() {
        var quests = sampleQuests
        quests[0].doneLine = "Done — nice week."
        var state = QuestsViewState(enabled: true, quests: quests)
        state.apply(.join(id: "cook-2"))
        XCTAssertFalse(state.quests[0].isJoined, "a done quest never re-joins")
    }

    // MARK: The share preview — the only path to a payload

    func testSharePreviewIsTheAllowlistProjectionOfTheCookRecord() throws {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.apply(.shareResult(id: "cook-2", record: sampleRecord))
        let preview = try XCTUnwrap(state.sharePreview)
        XCTAssertEqual(preview.questId, "cook-2")
        XCTAssertEqual(preview.questTitle, "Cook twice this week")
        XCTAssertEqual(preview.revisionId, "r-88")
        XCTAssertEqual(preview.servings, 2)
        XCTAssertEqual(preview.swapsUsed, 1)
        XCTAssertEqual(preview.rating, 5)
        XCTAssertEqual(preview.noteLine, "Fed two, no leftovers.")
    }

    func testSharePreviewCannotAppearForAnUnknownQuest() {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.apply(.shareResult(id: "ghost", record: sampleRecord))
        XCTAssertNil(state.sharePreview)
    }

    func testSharePreviewCannotAppearWhileTheFlagIsOff() {
        var state = QuestsViewState()
        state.apply(.questsArrived(sampleQuests))
        state.apply(.shareResult(id: "cook-2", record: sampleRecord))
        XCTAssertNil(state.sharePreview)
    }

    func testCancelAndConfirmBothCloseThePreview() {
        var state = QuestsViewState(enabled: true, quests: sampleQuests)
        state.apply(.shareResult(id: "cook-2", record: sampleRecord))
        state.apply(.cancelSharePreview)
        XCTAssertNil(state.sharePreview)

        state.apply(.shareResult(id: "cook-2", record: sampleRecord))
        state.apply(.shareConfirmed)
        XCTAssertNil(state.sharePreview, "the host performed the share; the preview closes")
    }
}
