// FLTasteProfile tests — the on-device taste editor's binding rules, as
// tests.
//
// Nothing is deleted by judgement: Wrong excludes and keeps; forget
// holds a receipt with undo in place; forget-all asks once and
// preserves restrictions. Evidence is host-verbatim with denominators —
// never computed here. Restrictions are hard filters, filtered before
// ranking, and setup-set ones are never weakened on this screen.
//
// Fixtures are synthetic. Every test runs on Linux — the reducer,
// validation and display grammar are Foundation-only.

import XCTest
@testable import FLTasteProfile

// MARK: Fixtures (file scope — usable as default parameter values)

private func sentence(
    id: String = "s-1", text: String = "You cook on weeknights, mostly under 30 minutes.",
    evidence: String = "18 of 23", kind: TasteViewState.SentenceKind = .pattern,
    status: TasteViewState.SentenceStatus = .learning,
    confirmationLine: String? = nil
) -> TasteViewState.Sentence {
    TasteViewState.Sentence(
        id: id, text: text, evidenceDisplay: evidence, kind: kind,
        status: status, confirmationLine: confirmationLine
    )
}

private func memory(
    id: String = "m-1", text: String = "Too salty. Low-sodium stock next time.",
    dish: String? = nil, date: String = "3 Oct"
) -> TasteViewState.Memory {
    TasteViewState.Memory(id: id, text: text, dishName: dish, dateDisplay: date)
}

private func restriction(
    id: String = "res-1", name: String = "Shellfish allergy",
    locked: Bool = false, note: String? = nil
) -> TasteViewState.Restriction {
    TasteViewState.Restriction(id: id, name: name, isLocked: locked, setupNote: note)
}

final class TasteStateTests: XCTestCase {

    // MARK: Fixtures (synthetic copy — no real user data)

    private func state(
        sentences: [TasteViewState.Sentence] = [sentence()],
        memories: [TasteViewState.Memory] = [memory()],
        restrictions: [TasteViewState.Restriction] = [restriction()],
        setup: [String] = ["No shellfish", "cooking for 2", "metric"]
    ) -> TasteViewState {
        TasteViewState(
            sentences: sentences, memories: memories,
            restrictions: restrictions, setupSummary: setup,
            cooksCountDisplay: "23 cooks"
        )
    }

    // MARK: Judgements — excluded and kept

    func testRightConfirmsAndKeepsTheRow() {
        var subject = state()
        subject.apply(.judge(sentenceID: "s-1", right: true))
        XCTAssertEqual(subject.sentences.first?.status, .confirmed)
        XCTAssertEqual(subject.sentences.count, 1, "confirmation keeps the row in the ledger")
        XCTAssertTrue(subject.hasUnsavedChanges)
    }

    func testWrongRejectsAndKeepsTheRow() {
        var subject = state()
        subject.apply(.judge(sentenceID: "s-1", right: false))
        XCTAssertEqual(subject.sentences.first?.status, .rejected)
        XCTAssertEqual(subject.sentences.count, 1, "nothing is deleted on Wrong — excluded and kept")
    }

    func testJudgingAgainSwitchesTheAnswer() {
        var subject = state()
        subject.apply(.judge(sentenceID: "s-1", right: true))
        subject.apply(.judge(sentenceID: "s-1", right: false))
        XCTAssertEqual(subject.sentences.first?.status, .rejected)
    }

    func testUndoRestoresLearningExactly() {
        var subject = state(sentences: [sentence(confirmationLine: "Confirmed 3 Oct. Never suggested.")])
        subject.apply(.judge(sentenceID: "s-1", right: true))
        subject.apply(.undoJudgement(sentenceID: "s-1"))
        XCTAssertEqual(subject.sentences.first?.status, .learning)
        XCTAssertNil(subject.sentences.first?.confirmationLine, "undo restores exactly")
        XCTAssertTrue(subject.hasUnsavedChanges)
    }

    func testJudgementOnUnknownSentencesChangesNothing() {
        var subject = state()
        subject.apply(.judge(sentenceID: "ghost", right: true))
        XCTAssertFalse(subject.hasUnsavedChanges)
        XCTAssertEqual(subject.sentences.first?.status, .learning)
    }

    // MARK: Don't ask again — a different control from Wrong

    func testDontAskAgainStopsPromptsWithoutTouchingTheRecord() {
        var subject = state()
        subject.apply(.dontAskAgain(sentenceID: "s-1"))
        XCTAssertEqual(subject.sentences.first?.promptSuppressed, true)
        XCTAssertEqual(subject.sentences.first?.status, .learning, "the record and its status stay")
        XCTAssertEqual(subject.sentences.count, 1)
    }

    // MARK: Offers — three doors

    func testOfferSuggestConfirms() {
        var subject = state(sentences: [sentence(
            id: "fish", text: "You've never cooked fish here.",
            evidence: "0 of 23", kind: .offer
        )])
        subject.apply(.answerOffer(sentenceID: "fish", suggest: true))
        XCTAssertEqual(subject.sentences.first?.status, .confirmed)
    }

    func testOfferDeclineLeavesTheNeverSuggestDoor() {
        var subject = state(sentences: [sentence(
            id: "fish", text: "You've never cooked fish here.",
            evidence: "0 of 23", kind: .offer
        )])
        subject.apply(.answerOffer(sentenceID: "fish", suggest: false))
        XCTAssertEqual(subject.sentences.first?.offerDeclined, true)
        XCTAssertEqual(subject.sentences.first?.status, .learning, "a polite no is not a judgement")
        XCTAssertFalse(subject.sentences.first?.promptSuppressed ?? true)

        subject.apply(.neverSuggest(sentenceID: "fish"))
        XCTAssertEqual(subject.sentences.first?.promptSuppressed, true, "the permanent door stops prompts")
        XCTAssertEqual(subject.sentences.first?.offerDeclined, true)
    }

    func testOfferAnswersAreRefusedOnPatternRows() {
        var subject = state()
        subject.apply(.answerOffer(sentenceID: "s-1", suggest: true))
        XCTAssertEqual(subject.sentences.first?.status, .learning)
        XCTAssertFalse(subject.hasUnsavedChanges)
    }

    // MARK: Memory — forget with a receipt, undo in place

    func testForgetMemoryHoldsAReceipt() {
        var subject = state(memories: [memory(id: "m-1"), memory(id: "m-2", text: "Lemon instead of lime worked.", date: "28 Sept")])
        subject.apply(.forgetMemory(id: "m-1"))
        XCTAssertEqual(subject.memories.map { $0.id }, ["m-2"])
        XCTAssertEqual(subject.lastForgotten?.memory.id, "m-1")
        XCTAssertEqual(subject.lastForgotten?.previousIndex, 0)
        XCTAssertTrue(subject.hasUnsavedChanges)
    }

    func testUndoForgetRestoresInPlace() {
        var subject = state(memories: [
            memory(id: "m-1"), memory(id: "m-2", text: "Second note."), memory(id: "m-3", text: "Third note."),
        ])
        subject.apply(.forgetMemory(id: "m-2"))
        subject.apply(.undoForget)
        XCTAssertEqual(subject.memories.map { $0.id }, ["m-1", "m-2", "m-3"], "restored at its original place")
        XCTAssertNil(subject.lastForgotten, "the receipt is spent")
    }

    func testUndoForgetClampsWhenTheListShrank() {
        var subject = state(memories: [memory(id: "m-1"), memory(id: "m-2", text: "Second.")])
        subject.apply(.forgetMemory(id: "m-2"))
        subject.apply(.forgetMemory(id: "m-1")) // replaces the receipt; index 1 > new count 0
        subject.apply(.undoForget)
        XCTAssertEqual(subject.memories.map { $0.id }, ["m-1"], "restore clamps to the list's bounds")
        XCTAssertNil(subject.lastForgotten)
    }

    func testUndoWithoutAReceiptChangesNothing() {
        var subject = state()
        let before = subject
        subject.apply(.undoForget)
        XCTAssertEqual(subject, before)
    }

    // MARK: Forget everything — asks once, restrictions survive

    func testForgetAllAsksOnceWithTheCount() {
        var subject = state(sentences: [sentence(), sentence(id: "s-2", text: "Second.", evidence: "3 of 3")], memories: [memory()])
        subject.apply(.askForgetAll)
        XCTAssertTrue(subject.isConfirmingForgetAll)
        XCTAssertEqual(subject.forgetAllPromptDisplay, "Forget 3 things? Restrictions stay.")

        subject.apply(.cancelForgetAll)
        XCTAssertFalse(subject.isConfirmingForgetAll)
        XCTAssertEqual(subject.sentences.count, 2, "cancelling deletes nothing")
    }

    func testForgetAllIsRefusedWithNothingToForget() {
        var subject = state(sentences: [], memories: [])
        subject.apply(.askForgetAll)
        XCTAssertFalse(subject.isConfirmingForgetAll)
    }

    func testForgetEverythingRequiresTheConfirmation() {
        var subject = state()
        subject.apply(.forgetEverything)
        XCTAssertEqual(subject.sentences.count, 1, "no wipe without the ask-once confirmation")
        XCTAssertEqual(subject.memories.count, 1)
    }

    func testForgetEverythingClearsSentencesAndMemoriesKeepsRestrictions() {
        var subject = state()
        subject.apply(.forgetMemory(id: "m-1")) // a pending receipt goes too
        subject.apply(.askForgetAll)
        subject.apply(.forgetEverything)
        XCTAssertTrue(subject.sentences.isEmpty)
        XCTAssertTrue(subject.memories.isEmpty)
        XCTAssertNil(subject.lastForgotten)
        XCTAssertEqual(subject.restrictions.count, 1, "explicit restrictions survive any reset")
        XCTAssertEqual(subject.restrictions.first?.name, "Shellfish allergy")
        XCTAssertEqual(subject.setupSummary.count, 3, "setup lines are not taste learning")
        XCTAssertFalse(subject.isConfirmingForgetAll)
        XCTAssertTrue(subject.hasUnsavedChanges)
    }

    // MARK: Restrictions — hard filters, edited with validation

    func testAddRestrictionTrimsAndAppends() {
        var subject = state()
        subject.apply(.addRestriction(name: "  Blue cheese  "))
        XCTAssertEqual(subject.restrictions.count, 2)
        XCTAssertEqual(subject.restrictions.last?.name, "Blue cheese")
        XCTAssertTrue(subject.hasUnsavedChanges)
    }

    func testAddRestrictionRefusesEmptyNames() {
        var subject = state()
        subject.apply(.addRestriction(name: "   "))
        XCTAssertEqual(subject.restrictions.count, 1, "a blank restriction filters nothing")
        XCTAssertFalse(subject.hasUnsavedChanges)
    }

    func testAddRestrictionDedupesCaseInsensitivelyWithCollapsedWhitespace() {
        var subject = state(restrictions: [restriction(id: "res-1", name: "Blue cheese")])
        subject.apply(.addRestriction(name: "  blue  CHEESE "))
        XCTAssertEqual(subject.restrictions.count, 1, "the same filter must not land twice")
        XCTAssertFalse(subject.hasUnsavedChanges)
    }

    func testRemoveRestrictionWorksOnlyOnUnlockedRows() {
        var subject = state(restrictions: [
            restriction(id: "res-1", name: "Coriander"),
            restriction(id: "res-2", name: "Shellfish allergy", locked: true, note: "edited in setup"),
        ])
        subject.apply(.removeRestriction(id: "res-1"))
        XCTAssertEqual(subject.restrictions.map { $0.id }, ["res-2"], "unlocked restrictions can be removed")
        XCTAssertTrue(subject.hasUnsavedChanges)

        subject.apply(.removeRestriction(id: "res-2"))
        XCTAssertEqual(subject.restrictions.map { $0.id }, ["res-2"], "setup-set restrictions are never weakened here")
    }

    // MARK: Save flow

    func testSaveRoundTripClearsTheUnsavedFlag() {
        var subject = state()
        subject.apply(.judge(sentenceID: "s-1", right: true))
        XCTAssertTrue(subject.hasUnsavedChanges)
        subject.apply(.saveEdits) // host effect — state unchanged
        XCTAssertTrue(subject.hasUnsavedChanges, "the flag survives until the host reports")
        subject.apply(.editsSaved)
        XCTAssertFalse(subject.hasUnsavedChanges)
        XCTAssertFalse(subject.saveFailed)
    }

    func testSaveFailureKeepsTheEdits() {
        var subject = state()
        subject.apply(.judge(sentenceID: "s-1", right: false))
        subject.apply(.editsFailed)
        XCTAssertTrue(subject.saveFailed)
        XCTAssertTrue(subject.hasUnsavedChanges, "the edits are kept")
        XCTAssertEqual(subject.sentences.first?.status, .rejected, "the judgement stands")
    }

    // MARK: Display grammar

    func testEvidenceIsHostVerbatimNeverComputed() {
        let subject = state(sentences: [sentence(evidence: "9 · 6 · 7")])
        XCTAssertEqual(subject.sentences.first?.evidenceDisplay, "9 · 6 · 7")
    }

    func testMemoriesCountIsTheSectionNumber() {
        let subject = state(memories: [memory(), memory(id: "m-2", text: "Second.", date: "28 Sept")])
        XCTAssertEqual(subject.memoriesCountDisplay, "2")
    }

    func testNewUserModeCarriesItsOwnLine() {
        let subject = TasteViewState(
            isNewUser: true,
            newUserLine: "Cook three things and I'll start writing this. Until then I'm using what you told me at setup."
        )
        XCTAssertTrue(subject.isNewUser)
        XCTAssertEqual(
            subject.newUserLine,
            "Cook three things and I'll start writing this. Until then I'm using what you told me at setup.")
        XCTAssertTrue(subject.sentences.isEmpty, "thin data is filtered host-side")
    }

    func testNormalisedRestrictionCollapsesWhitespaceAndCase() {
        XCTAssertEqual(TasteViewState.normalizedRestriction("  Shellfish   Allergy "), "shellfish allergy")
        XCTAssertTrue(
            TasteViewState.normalizedRestriction("NO PORK") == TasteViewState.normalizedRestriction("no pork"))
    }
}
