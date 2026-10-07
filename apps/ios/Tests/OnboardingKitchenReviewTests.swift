import CoreImage
import GRDB
import UIKit
import XCTest

@testable import FridgeLuck

/// Onboarding's kitchen review used to show 14 hard-coded ingredients whatever the photos held,
/// and "Add to My Kitchen" wrote them into the real Kitchen. These pin the replacement: the
/// review shows only what recognition returned for the user's own photos, and says so plainly
/// when there were no photos, nothing was found, or the scan failed.
@MainActor
final class OnboardingKitchenReviewTests: XCTestCase {
  private let tomato: Int64 = 1
  private let pepper: Int64 = 2
  private let egg: Int64 = 3

  // MARK: - Review state

  func testSkippingBothPhotoStepsShowsNothingCaptured() {
    let state = OnboardingKitchenReview.state(fridge: .notCaptured, pantry: .notCaptured)

    guard case .nothingCaptured = state else { return XCTFail("got \(state)") }
    XCTAssertTrue(state.detections.isEmpty)
  }

  func testScansThatRecognizeNothingShowNothingFound() {
    for (fridge, pantry) in [
      (OnboardingKitchenScanResult.scanned([]), OnboardingKitchenScanResult.notCaptured),
      (.notCaptured, .scanned([])),
      (.scanned([]), .scanned([])),
    ] {
      let state = OnboardingKitchenReview.state(fridge: fridge, pantry: pantry)
      guard case .nothingFound = state else { return XCTFail("got \(state)") }
    }
  }

  func testAFailedScanWithNothingFoundElsewhereIsAnErrorNotAnEmptyResult() {
    for (fridge, pantry) in [
      (OnboardingKitchenScanResult.failed, OnboardingKitchenScanResult.notCaptured),
      (.failed, .scanned([])),
      (.scanned([]), .failed),
      (.failed, .failed),
    ] {
      let state = OnboardingKitchenReview.state(fridge: fridge, pantry: pantry)
      guard case .failed = state else { return XCTFail("got \(state)") }
    }
  }

  func testOneLocationFailingKeepsTheOtherLocationsItemsReviewable() {
    let state = OnboardingKitchenReview.state(
      fridge: .scanned([detection(egg, 0.9)]), pantry: .failed)

    guard case .review(let fridge, let pantry) = state else { return XCTFail("got \(state)") }
    XCTAssertEqual(fridge.detections.map(\.ingredientId), [egg])
    guard case .failed = pantry else { return XCTFail("pantry: \(pantry)") }
  }

  func testALocationThatFoundNothingSaysSoNextToTheOther() {
    let state = OnboardingKitchenReview.state(
      fridge: .scanned([detection(egg, 0.9)]), pantry: .scanned([]))

    guard case .review(_, let pantry) = state else { return XCTFail("got \(state)") }
    guard case .nothingFound = pantry else { return XCTFail("pantry: \(pantry)") }
  }

  // MARK: - Sections

  func testIngredientFoundInBothPhotosIsListedOnceWhereItScoredHigher() {
    let state = OnboardingKitchenReview.state(
      fridge: .scanned([detection(egg, 0.6)]),
      pantry: .scanned([detection(egg, 0.9), detection(tomato, 0.85)])
    )

    guard case .review(let fridge, let pantry) = state else { return XCTFail("got \(state)") }
    // The fridge did recognize something, so it is hidden rather than labeled "nothing found".
    guard case .items(let fridgeItems) = fridge else { return XCTFail("fridge: \(fridge)") }
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

  // MARK: - Selection

  func testOnlyItemsTheRouterIsSureOfStartSelected() {
    let sure = detection(egg, ConfidenceRouter.Thresholds.visionAuto)
    let uncertain = detection(pepper, ConfidenceRouter.Thresholds.visionConfirmMin)
    let possible = detection(tomato, ConfidenceRouter.Thresholds.visionConfirmMin - 0.01)

    XCTAssertEqual(
      OnboardingKitchenReview.selection(for: [sure, uncertain, possible]), [egg])
  }

  func testRescanKeepsTheUsersChoicesForItemsAlreadyReviewed() {
    let reviewed = [detection(egg, 0.95), detection(pepper, 0.6)]
    // The user unchecked the egg and checked the pepper; a retried pantry scan then finds the
    // egg again with a high score, and a new sure tomato.
    let rescanned = reviewed + [detection(tomato, 0.9)]

    let selection = OnboardingKitchenReview.selection(
      for: rescanned, keeping: [pepper], reviewed: reviewed)

    XCTAssertEqual(selection, [pepper, tomato])
  }

  func testSelectionDropsIngredientsNoLongerShown() {
    let selection = OnboardingKitchenReview.selection(
      for: [detection(egg, 0.6)], keeping: [egg, tomato], reviewed: [detection(egg, 0.6)])

    XCTAssertEqual(selection, [egg])
  }

  // MARK: - Photos and scan inputs

  func testScanInputsKeepEachPhotosSourceAndOrder() {
    let photos = [
      FLCapturedPhoto(image: drawnImage(), source: .camera),
      FLCapturedPhoto(image: drawnImage(), source: .photoLibrary),
    ]

    let inputs = OnboardingKitchenReview.scanInputs(for: photos)

    XCTAssertEqual(inputs.map(\.source), [.camera, .photoLibrary])
    XCTAssertEqual(inputs.map(\.captureIndex), [0, 1])
  }

  // MARK: - Scanner

  func testFridgeAndPantryPhotosAreScannedSeparately() async {
    let fridgePhotos = [photo(.camera), photo(.camera)]
    let pantryPhotos = [photo(.photoLibrary)]
    var calls: [[ScanInputSource]] = []

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: nil, retryFailed: false
    ) { inputs in
      calls.append(inputs.map(\.source))
      return calls.count == 1 ? [self.detection(self.egg, 0.9)] : [self.detection(self.tomato, 0.9)]
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
      return []
    }

    XCTAssertEqual(callCount, 1)
    guard case .notCaptured = session?.fridge else { return XCTFail("fridge scanned") }
  }

  func testAThrowingScanIsRecordedAsFailedNotEmpty() async {
    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [photo(.camera)], pantryPhotos: [], previous: nil, retryFailed: false
    ) { _ in
      throw VisionService.VisionServiceError.pipelineFailed(
        classificationError: nil, ocrError: nil)
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
      return []
    }

    XCTAssertEqual(callCount, 0)
    guard case .failed = session?.fridge else { return XCTFail("expected failed") }
  }

  func testReturningToTheSamePhotosDoesNotRescan() async {
    let fridgePhotos = [photo(.camera)]
    let previous = OnboardingKitchenScanSession(
      fridgePhotoIDs: fridgePhotos.map(\.id), pantryPhotoIDs: [],
      fridge: .scanned([detection(egg, 0.9)]), pantry: .notCaptured)
    var callCount = 0

    for retry in [false, true] {
      let session = await OnboardingKitchenScanner.run(
        fridgePhotos: fridgePhotos, pantryPhotos: [], previous: previous, retryFailed: retry
      ) { _ in
        callCount += 1
        return []
      }
      XCTAssertNil(session)
    }
    XCTAssertEqual(callCount, 0)
  }

  func testChangedPhotosAreScannedAgain() async {
    let previous = OnboardingKitchenScanSession(
      fridgePhotoIDs: [UUID()], pantryPhotoIDs: [],
      fridge: .scanned([detection(egg, 0.9)]), pantry: .notCaptured)
    var callCount = 0

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [photo(.camera)], pantryPhotos: [], previous: previous, retryFailed: false
    ) { _ in
      callCount += 1
      return []
    }

    XCTAssertEqual(callCount, 1)
    guard case .nothingFound = session?.reviewState else { return XCTFail("stale result kept") }
  }

  func testRetryRescansOnlyTheFailedLocation() async {
    let fridgePhotos = [photo(.camera)]
    let pantryPhotos = [photo(.photoLibrary)]
    let previous = OnboardingKitchenScanSession(
      fridgePhotoIDs: fridgePhotos.map(\.id), pantryPhotoIDs: pantryPhotos.map(\.id),
      fridge: .scanned([detection(egg, 0.9)]), pantry: .failed)
    var calls: [[ScanInputSource]] = []

    let skipped = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: previous,
      retryFailed: false
    ) { inputs in
      calls.append(inputs.map(\.source))
      return []
    }
    XCTAssertNil(skipped, "a failure is retried only when the user asks")

    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: previous,
      retryFailed: true
    ) { inputs in
      calls.append(inputs.map(\.source))
      return [self.detection(self.tomato, 0.9)]
    }

    XCTAssertEqual(calls, [[.photoLibrary]])
    XCTAssertEqual(session?.reviewState.detections.map(\.ingredientId).sorted(), [tomato, egg])
  }

  // MARK: - What the review step runs

  /// Uncheck a sure item and check an uncertain one, go back, add a pantry photo, return: the
  /// rescan must not re-check the first or clear the second.
  func testChangingPhotosKeepsChoicesForIngredientsAlreadyShown() async {
    let fridgePhoto = photo(.camera)
    let previous = OnboardingKitchenScanSession(
      fridgePhotoIDs: [fridgePhoto.id], pantryPhotoIDs: [],
      fridge: .scanned([detection(egg, 0.95), detection(pepper, 0.6)]), pantry: .notCaptured)
    let userSelection: Set<Int64> = [pepper]

    let update = await OnboardingKitchenScanner.update(
      fridgePhotos: [fridgePhoto], pantryPhotos: [photo(.photoLibrary)], previous: previous,
      selection: userSelection, retryFailed: false
    ) { inputs in
      inputs.first?.source == .camera
        ? [self.detection(self.egg, 0.95), self.detection(self.pepper, 0.6)]
        : [self.detection(self.tomato, 0.9)]
    }

    XCTAssertEqual(update?.selection, [pepper, tomato])
    XCTAssertEqual(update?.session.reviewState.detections.count, 3)
  }

  func testFirstScanChecksOnlySureItems() async {
    let update = await OnboardingKitchenScanner.update(
      fridgePhotos: [photo(.camera)], pantryPhotos: [], previous: nil, selection: [],
      retryFailed: false
    ) { _ in
      [self.detection(self.egg, 0.95), self.detection(self.pepper, 0.6)]
    }

    XCTAssertEqual(update?.selection, [egg])
  }

  func testRetryKeepsChoicesInTheLocationThatAlreadyScanned() async {
    let fridgePhotos = [photo(.camera)]
    let pantryPhotos = [photo(.photoLibrary)]
    let previous = OnboardingKitchenScanSession(
      fridgePhotoIDs: fridgePhotos.map(\.id), pantryPhotoIDs: pantryPhotos.map(\.id),
      fridge: .scanned([detection(egg, 0.95)]), pantry: .failed)

    let update = await OnboardingKitchenScanner.update(
      fridgePhotos: fridgePhotos, pantryPhotos: pantryPhotos, previous: previous,
      selection: [], retryFailed: true
    ) { _ in
      [self.detection(self.tomato, 0.9)]
    }

    XCTAssertEqual(update?.selection, [tomato], "the unchecked egg stays unchecked")
  }

  // MARK: - Announcements

  func testAnnouncementStatesWhatTheScanFound() {
    let partial = OnboardingKitchenReview.state(
      fridge: .scanned([detection(egg, 0.95)]), pantry: .failed)

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

  // MARK: - Into the Kitchen

  func testOnlyRecognizedItemsTheUserKeptReachTheKitchen() async throws {
    let (intake, inventory) = try makeIntake()
    let session = await OnboardingKitchenScanner.run(
      fridgePhotos: [photo(.camera)], pantryPhotos: [], previous: nil, retryFailed: false
    ) { _ in
      [self.detection(self.egg, 0.95), self.detection(self.pepper, 0.6)]
    }
    let reviewed = try XCTUnwrap(session).reviewState.detections
    let selection = OnboardingKitchenReview.selection(for: reviewed)

    try intake.ingestConfirmedScan(
      detections: reviewed, confirmedIngredientIDs: selection,
      selectedIngredientByDetection: [:], sourceRef: "onboarding-kitchen-review:test")

    XCTAssertEqual(try inventory.fetchAllActiveItems().map(\.ingredientId), [egg])
  }

  // MARK: - Helpers

  private func detection(_ ingredientID: Int64, _ confidence: Float) -> Detection {
    Detection(
      ingredientId: ingredientID, label: "item \(ingredientID)", confidence: confidence,
      source: .vision, originalVisionLabel: "item_\(ingredientID)")
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

  private func makeIntake() throws -> (InventoryIntakeService, InventoryRepository) {
    let db = try DatabaseQueue()
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
    let inventory = InventoryRepository(db: db)
    let intake = InventoryIntakeService(
      ingredientRepository: IngredientRepository(db: db), inventoryRepository: inventory)
    return (intake, inventory)
  }
}
