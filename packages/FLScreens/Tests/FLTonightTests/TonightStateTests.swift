// FLTonight tests — the SPEC 2 rules the screen must encode, as tests.
//
// The honest fit line, the rejection constraint pattern, the taste
// question asked once, "choose tomorrow" never taken away, servings edits
// never morphing a state, and the identity of navigation intents.

import XCTest
@testable import FLTonight

final class TonightStateTests: XCTestCase {

    // MARK: Fixtures (synthetic copy — no real user data)

    private func fit(
        sufficient: Int, total: Int, swapsNeeded: Int = 0, shortfall: TonightFit.LineState = .short(amount: "1")
    ) -> TonightFit {
        var lines: [TonightFit.Line] = (0..<sufficient).map {
            .init(name: "have-\($0)", state: .sufficient)
        }
        let shortfallNames = ["eggs", "oil", "butter", "lemon"]
        for index in 0..<(total - sufficient) {
            lines.append(.init(name: shortfallNames[index % shortfallNames.count], state: shortfall))
        }
        return TonightFit(lines: lines, swapsNeeded: swapsNeeded)
    }

    private func pick(fit: TonightFit, servings: Int = 2) -> TonightViewState.Pick {
        TonightViewState.Pick(
            recipeID: "r-1",
            title: "Ginger chicken udon noodles",
            meta: TonightViewState.MealMeta(minutes: 25, servings: servings, kilocalories: 520),
            photo: TonightViewState.PhotoSpec(caption: "photo: overhead, daylight"),
            fit: fit,
            why: TonightViewState.WhyLine(
                text: "You've cooked noodles four times this month and rated two of them 5.",
                profileSentenceID: "s-1"
            )
        )
    }

    private func state(
        _ content: TonightViewState.Content, lateLinesLoading: Bool = false
    ) -> TonightViewState {
        TonightViewState(
            dateLabel: "Sat 11 Oct",
            content: content,
            lateLinesLoading: lateLinesLoading
        )
    }

    // MARK: Fit honesty (SPEC 3.2)

    func testFitLineNumericFormOnlyWhenShortfallsAreRealSwaps() {
        // Nine sufficient, one short, one real swap: "9 of 10 · 1 swap".
        let covered = fit(sufficient: 9, total: 10, swapsNeeded: 1)
        XCTAssertEqual(covered.lineText, "9 of 10 · 1 swap")

        // Two real swaps: plural, real count.
        let coveredTwo = fit(sufficient: 8, total: 10, swapsNeeded: 2)
        XCTAssertEqual(coveredTwo.lineText, "8 of 10 · 2 swaps")
    }

    func testFitLineNamesProblemLinesWhenSwapsDoNotCoverIt() {
        // A shortfall that is not a plain short, or swaps that do not
        // cover it: the recorded form with the names.
        let unknownQuantity = fit(
            sufficient: 7, total: 10, swapsNeeded: 1, shortfall: .quantityUnknown
        )
        XCTAssertEqual(unknownQuantity.lineText, "7 recorded · check eggs and oil and 1 more")

        let uncovered = fit(sufficient: 7, total: 10, swapsNeeded: 0)
        XCTAssertEqual(uncovered.lineText, "7 recorded · check eggs and oil and 1 more")
    }

    func testFitLineNeverClaimsMoreThanIsSufficient() {
        // A short line that has no swap behind it is never counted as had.
        let f = fit(sufficient: 9, total: 10, swapsNeeded: 0)
        XCTAssertTrue(f.lineText.hasPrefix("9 "))
        XCTAssertFalse(f.lineText.contains("10 of 10"))
    }

    func testFitLineNeverContainsAPercentage() {
        let cases: [TonightFit] = [
            fit(sufficient: 10, total: 10),
            fit(sufficient: 9, total: 10, swapsNeeded: 1),
            fit(sufficient: 3, total: 10, swapsNeeded: 0),
            fit(sufficient: 0, total: 4, shortfall: .needsReconfirming),
        ]
        for f in cases {
            XCTAssertFalse(f.lineText.contains("%"), "\(f.lineText) contains a percentage")
        }
    }

    func testFitLineAllSufficientStatesTheFullCount() {
        // "You have everything" is only earned when every line is
        // sufficient — and this grammar states the count instead of a claim.
        let f = fit(sufficient: 10, total: 10)
        XCTAssertEqual(f.lineText, "10 of 10")
        XCTAssertTrue(f.allSufficient)
    }

    func testFitLineNamesAtMostTwoProblemLinesThenCountsTheRest() {
        let f = fit(sufficient: 5, total: 9, shortfall: .needsReconfirming)
        XCTAssertEqual(f.lineText, "5 recorded · check eggs and oil and 2 more")
    }

    // MARK: Rejections (SPEC 2: after the third "Something else")

    func testThirdRejectionOffersTheConstraintChoice() {
        var s = state(.pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))))
        s.apply(.somethingElse)
        XCTAssertFalse(s.constraintsOffered)
        s.apply(.somethingElse)
        XCTAssertFalse(s.constraintsOffered)
        s.apply(.somethingElse)
        XCTAssertTrue(s.constraintsOffered, "the third rejection offers the constraint choice")

        // …and the sixth again (every third).
        s.apply(.somethingElse)
        XCTAssertFalse(s.constraintsOffered)
        s.apply(.somethingElse)
        XCTAssertFalse(s.constraintsOffered)
        s.apply(.somethingElse)
        XCTAssertTrue(s.constraintsOffered)
    }

    func testRejectionsNeverBecomeDislikes() {
        // The rejection counter is the ONLY thing a rejection changes. No
        // taste field exists; assert the whole screen state is otherwise
        // untouched.
        let before = state(
            .pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))),
            lateLinesLoading: false
        )
        var after = before
        after.apply(.somethingElse)
        after.apply(.somethingElse)

        var expected = before
        expected.rejectionCount = 2
        XCTAssertEqual(after, expected, "a rejection changes nothing but the count")
    }

    func testChoosingAConstraintClosesTheOfferAndNeverWritesTaste() {
        var s = state(.pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))))
        s.apply(.somethingElse)
        s.apply(.somethingElse)
        s.apply(.somethingElse)
        XCTAssertTrue(s.constraintsOffered)

        s.apply(.chooseConstraint(.lessEffort))
        XCTAssertFalse(s.constraintsOffered)
        // The pick is untouched — filtering is the host's next computation.
        XCTAssertNotNil(s.carriedPick)
        XCTAssertEqual(s.rejectionCount, 3, "a constraint choice is not another rejection")
    }

    func testConstraintChoiceCoversTheFourOptions() {
        // SPEC 2: quicker, different main, less effort, pick from a list.
        XCTAssertEqual(
            Set(TonightConstraint.allCases.map(\.rawValue)),
            ["quicker", "differentMain", "lessEffort", "pickFromList"]
        )
    }

    // MARK: The taste question (asked once, never repeated)

    func testTasteQuestionDismissesOnEitherAnswerAndWritesNoTaste() {
        var s = state(
            .pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))),
        )
        s.tasteQuestion = .init(id: "coriander", text: "You've taken coriander out 5 times. Stop suggesting it?")

        let before = s
        s.apply(.answerTasteQuestion(questionID: "coriander", stop: true))
        XCTAssertNil(s.tasteQuestion)
        s.tasteQuestion = before.tasteQuestion
        s.apply(.answerTasteQuestion(questionID: "coriander", stop: false))
        XCTAssertNil(s.tasteQuestion, "either answer dismisses the question")

        // "No" is not a dislike either: with the question removed from the
        // comparison, the screen state is identical.
        var expectedNo = before
        expectedNo.tasteQuestion = nil
        // (redo from before to compare the stop:false path)
        var replay = before
        replay.apply(.answerTasteQuestion(questionID: "coriander", stop: false))
        XCTAssertEqual(replay, expectedNo)
    }

    // MARK: Choose tomorrow — no clock cutoff

    func testChooseTomorrowIsAlwaysAvailable() {
        let contents: [TonightViewState.Content] = [
            .unknownKitchen(reason: .neverScanned, example: nil),
            .pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))),
            .sparse(pick: pick(fit: fit(sufficient: 2, total: 10)), youdNeed: ["rice noodles"]),
            .nothingFeasible(pick: pick(fit: fit(sufficient: 3, total: 10))),
        ]
        for content in contents {
            let s = state(content)
            XCTAssertTrue(s.canChooseTomorrow, "\(content) must not take Choose-tomorrow away")
        }
    }

    // MARK: Servings edits preserve the content case

    func testSetServingsClampsAndPreservesTheState() {
        var sparse = state(.sparse(pick: pick(fit: fit(sufficient: 2, total: 10)), youdNeed: ["rice noodles"]))
        sparse.apply(.setServings(4))
        XCTAssertEqual(sparse.carriedPick?.meta.servings, 4)
        guard case .sparse(_, let youdNeed) = sparse.content else {
            return XCTFail("a servings edit must not morph a sparse kitchen into a full pick")
        }
        XCTAssertEqual(youdNeed, ["rice noodles"])

        var full = state(.pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))))
        full.apply(.setServings(0))
        XCTAssertEqual(full.carriedPick?.meta.servings, 1, "servings clamp at 1")
        full.apply(.setServings(99))
        XCTAssertEqual(full.carriedPick?.meta.servings, 12, "servings clamp at 12")
    }

    // MARK: Late lines and the error stamp

    func testLateLinesArrivedClearsTheLoadingState() {
        var s = state(.pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))), lateLinesLoading: true)
        s.apply(.lateLinesArrived)
        XCTAssertFalse(s.lateLinesLoading)
    }

    func testPickAsOfIsHostSetAndUntouchedByReducerIntents() {
        var s = state(.pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))))
        s.pickAsOf = "As of 6:10 pm"
        s.apply(.somethingElse)
        XCTAssertEqual(s.pickAsOf, "As of 6:10 pm")
    }

    // MARK: Navigation intents are host-routed (identity)

    func testNavigationIntentsAreIdentity() {
        let base = state(.pick(pick(fit: fit(sufficient: 9, total: 10, swapsNeeded: 1))))
        let identityIntents: [TonightIntent] = [
            .cookThis, .chooseTomorrow, .scanKitchen, .enterManually, .resumeCook,
            .openWhy, .openAlternative(recipeID: "r-1"), .openUseSoon(itemID: "u-1"),
            .openProfileSentence(sentenceID: "s-1"), .shoppingList, .pickFromSaved,
        ]
        for intent in identityIntents {
            XCTAssertEqual(TonightReducer.reduced(base, by: intent), base, "\(intent) is host-routed")
        }
    }

    // MARK: Meta display

    func testMealMetaDisplayOmitsMissingKcal() {
        XCTAssertEqual(
            TonightViewState.MealMeta(minutes: 25, servings: 2, kilocalories: 520).display,
            "25 min · 2 servings · 520 kcal"
        )
        XCTAssertEqual(
            TonightViewState.MealMeta(minutes: 15, servings: 1).display,
            "15 min · 1 servings"
        )
    }
}
