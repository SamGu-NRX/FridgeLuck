import CoreImage
import GRDB
import UIKit
import XCTest

@testable import FridgeLuck

/// Onboarding's kitchen review used to show 14 hard-coded ingredients whatever the photos held,
/// and "Add to My Kitchen" wrote them into the real Kitchen. These pin the replacement: the
/// review shows only what recognition returned for the user's own photos, says so plainly when
/// there were no photos, nothing was found, or photos weren't read, and writes only what the
/// user kept, filed where the photo was taken.
@MainActor
final class OnboardingKitchenReviewTests: XCTestCase {
  private struct ScanFailure: Error {}

  @MainActor
  private final class ScanCounter {
    var count = 0
  }

  private let tomato: Int64 = 1
  private let pepper: Int64 = 2
  private let egg: Int64 = 3

  // MARK: - Review state

  func testSkippingBothPhotoStepsShowsNothingCaptured() {
    let state = OnboardingKitchenReview.state(fridge: .notCaptured, pantry: .notCaptured)

    guard case .nothingCaptured = state else { return XCTFail("got \(state)") }
    XCTAssertTrue(state.detections.isEmpty)
  }

  func testScansThatReadEverythingAndRecognizeNothingShowNothingFound() {
    for (fridge, pantry) in [
      (scanned([]), OnboardingKitchenScanResult.notCaptured),
      (.notCaptured, scanned([])),
      (scanned([]), scanned([])),
    ] {
      let state = OnboardingKitchenReview.state(fridge: fridge, pantry: pantry)
      guard case .nothingFound = state else { return XCTFail("got \(state)") }
    }
  }

  func testUnreadPhotosWithNothingFoundElsewhereAreAnErrorNotAnEmptyResult() {
    for (fridge, pantry) in [
      (OnboardingKitchenScanResult.failed, OnboardingKitchenScanResult.notCaptured),
      (.failed, scanned([])),
      (scanned([]), .failed),
      (.failed, .failed),
      (scanned([], unreadCrops: 2), .notCaptured),
      (scanned([]), scanned([], unreadCrops: 1)),
    ] {
      let state = OnboardingKitchenReview.state(fridge: fridge, pantry: pantry)
      guard case .failed = state else { return XCTFail("got \(state)") }
    }
  }

  func testOneLocationFailingKeepsTheOtherLocationsItemsReviewable() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9)]), pantry: .failed)

    guard case .review(let fridge, let pantry) = state else { return XCTFail("got \(state)") }
    XCTAssertEqual(fridge.detections.map(\.ingredientId), [egg])
    guard case .failed = pantry else { return XCTFail("pantry: \(pantry)") }
    XCTAssertEqual(
      OnboardingKitchenReview.unreadNotice(for: pantry, place: "pantry"),
      "Couldn\u{2019}t read your pantry photos.")
  }

  func testPartlyUnreadPhotosShowTheirItemsWithAWarning() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9)], unreadCrops: 2), pantry: .notCaptured)

    guard case .review(let fridge, _) = state,
      case .items(let items, someUnread: true) = fridge
    else { return XCTFail("got \(state)") }
    XCTAssertEqual(items.map(\.ingredientId), [egg])
    XCTAssertEqual(
      OnboardingKitchenReview.unreadNotice(for: fridge, place: "fridge"),
      "Some fridge photos couldn\u{2019}t be read.")
  }

  /// `passErrors` lists only crops where every request failed. On the simulator classification
  /// always fails while OCR works, which leaves it empty and must not warn.
  func testFullyReadPhotosShowNoWarning() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9)]), pantry: .notCaptured)

    guard case .review(let fridge, _) = state else { return XCTFail("got \(state)") }
    XCTAssertNil(OnboardingKitchenReview.unreadNotice(for: fridge, place: "fridge"))
  }

  func testALocationThatFoundNothingSaysSoNextToTheOther() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9)]), pantry: scanned([]))

    guard case .review(_, let pantry) = state else { return XCTFail("got \(state)") }
    guard case .nothingFound = pantry else { return XCTFail("pantry: \(pantry)") }
  }

  // MARK: - Sections

  func testIngredientFoundInBothPhotosIsListedOnceWhereItScoredHigher() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.6)]),
      pantry: scanned([detection(egg, 0.9), detection(tomato, 0.85)])
    )

    guard case .review(let fridge, let pantry) = state else { return XCTFail("got \(state)") }
    // The fridge did recognize something, so it is hidden rather than labeled "nothing found".
    guard case .items(let fridgeItems, someUnread: false) = fridge else {
      return XCTFail("fridge: \(fridge)")
    }
    XCTAssertTrue(fridgeItems.isEmpty)
    XCTAssertEqual(pantry.detections.map(\.ingredientId), [egg, tomato])
    XCTAssertEqual(pantry.detections.first?.confidence, 0.9)
  }

  func testAScoreTieKeepsTheIngredientInTheFridge() {
    let split = OnboardingKitchenReview.sections(
      fridge: [detection(egg, 0.7)], pantry: [detection(egg, 0.7)])

    XCTAssertEqual(split.fridge.map(\.ingredientId), [egg])
    XCTAssertTrue(split.pantry.isEmpty)
  }

  func testSectionsListSureItemsBeforeUncertainThenPossible() {
    let split = OnboardingKitchenReview.sections(
      fridge: [detection(tomato, 0.2), detection(pepper, 0.6), detection(egg, 0.95)],
      pantry: []
    )

    XCTAssertEqual(split.fridge.map(\.ingredientId), [egg, pepper, tomato])
  }

  // MARK: - Choices

  func testOnlyItemsTheRouterIsSureOfStartSelected() {
    let sure = detection(egg, ConfidenceRouter.Thresholds.visionAuto)
    let uncertain = detection(pepper, ConfidenceRouter.Thresholds.visionConfirmMin)
    let possible = detection(tomato, ConfidenceRouter.Thresholds.visionConfirmMin - 0.01)
    var choices = OnboardingKitchenChoices()

    choices.noteShown([sure, uncertain, possible])

    XCTAssertEqual(choices.selectedIDs(in: [sure, uncertain, possible]), [egg])
  }

  func testAnItemFirstShownAsUncertainIsNotCheckedWhenItReturnsAsSure() {
    var choices = OnboardingKitchenChoices()
    choices.noteShown([detection(pepper, 0.6)])

    choices.noteShown([detection(pepper, 0.95)])

    XCTAssertFalse(choices.isSelected(pepper))
  }

  /// Uncheck a sure item and check an uncertain one; new photos then fail to scan, and a retry
  /// succeeds. Both choices must survive the scan that showed neither item.
  func testExplicitChoicesSurviveAFailedScanAndRetry() async {
    var choices = OnboardingKitchenChoices()
    let fridgePhotos = [photo(.camera)]
    let first = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: [], previous: nil, retryFailed: false
    ) { _ in
      self.scanResult(self.detection(self.egg, 0.95), self.detection(self.pepper, 0.6))
    }
    choices.noteShown(first?.reviewState.detections ?? [])
    choices.toggle(egg)
    choices.toggle(pepper)

    let pantryPhotos = [photo(.photoLibrary)]
    let failed = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: first, retryFailed: false
    ) { inputs in
      guard inputs.first?.source == .photoLibrary else { throw ScanFailure() }
      return self.scanResult(self.detection(self.tomato, 0.9))
    }
    choices.noteShown(failed?.reviewState.detections ?? [])
    XCTAssertEqual(failed?.reviewState.detections.map(\.ingredientId), [tomato])

    let retried = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: failed, retryFailed: true
    ) { _ in
      self.scanResult(self.detection(self.egg, 0.95), self.detection(self.pepper, 0.6))
    }
    let shown = retried?.reviewState.detections ?? []
    choices.noteShown(shown)

    XCTAssertEqual(choices.selectedIDs(in: shown), [pepper, tomato])
  }

  // MARK: - Photos and scan inputs

  func testScanInputsKeepEachPhotosSourceAndOrder() {
    let photos = [photo(.camera), photo(.photoLibrary)]

    let inputs = OnboardingKitchenReview.scanInputs(for: photos)

    XCTAssertEqual(inputs.map(\.source), [.camera, .photoLibrary])
    XCTAssertEqual(inputs.map(\.captureIndex), [0, 1])
  }

  // MARK: - Scanner

  func testFridgeAndPantryPhotosAreScannedSeparately() async {
    var calls: [[ScanInputSource]] = []

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [photo(.camera), photo(.camera)], pantryPhotos: [photo(.photoLibrary)],
      previous: nil, retryFailed: false
    ) { inputs in
      calls.append(inputs.map(\.source))
      return calls.count == 1
        ? self.scanResult(self.detection(self.egg, 0.9))
        : self.scanResult(self.detection(self.tomato, 0.9))
    }

    XCTAssertEqual(calls, [[.camera, .camera], [.photoLibrary]])
    guard case .review(let fridge, let pantry) = session?.reviewState else {
      return XCTFail("got \(String(describing: session?.reviewState))")
    }
    XCTAssertEqual(fridge.detections.map(\.ingredientId), [egg])
    XCTAssertEqual(pantry.detections.map(\.ingredientId), [tomato])
  }

  func testSkippedLocationIsNotScanned() async {
    var callCount = 0

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [], pantryPhotos: [photo(.camera)], previous: nil, retryFailed: false
    ) { _ in
      callCount += 1
      return self.scanResult()
    }

    XCTAssertEqual(callCount, 1)
    guard case .notCaptured = session?.fridge else { return XCTFail("fridge scanned") }
  }

  func testAThrowingScanIsRecordedAsFailedNotEmpty() async {
    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [photo(.camera)], pantryPhotos: [], previous: nil, retryFailed: false
    ) { _ in
      throw ScanFailure()
    }

    guard case .failed = session?.reviewState else {
      return XCTFail("got \(String(describing: session?.reviewState))")
    }
  }

  func testPhotosThatCannotBecomeScanInputFailWithoutScanning() async {
    let unreadable = FLCapturedPhoto(
      image: UIImage(
        ciImage: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))),
      source: .camera
    )
    var callCount = 0

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [unreadable], pantryPhotos: [], previous: nil, retryFailed: false
    ) { _ in
      callCount += 1
      return self.scanResult()
    }

    XCTAssertEqual(callCount, 0)
    guard case .failed = session?.fridge else { return XCTFail("expected failed") }
  }

  func testReturningToTheSamePhotosDoesNotRescan() async {
    let fridgePhotos = [photo(.camera)]
    let previous = session(fridgePhotos: fridgePhotos, fridge: scanned([detection(egg, 0.9)]))
    var callCount = 0

    for retry in [false, true] {
      let session = await OnboardingKitchenScanner.run(
        fridgePhotos: fridgePhotos, pantryPhotos: [], previous: previous, retryFailed: retry
      ) { _ in
        callCount += 1
        return self.scanResult()
      }
      XCTAssertNil(session)
    }
    XCTAssertEqual(callCount, 0)
  }

  func testChangedPhotosAreScannedAgain() async {
    let previous = session(
      fridgePhotos: [photo(.camera)], fridge: scanned([detection(egg, 0.9)]))
    var callCount = 0

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [photo(.camera)], pantryPhotos: [], previous: previous, retryFailed: false
    ) { _ in
      callCount += 1
      return self.scanResult()
    }

    XCTAssertEqual(callCount, 1)
    guard case .nothingFound = session?.reviewState else { return XCTFail("stale result kept") }
  }

  func testRetryRescansOnlyLocationsWithUnreadPhotos() async {
    let fridgePhotos = [photo(.camera)]
    let pantryPhotos = [photo(.photoLibrary)]
    let previous = session(
      fridgePhotos: fridgePhotos, fridge: scanned([detection(egg, 0.9)], unreadCrops: 1),
      pantryPhotos: pantryPhotos, pantry: .failed)
    var calls: [[ScanInputSource]] = []

    let skipped = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: previous,
      retryFailed: false
    ) { inputs in
      calls.append(inputs.map(\.source))
      return self.scanResult()
    }
    XCTAssertNil(skipped, "unread photos are rescanned only when the user asks")

    let retried = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: previous,
      retryFailed: true
    ) { inputs in
      calls.append(inputs.map(\.source))
      return self.scanResult(self.detection(self.tomato, 0.9))
    }

    XCTAssertEqual(calls, [[.camera], [.photoLibrary]])
    XCTAssertEqual(retried?.reviewState.detections.map(\.ingredientId), [tomato])
  }

  func testRetryLeavesACompletelyReadLocationAlone() async {
    let fridgePhotos = [photo(.camera)]
    let pantryPhotos = [photo(.photoLibrary)]
    let previous = session(
      fridgePhotos: fridgePhotos, fridge: scanned([detection(egg, 0.9)]),
      pantryPhotos: pantryPhotos, pantry: .failed)
    var calls: [[ScanInputSource]] = []

    let retried = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: previous,
      retryFailed: true
    ) { inputs in
      calls.append(inputs.map(\.source))
      return self.scanResult(self.detection(self.tomato, 0.9))
    }

    XCTAssertEqual(calls, [[.photoLibrary]])
    XCTAssertEqual(
      retried?.reviewState.detections.map(\.ingredientId).sorted(), [tomato, egg])
  }

  func testACancelledRunStartsNoScanAndPublishesNothing() async {
    let scans = ScanCounter()
    let task = Task { @MainActor in
      await OnboardingKitchenScanner.run(
        fridgePhotos: [self.photo(.camera)], pantryPhotos: [self.photo(.camera)],
        previous: nil, retryFailed: false
      ) { _ in
        scans.count += 1
        return self.scanResult(self.detection(self.egg, 0.9))
      }
    }
    task.cancel()

    let session = await task.value

    XCTAssertNil(session)
    XCTAssertEqual(scans.count, 0)
  }

  func testCancellingDuringTheFridgeScanSkipsThePantry() async {
    let scans = ScanCounter()
    let task = Task { @MainActor in
      await OnboardingKitchenScanner.run(
        fridgePhotos: [self.photo(.camera)], pantryPhotos: [self.photo(.photoLibrary)],
        previous: nil, retryFailed: false
      ) { _ in
        scans.count += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return self.scanResult(self.detection(self.egg, 0.9))
      }
    }

    let session = await task.value

    XCTAssertNil(session)
    XCTAssertEqual(scans.count, 1)
  }

  // MARK: - Into the Kitchen (OnboardingView.commitKitchenInventory's path)

  func testLotsAreFiledWhereThePhotoWasTaken() throws {
    var run = try OnboardingRun()

    try run.confirm(
      session(fridge: scanned([detection(egg, 0.95)]), pantry: scanned([detection(tomato, 0.95)])))

    XCTAssertEqual(try lotLocations(run.db), [egg: "fridge", tomato: "pantry"])
  }

  func testOnlyVisibleItemsTheUserKeptReachTheKitchen() throws {
    var run = try OnboardingRun()

    try run.confirm(session(fridge: scanned([detection(egg, 0.95), detection(pepper, 0.6)])))

    XCTAssertEqual(try run.activeIngredientIDs(), [egg])
  }

  func testRevisitingAndAddingAgainStoresOneCopy() throws {
    var run = try OnboardingRun()
    let visit = session(fridge: scanned([detection(egg, 0.95)]))

    try run.confirm(visit)
    try run.confirm(visit)

    XCTAssertEqual(try lotCount(run.db), 1)
  }

  /// The egg scores higher in the pantry on a rescan, so the review moves it there. It is the
  /// same food: one lot, still where it was first filed.
  func testItemMovingToTheOtherSectionKeepsItsOneLot() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.9)])))

    try run.confirm(movedEggVisit())

    XCTAssertEqual(try lotCount(run.db), 1)
    XCTAssertEqual(try lotLocations(run.db), [egg: "fridge"])
  }

  func testItemMovingAfterSomeWasCookedAddsNoFreshEstimate() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.9)])))
    try cook(egg, grams: 25, db: run.db)
    let remainingAfterCooking = try remainingGrams(run.db)

    try run.confirm(movedEggVisit())

    XCTAssertEqual(try lotCount(run.db), 1)
    XCTAssertEqual(try remainingGrams(run.db), remainingAfterCooking)
    XCTAssertLessThan(
      remainingAfterCooking, InventoryIntakeService.estimateGrams(forName: "item \(egg)"))
  }

  func testItemMovingAfterAllOfItWasCookedIsNotAddedBack() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.9)])))
    try cook(egg, grams: 10_000, db: run.db)

    try run.confirm(movedEggVisit())

    XCTAssertEqual(try lotCount(run.db), 1)
    XCTAssertEqual(try run.activeIngredientIDs(), [])
  }

  func testAFailedFridgeScanKeepsWhatAnEarlierVisitAdded() throws {
    var run = try OnboardingRun()
    try run.confirm(
      session(fridge: scanned([detection(egg, 0.95)]), pantry: scanned([detection(tomato, 0.95)])))

    try run.confirm(session(fridge: .failed, pantry: scanned([detection(tomato, 0.95)])))

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato, egg])
  }

  func testPartlyUnreadFridgeKeepsAnEarlierItemItNoLongerShows() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.95)])))

    try run.confirm(session(fridge: scanned([detection(tomato, 0.95)], unreadCrops: 1)))

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato, egg])
  }

  func testPartlyUnreadFridgeRetiresAnEarlierItemTheUserUnchecked() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.95)])))
    // Seen again and unchecked, then the user went back for new photos instead of confirming.
    run.show(session(fridge: scanned([detection(egg, 0.95)])), toggling: [egg])

    try run.confirm(session(fridge: scanned([detection(tomato, 0.95)], unreadCrops: 1)))

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato])
  }

  func testRemovingAllFridgePhotosKeepsWhatTheFridgeAdded() throws {
    var run = try OnboardingRun()
    try run.confirm(
      session(fridge: scanned([detection(egg, 0.95)]), pantry: scanned([detection(tomato, 0.95)])))

    try run.confirm(session(fridge: .notCaptured, pantry: scanned([detection(tomato, 0.95)])))

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato, egg])
  }

  func testRemovingFridgePhotosStillRetiresAnEggTheUserUnchecked() throws {
    var run = try OnboardingRun()
    let firstVisit = session(
      fridge: scanned([detection(egg, 0.95)]), pantry: scanned([detection(tomato, 0.95)]))
    try run.confirm(firstVisit)
    run.show(firstVisit, toggling: [egg])

    try run.confirm(session(fridge: .notCaptured, pantry: scanned([detection(tomato, 0.95)])))

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato])
  }

  func testFullyReadPhotosRetireAnEarlierItemTheyNoLongerShow() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.95)])))

    try run.confirm(session(fridge: scanned([detection(tomato, 0.95)])))

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato])
  }

  func testShownAndUncheckedIsRetired() throws {
    var run = try OnboardingRun()
    let visit = session(fridge: scanned([detection(egg, 0.95)]))
    try run.confirm(visit)

    try run.confirm(visit, toggling: [egg])

    XCTAssertEqual(try run.activeIngredientIDs(), [])
  }

  func testContinuingWithoutAddingLeavesTheUnreadSectionAlone() throws {
    var run = try OnboardingRun()
    try run.confirm(
      session(fridge: scanned([detection(egg, 0.95)]), pantry: scanned([detection(tomato, 0.95)])))

    try run.confirm(
      session(fridge: scanned([detection(egg, 0.95)]), pantry: .failed), toggling: [egg])

    XCTAssertEqual(try run.activeIngredientIDs(), [tomato])
  }

  /// Unchecking the egg retires its lot before the unknown ingredient's lot fails its foreign
  /// key, so a partial write would leave the egg retired.
  func testAFailedSaveChangesNothing() throws {
    var run = try OnboardingRun()
    try run.confirm(session(fridge: scanned([detection(egg, 0.95)])))
    let recordBefore = run.record.sectionByIngredient

    XCTAssertThrowsError(
      try run.confirm(
        session(fridge: scanned([detection(egg, 0.95), detection(999, 0.95)])),
        toggling: [egg]))

    XCTAssertEqual(try run.activeIngredientIDs(), [egg])
    XCTAssertEqual(try lotCount(run.db), 1)
    XCTAssertEqual(run.record.sectionByIngredient, recordBefore)
  }

  // MARK: - Announcements and navigation

  func testAnnouncementStatesWhatTheScanFound() {
    let partial = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.95)]), pantry: .failed)

    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: partial, selectedCount: 1),
      "Found 1 ingredient, 1 selected. Couldn\u{2019}t read your pantry photos.")
    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: .nothingFound, selectedCount: 0),
      "No ingredients found in these photos.")
    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: .failed, selectedCount: 0),
      "Couldn\u{2019}t read your photos. Try again, or continue.")
  }

  /// The setup bridge replays and moves on by itself, so stepping back onto it from the final
  /// step made the kitchen review unreachable.
  func testBackFromTheFinalStepReturnsToTheKitchenReview() {
    XCTAssertEqual(OnboardingStep.handoff.backStep, .kitchenReview)
    XCTAssertEqual(OnboardingStep.setupBridge.backStep, .kitchenReview)
    XCTAssertEqual(OnboardingStep.name.backStep, .welcome)
    XCTAssertNil(OnboardingStep.welcome.backStep)
  }

  // MARK: - Helpers

  private func detection(_ ingredientID: Int64, _ confidence: Float) -> Detection {
    Detection(
      ingredientId: ingredientID, label: "item \(ingredientID)", confidence: confidence,
      source: .vision, originalVisionLabel: "item_\(ingredientID)")
  }

  /// `unreadCrops` crops where every recognition request failed, as `VisionService` reports.
  private func scanned(
    _ detections: [Detection], unreadCrops: Int = 0
  ) -> OnboardingKitchenScanResult {
    .scanned(scanResult(detections, unreadCrops: unreadCrops))
  }

  private func scanResult(_ detections: Detection...) -> VisionService.ScanResult {
    scanResult(detections, unreadCrops: 0)
  }

  private func scanResult(
    _ detections: [Detection], unreadCrops: Int
  ) -> VisionService.ScanResult {
    VisionService.ScanResult(
      detections: detections,
      ocrText: [],
      diagnostics: ScanDiagnostics(
        captureCount: 1, cropCount: 6, topRawLabels: [], ocrCandidates: [],
        bucketCounts: ScanBucketCounts(auto: 0, confirm: 0, possible: 0),
        passErrors: Array(repeating: "class=failed,ocr=failed", count: unreadCrops),
        elapsedMs: 0
      ),
      provenance: .realScan
    )
  }

  private func session(
    fridgePhotos: [FLCapturedPhoto] = [],
    fridge: OnboardingKitchenScanResult = .notCaptured,
    pantryPhotos: [FLCapturedPhoto] = [],
    pantry: OnboardingKitchenScanResult = .notCaptured
  ) -> OnboardingKitchenScanSession {
    OnboardingKitchenScanSession(
      fridgePhotoIDs: fridgePhotos.map(\.id), pantryPhotoIDs: pantryPhotos.map(\.id),
      fridge: fridge, pantry: pantry)
  }

  /// A fridge scan that scores the egg lower than a pantry scan, so the review lists it under
  /// the pantry.
  private func movedEggVisit() -> OnboardingKitchenScanSession {
    session(fridge: scanned([detection(egg, 0.6)]), pantry: scanned([detection(egg, 0.9)]))
  }

  /// One onboarding run against a real database. Choices and the commit record carry across
  /// visits, as `OnboardingView` keeps them.
  private struct OnboardingRun {
    let db: DatabaseQueue
    let intake: InventoryIntakeService
    let inventory: InventoryRepository
    var choices = OnboardingKitchenChoices()
    var record = OnboardingKitchenCommitRecord()

    init() throws {
      db = try DatabaseQueue()
      try DatabaseMigrations.migrate(db)
      try db.write { db in
        try db.execute(
          sql: """
            INSERT INTO ingredients (id, name, calories, protein, carbs, fat, typical_unit) VALUES
              (1, 'tomato', 0.18, 0.01, 0.04, 0, '1 medium (120g)'),
              (2, 'bell_pepper', 0.2, 0.01, 0.05, 0, '1 medium (120g)'),
              (3, 'egg', 1.4, 0.13, 0.01, 0.1, '1 large (50g)')
            """
        )
      }
      inventory = InventoryRepository(db: db)
      intake = InventoryIntakeService(
        ingredientRepository: IngredientRepository(db: db), inventoryRepository: inventory)
    }

    /// The review shows `session` and the user taps `toggling`, without confirming.
    mutating func show(_ session: OnboardingKitchenScanSession, toggling: [Int64] = []) {
      choices.noteShown(session.reviewState.detections)
      for ingredientID in toggling { choices.toggle(ingredientID) }
    }

    /// As `show`, then "Add to My Kitchen" (or "Continue Without Adding").
    mutating func confirm(
      _ session: OnboardingKitchenScanSession, toggling: [Int64] = []
    ) throws {
      show(session, toggling: toggling)
      record = try OnboardingKitchenIntake.commit(
        session: session, choices: choices, record: record,
        sourceRef: "onboarding-kitchen-review:test", intake: intake)
    }

    func activeIngredientIDs() throws -> [Int64] {
      try inventory.fetchAllActiveItems().map(\.ingredientId).sorted()
    }
  }

  /// Cooks through the real consumption path so consume events exist, as after a meal.
  private func cook(_ ingredientID: Int64, grams: Double, db: DatabaseQueue) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO recipes (id, title, time_minutes, servings, instructions)
          VALUES (100, 'Test Dish', 5, 1, 'Cook.');
          DELETE FROM recipe_ingredients WHERE recipe_id = 100;
          INSERT INTO recipe_ingredients
            (recipe_id, ingredient_id, is_required, quantity_grams, display_quantity)
          VALUES (100, ?, 1, ?, 'some');
          """,
        arguments: [ingredientID, grams]
      )
    }
    _ = try InventoryRepository(db: db).applyConsumption(recipeId: 100, servingsConsumed: 1)
  }

  private func lotCount(_ db: DatabaseQueue) throws -> Int {
    try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM inventory_lots") ?? 0 }
  }

  private func remainingGrams(_ db: DatabaseQueue) throws -> Double {
    try db.read {
      try Double.fetchOne($0, sql: "SELECT SUM(remaining_grams) FROM inventory_lots") ?? 0
    }
  }

  private func photo(_ source: ScanInputSource) -> FLCapturedPhoto {
    FLCapturedPhoto(image: drawnImage(), source: source)
  }

  private func drawnImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.systemGreen.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
  }

  private func lotLocations(_ db: DatabaseQueue) throws -> [Int64: String] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT ingredient_id, storage_location FROM inventory_lots")
      return Dictionary(
        uniqueKeysWithValues: rows.map {
          ($0["ingredient_id"] as Int64, $0["storage_location"] as String)
        })
    }
  }
}
