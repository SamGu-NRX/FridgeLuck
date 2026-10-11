// FLScan tests — the capture-and-review flow's binding rules, as tests.
//
// A scan OBSERVES; it never adds stock on its own. Unanswered questions
// never block the commit. Errors are escapes, never dead ends. The
// commit is idempotent. Quantities arrive verbatim — never invented.
// No confidence percentage exists anywhere.
//
// Fixtures are synthetic. Every test runs on Linux — the stage machine,
// dedup and display grammar are Foundation-only.

import XCTest
@testable import FLScan

// MARK: Fixtures (file scope — usable as default parameter values)

private func pantry(_ pairs: [(String, String)]) -> [ScanViewState.PantryItem] {
    pairs.map { ScanViewState.PantryItem(name: $0.0, quantityDisplay: $0.1) }
}

private func item(
    id: String = "r-1", name: String = "Greek yogurt", quantity: String = "4",
    receiptLine: String? = nil
) -> ScanViewState.RecognizedItem {
    ScanViewState.RecognizedItem(
        id: id, name: name, quantityDisplay: quantity, receiptLine: receiptLine
    )
}

private func uncertain(
    id: String = "u-1", observed: String = "Leafy, pale stems, top shelf.",
    options: [String] = ["Chard", "Celery"]
) -> ScanViewState.UncertainItem {
    ScanViewState.UncertainItem(id: id, observedLine: observed, options: options)
}

final class ScanStateTests: XCTestCase {
    private func capturingState(pantryItems: [ScanViewState.PantryItem] = []) -> ScanViewState {
        var state = ScanViewState(pantryItems: pantryItems)
        state.apply(.startCapture)
        return state
    }

    private func reviewingState(
        pantryItems: [ScanViewState.PantryItem] = [],
        recognised: [ScanViewState.RecognizedItem] = [item()],
        uncertain: [ScanViewState.UncertainItem] = []
    ) -> ScanViewState {
        var state = capturingState(pantryItems: pantryItems)
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        state.apply(.recognitionProgress(recognised: recognised, uncertain: uncertain))
        state.apply(.recognitionFinished)
        return state
    }

    // MARK: Stage machine

    func testStartCaptureFromIdleEntersCapturingAndKeepsPantry() {
        var state = ScanViewState(pantryItems: pantry([("eggs", "6")]))
        state.apply(.startCapture)
        XCTAssertEqual(state.stage, .capturing)
        XCTAssertEqual(state.pantryItems.count, 1, "the pantry snapshot survives the stage change")
        XCTAssertEqual(state.pantryItems.first?.name, "eggs")
    }

    func testStartCaptureIsIgnoredOutsideIdle() {
        var state = capturingState()
        state.apply(.startCapture)
        XCTAssertEqual(state.stage, .capturing, "a second start must not reset the capture")
    }

    func testCameraDeniedIsAnEscapeNotADeadEnd() {
        var state = capturingState()
        state.apply(.cameraDenied)
        XCTAssertEqual(state.cameraFailure, .denied)
        XCTAssertEqual(state.cameraFailureDisplay, "Camera off. Add by hand any time.")
    }

    func testCameraFailedCarriesTheFailedCopy() {
        var state = capturingState()
        state.apply(.cameraFailed)
        XCTAssertEqual(state.cameraFailure, .failed)
        XCTAssertEqual(state.cameraFailureDisplay, "The camera didn't open. Add by hand any time.")
    }

    func testCameraFailureIsOnlyAcceptedWhileCapturing() {
        var state = ScanViewState()
        state.apply(.cameraDenied)
        XCTAssertNil(state.cameraFailure, "a refusal outside the capture stage changes nothing")

        var reviewing = reviewingState()
        reviewing.apply(.cameraFailed)
        XCTAssertNil(reviewing.cameraFailure)
    }

    func testCaptureTakenStartsRecognizingWithKindAndCaption() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .receipt, photoCaption: "Receipt"))
        XCTAssertEqual(state.stage, .recognizing)
        XCTAssertEqual(state.runKind, .receipt)
        XCTAssertEqual(state.photoCaption, "Receipt")
        XCTAssertEqual(state.titleDisplay, "Looking", "the analysing state says Looking")
    }

    func testCaptureTakenCannotFollowARefusedCamera() {
        var state = capturingState()
        state.apply(.cameraDenied)
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        XCTAssertEqual(state.stage, .capturing, "a refused camera cannot reach recognition")
        XCTAssertNil(state.runKind)
    }

    // MARK: Capture quality gate

    func testCaptureIssueIsDetectedBeforeUploadAndShownOverThePhoto() {
        var state = capturingState()
        state.apply(.captureRejected(.tooDark))
        XCTAssertEqual(state.captureIssue, .tooDark)
        XCTAssertEqual(state.captureIssueDisplay, "Too dark to read")
        XCTAssertEqual(state.stage, .capturing, "the gate keeps the capture stage")
    }

    func testBlurryCopyMatchesTheMock() {
        var state = capturingState()
        state.apply(.captureRejected(.tooBlurry))
        XCTAssertEqual(state.captureIssueDisplay, "Too blurry")
    }

    func testRetakeClearsTheQualityIssueAndStaysCapturing() {
        var state = capturingState()
        state.apply(.captureRejected(.tooBlurry))
        state.apply(.retake)
        XCTAssertEqual(state.stage, .capturing)
        XCTAssertNil(state.captureIssue)
    }

    func testRetakeFromReviewStartsAFreshCaptureNotAnAppend() {
        var state = reviewingState(pantryItems: pantry([("eggs", "6")]))
        state.apply(.retake)
        XCTAssertEqual(state.stage, .capturing)
        XCTAssertTrue(state.sureItems.isEmpty, "a retake is a new run, not an append")
        XCTAssertTrue(state.uncertainItems.isEmpty)
        XCTAssertEqual(state.pantryItems.count, 1, "the pantry snapshot survives")
    }

    // MARK: Recognition ingestion

    func testRecognitionProgressCoalescesEchoesByNormalisedName() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        let first = item(id: "r-1", name: "Greek yogurt", quantity: "4")
        state.apply(.recognitionProgress(recognised: [first], uncertain: []))
        // The same item again, with casing and spacing variants — an echo.
        let echo = item(id: "r-2", name: "  greek  YOGURT ", quantity: "9")
        state.apply(.recognitionProgress(recognised: [echo], uncertain: []))
        XCTAssertEqual(state.sureItems.count, 1, "an echo never duplicates a row")
        XCTAssertEqual(state.sureItems.first?.quantityDisplay, "4", "the first quantity wins; neither is invented")
    }

    func testRecognitionProgressClassifiesAgainstThePantry() {
        var state = capturingState(pantryItems: pantry([("spinach", "1 bag")]))
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        let known = item(id: "r-1", name: "  Spinach ", quantity: "2")
        let fresh = item(id: "r-2", name: "Miso paste", quantity: "1")
        state.apply(.recognitionProgress(recognised: [known, fresh], uncertain: []))
        XCTAssertEqual(state.sureItems.count, 2)
        let spinach = state.sureItems.first { $0.id == "r-1" }
        XCTAssertEqual(spinach?.isExisting, true, "a pantry name match marks the row existing")
        XCTAssertEqual(spinach?.existingQuantityDisplay, "1 bag", "the Still-N number is the pantry's own")
        let miso = state.sureItems.first { $0.id == "r-2" }
        XCTAssertEqual(miso?.isExisting, false)
        XCTAssertNil(miso?.existingQuantityDisplay)
    }

    func testRecognitionProgressIsIgnoredOutsideRecognizing() {
        var state = reviewingState()
        let late = item(id: "late-1", name: "Late arrival", quantity: "1")
        state.apply(.recognitionProgress(recognised: [late], uncertain: []))
        XCTAssertFalse(
            state.sureItems.contains { $0.id == "late-1" },
            "results landing after the stream ended change nothing")
    }

    func testUncertainItemsJoinAsQuestionsAndEmptyOptionRowsAreDropped() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        state.apply(.recognitionProgress(
            recognised: [],
            uncertain: [uncertain(id: "u-1"), uncertain(id: "u-2", options: [])]
        ))
        XCTAssertEqual(state.uncertainItems.count, 1, "an unresolvable result is a recognition problem, not a question")
        XCTAssertEqual(state.uncertainItems.first?.id, "u-1")
    }

    func testUncertainEchoesDoNotDuplicate() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        state.apply(.recognitionProgress(recognised: [], uncertain: [uncertain(id: "u-1")]))
        state.apply(.recognitionProgress(recognised: [], uncertain: [uncertain(id: "u-1")]))
        XCTAssertEqual(state.uncertainItems.count, 1)
    }

    func testRecognitionFinishedEntersReview() {
        let state = capturingState().applied(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
            .applied(.recognitionProgress(recognised: [item()], uncertain: []))
            .applied(.recognitionFinished)
        XCTAssertEqual(state.stage, .reviewing)
    }

    func testRecognitionFailedKeepsThePhotoAndOffersRetryWithoutRecapture() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        state.apply(.recognitionFailed)
        XCTAssertEqual(state.stage, .reviewing)
        XCTAssertEqual(state.recognitionProblem, .requestFailed)
        XCTAssertEqual(state.photoCaption, "Shelf", "the photo stays")
        XCTAssertEqual(
            state.problemDisplay,
            "Couldn't read this photo. Try again or add by name.")

        state.apply(.retryRecognition)
        XCTAssertEqual(state.stage, .recognizing, "retry keeps the photo — no re-capture required")
        XCTAssertNil(state.recognitionProblem)
        XCTAssertEqual(state.photoCaption, "Shelf")
    }

    func testRetryIsOnlyPossibleFromAFailedReview() {
        var state = reviewingState()
        state.apply(.retryRecognition)
        XCTAssertEqual(state.stage, .reviewing, "a healthy review has nothing to retry")

        var fresh = ScanViewState()
        fresh.apply(.retryRecognition)
        XCTAssertEqual(fresh.stage, .idle)
    }

    func testRecognisedNothingCarriesTheCoachingCopy() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        state.apply(.recognisedNothing)
        XCTAssertEqual(state.stage, .reviewing)
        XCTAssertEqual(state.recognitionProblem, .nothingRecognised)
        XCTAssertEqual(
            state.problemDisplay,
            "Nothing I recognise. Try one shelf, straight on, with the door light on.")
    }

    // MARK: Review edits — uncertain rows

    func testAnsweringAnUncertainRowMovesItToSureWithUnknownQuantity() {
        var state = reviewingState(uncertain: [uncertain(id: "u-1")])
        state.apply(.answerUncertain(itemID: "u-1", name: "  Chard  "))
        XCTAssertTrue(state.uncertainItems.isEmpty)
        let answered = state.sureItems.first { $0.id == "u-1" }
        XCTAssertEqual(answered?.name, "Chard", "the answer is trimmed")
        XCTAssertEqual(answered?.quantityDisplay, "?", "the scan never invents grams")
    }

    func testAnsweringAnUncertainRowWithAPantryNameBecomesADuplicateQuestion() {
        var state = reviewingState(pantryItems: pantry([("celery", "2")]), uncertain: [uncertain(id: "u-1")])
        state.apply(.answerUncertain(itemID: "u-1", name: "Celery"))
        let answered = state.sureItems.first { $0.id == "u-1" }
        XCTAssertEqual(answered?.isExisting, true, "a chosen name already in the kitchen asks, never double-adds")
        XCTAssertEqual(answered?.existingQuantityDisplay, "2")
        XCTAssertEqual(answered?.dedup, .pending, "undecided duplicates default to observe")
    }

    func testAnsweringAnUncertainRowWithABlankNameIsRefused() {
        var state = reviewingState(recognised: [], uncertain: [uncertain(id: "u-1")])
        state.apply(.answerUncertain(itemID: "u-1", name: "   "))
        XCTAssertEqual(state.uncertainItems.count, 1, "a blank answer answers nothing")
        XCTAssertTrue(state.sureItems.isEmpty)
    }

    func testNeitherDropsTheRow() {
        var state = reviewingState(recognised: [], uncertain: [uncertain(id: "u-1")])
        state.apply(.rejectUncertain(itemID: "u-1"))
        XCTAssertTrue(state.uncertainItems.isEmpty, "the misread leaves the scan")
        XCTAssertEqual(state.seenCount, 0)
    }

    // MARK: Review edits — duplicates, removal, manual add

    func testDuplicateAnswersSetTheObserveVersusPurchaseAnswer() {
        var state = reviewingState(
            pantryItems: pantry([("greek yogurt", "2")]),
            recognised: [item(id: "r-1", name: "Greek yogurt", quantity: "4")]
        )
        state.apply(.answerDuplicate(itemID: "r-1", stillThere: true))
        XCTAssertEqual(state.sureItems.first?.dedup, .stillThere)
        state.apply(.answerDuplicate(itemID: "r-1", stillThere: false))
        XCTAssertEqual(state.sureItems.first?.dedup, .boughtMore, "the user can change their mind")
    }

    func testDuplicateAnswersAreRefusedForFreshItems() {
        var state = reviewingState(recognised: [item(id: "r-1", name: "Miso paste")])
        state.apply(.answerDuplicate(itemID: "r-1", stillThere: true))
        XCTAssertEqual(state.sureItems.first?.dedup, .pending, "a fresh item has no observe-versus-purchase question")
    }

    func testRemoveItemDropsItFromTheScan() {
        var state = reviewingState(recognised: [item(id: "r-1"), item(id: "r-2", name: "Eggs")])
        state.apply(.removeItem(itemID: "r-1"))
        XCTAssertEqual(state.sureItems.map { $0.id }, ["r-2"])
    }

    func testManualAddTrimsRefusesEmptyAndDefaultsUnknownQuantity() {
        var state = reviewingState(recognised: [])
        state.apply(.addItemManually(name: "  Miso paste  ", quantityDisplay: "  "))
        let added = state.sureItems.first { $0.source == .manual }
        XCTAssertEqual(added?.name, "Miso paste")
        XCTAssertEqual(added?.quantityDisplay, "?", "an unknown amount stays unknown")
        XCTAssertEqual(added?.id, "manual-1", "manual rows get stable ids")

        state.apply(.addItemManually(name: "   ", quantityDisplay: "2"))
        XCTAssertEqual(state.sureItems.count, 1, "a blank name adds nothing")

        state.apply(.addItemManually(name: "Eggs", quantityDisplay: "6"))
        XCTAssertEqual(state.sureItems.count, 2)
        let second = state.sureItems.last
        XCTAssertEqual(second?.id, "manual-2", "ids keep incrementing")
        XCTAssertEqual(second?.quantityDisplay, "6", "a given quantity is kept verbatim")
    }

    func testManualAddClassifiesAgainstThePantry() {
        var state = reviewingState(pantryItems: pantry([("eggs", "6")]))
        state.apply(.addItemManually(name: "EGGS", quantityDisplay: "12"))
        let added = state.sureItems.first { $0.source == .manual }
        XCTAssertEqual(added?.isExisting, true, "manual entry meets the same dedup as recognition")
        XCTAssertEqual(added?.existingQuantityDisplay, "6")
    }

    // MARK: Plate offer

    func testPlateOfferShowsOnlyForPlateRunsAndNeverAutoSwitches() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .shelf, photoCaption: "Shelf"))
        XCTAssertFalse(state.showsPlateOffer, "a shelf run never offers meal logging")

        state.apply(.retake)
        state.apply(.captureTaken(kind: .plate, photoCaption: "Plate"))
        XCTAssertTrue(state.showsPlateOffer)
        XCTAssertEqual(state.stage, .recognizing, "the offer is a question; the scan never auto-switches to meal logging")
    }

    func testPlateOfferAnswersOnce() {
        var state = capturingState()
        state.apply(.captureTaken(kind: .plate, photoCaption: "Plate"))
        state.apply(.answerPlateSwitch(logMeal: true))
        XCTAssertFalse(state.showsPlateOffer, "answered offers never re-ask")
        state.apply(.answerPlateSwitch(logMeal: false))
        XCTAssertTrue(state.plateOfferAnswered, "the first answer stands")
    }

    func testPlateOfferIsRefusedOutsidePlateRuns() {
        var state = reviewingState()
        state.apply(.answerPlateSwitch(logMeal: true))
        XCTAssertFalse(state.plateOfferAnswered)
    }

    // MARK: Commit

    func testConfirmCommitIsIdempotentUnderADoubleTap() {
        var state = reviewingState()
        state.apply(.confirmCommit)
        XCTAssertEqual(state.stage, .saving)
        state.apply(.confirmCommit)
        XCTAssertEqual(state.stage, .saving, "a second tap while saving changes nothing")
    }

    func testConfirmCommitIsRefusedOutsideReview() {
        var state = capturingState()
        state.apply(.confirmCommit)
        XCTAssertEqual(state.stage, .capturing)
    }

    func testCommitSuccessIsTerminalForTheFlow() {
        var state = reviewingState().applied(.confirmCommit)
        state.apply(.commitSucceeded)
        XCTAssertEqual(state.stage, .committed)
        state.apply(.commitSucceeded)
        XCTAssertEqual(state.stage, .committed, "already terminal")
    }

    func testCommitFailureReturnsToReviewWithEverythingIntact() {
        var state = reviewingState(uncertain: [uncertain(id: "u-1")]).applied(.confirmCommit)
        state.apply(.commitFailed)
        XCTAssertEqual(state.stage, .reviewing)
        XCTAssertTrue(state.commitFailed, "the quiet line above the dock names it")
        XCTAssertEqual(state.sureItems.count, 1, "the review keeps everything")
        XCTAssertEqual(state.uncertainItems.count, 1)
    }

    // MARK: Counts — the header's mono numbers

    func testCountsCoverSureRowsAndUnansweredQuestions() {
        var state = reviewingState(
            recognised: [item(id: "r-1"), item(id: "r-2", name: "Eggs"), item(id: "r-3", name: "Miso")],
            uncertain: [uncertain(id: "u-1")]
        )
        XCTAssertEqual(state.seenCount, 4)
        XCTAssertEqual(state.sureCount, 3)
        XCTAssertEqual(state.commitCount, 4, "unanswered questions record too — they never block")
        XCTAssertEqual(state.needsALookCount, 1)

        state.apply(.answerUncertain(itemID: "u-1", name: "Chard"))
        XCTAssertEqual(state.seenCount, 4, "an answer moves a row, it does not change the total")
        XCTAssertEqual(state.sureCount, 4)
        XCTAssertEqual(state.commitCount, 4)
    }

    func testStockAddCountsOnlyRealStockWrites() {
        var state = reviewingState(
            pantryItems: pantry([("greek yogurt", "2"), ("eggs", "6")]),
            recognised: [
                item(id: "r-1", name: "Greek yogurt", quantity: "4"),  // duplicate, pending → observe
                item(id: "r-2", name: "eggs", quantity: "12"),         // duplicate, will be boughtMore
                item(id: "r-3", name: "Miso paste", quantity: "1"),    // fresh → adds
            ]
        )
        state.apply(.answerDuplicate(itemID: "r-2", stillThere: false))
        XCTAssertEqual(state.stockAddCount, 2, "fresh items plus Bought more — not the observe rows")
        state.apply(.answerDuplicate(itemID: "r-1", stillThere: true))
        XCTAssertEqual(state.stockAddCount, 2, "answering Still there adds no stock")
    }

    func testRemovedRowsLeaveEveryCount() {
        var state = reviewingState(recognised: [item(id: "r-1"), item(id: "r-2", name: "Eggs")])
        state.apply(.removeItem(itemID: "r-1"))
        XCTAssertEqual(state.seenCount, 1)
        XCTAssertEqual(state.commitCount, 1)
    }

    // MARK: Display grammar

    func testHeaderCountIsOnlyShownWhileReviewingOrSaving() {
        var state = reviewingState(recognised: [item(), item(id: "r-2", name: "Eggs")])
        XCTAssertEqual(state.headerCountDisplay, "2 seen · 2 sure")

        state.apply(.confirmCommit)
        XCTAssertEqual(state.headerCountDisplay, "2 seen · 2 sure", "the dock shows during saving too")

        var idle = ScanViewState()
        XCTAssertNil(idle.headerCountDisplay)
        var capturing = capturingState()
        XCTAssertNil(capturing.headerCountDisplay)
    }

    func testAllSureReviewGetsTheFoundTitleAndSubtitle() {
        var state = reviewingState(recognised: [item(), item(id: "r-2", name: "Eggs")])
        XCTAssertEqual(state.titleDisplay, "Found 2 things")
        XCTAssertEqual(state.subtitleDisplay, "All look right.")

        // A question arriving in review (host-replayed batch) keeps the
        // header neutral:
        state.uncertainItems.append(uncertain(id: "u-1"))
        XCTAssertEqual(state.titleDisplay, "Scan", "with questions open, the header stays neutral")
        XCTAssertNil(state.subtitleDisplay, "All look right is only said when it is true")
    }

    func testReceiptLinesTravelVerbatim() {
        var state = reviewingState(
            recognised: [item(id: "r-1", name: "Spinach", quantity: "200 g", receiptLine: "ORG SPNCH 200G")]
        )
        XCTAssertEqual(state.sureItems.first?.receiptLine, "ORG SPNCH 200G", "the receipt's own line is shown as-is")
        XCTAssertEqual(state.sureItems.first?.quantityDisplay, "200 g")
    }

    // MARK: Dedup normalisation (shared rules)

    func testNormalisedNameCollapsesWhitespaceAndCase() {
        XCTAssertEqual(ScanViewState.normalizedName("  Greek   yogurt "), "greek yogurt")
        XCTAssertEqual(ScanViewState.normalizedName("GREEK YOGURT"), "greek yogurt")
        XCTAssertTrue(
            ScanViewState.normalizedName("  greek  yogurt ") == ScanViewState.normalizedName("Greek yogurt"))
    }

    func testCloseCaptureResetsToIdleAndKeepsNothing() {
        var state = reviewingState(pantryItems: pantry([("eggs", "6")]))
        state.apply(.closeCapture)
        XCTAssertEqual(state.stage, .idle)
        XCTAssertTrue(state.sureItems.isEmpty)
        XCTAssertEqual(state.pantryItems.count, 1, "the pantry snapshot is the host's, it survives")
    }
}

// Small helper keeping the chained-arrangement tests readable.
private extension ScanViewState {
    func applied(_ intent: ScanIntent) -> ScanViewState {
        var next = self
        next.apply(intent)
        return next
    }
}
