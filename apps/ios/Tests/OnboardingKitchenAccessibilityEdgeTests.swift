import XCTest

@testable import FridgeLuck

/// Edge cases of the kitchen review's VoiceOver strings: the singular and plural noun, a zero
/// selected count, and which warnings fire when photos weren't read. Wording is pinned exactly
/// because VoiceOver reads it aloud — a wording change is a behavior change for those users.
final class OnboardingKitchenAccessibilityEdgeTests: XCTestCase {
  private let pepper: Int64 = 2
  private let egg: Int64 = 3

  // MARK: - Announcements

  func testNothingCapturedAnnouncesThatThereAreNoPhotos() {
    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: .nothingCaptured, selectedCount: 0),
      "No photos to scan.")
  }

  func testAnnouncementAppendsBothUnreadNoticesWithTheFridgeFirst() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9)], unreadCrops: 1),
      pantry: scanned([detection(pepper, 0.9)], unreadCrops: 1)
    )

    let message = OnboardingKitchenReview.announcement(for: state, selectedCount: 1)
    XCTAssertEqual(
      message,
      "Found 2 ingredients, 1 selected. Some fridge photos couldn\u{2019}t be read."
        + " Some pantry photos couldn\u{2019}t be read.")
    guard
      let fridgeNotice = message.range(of: "Some fridge photos couldn\u{2019}t be read."),
      let pantryNotice = message.range(of: "Some pantry photos couldn\u{2019}t be read.")
    else { return XCTFail("message: \(message)") }
    XCTAssertLessThan(fridgeNotice.lowerBound, pantryNotice.lowerBound)
  }

  func testAnnouncementUsesTheSingularNounForOneIngredientAndPluralForMore() {
    let one = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9)]), pantry: .notCaptured)
    let two = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.9), detection(pepper, 0.9)]), pantry: .notCaptured)

    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: one, selectedCount: 3),
      "Found 1 ingredient, 3 selected.")
    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: two, selectedCount: 1),
      "Found 2 ingredients, 1 selected.")
  }

  func testAnnouncementReportsZeroSelectedAmongTheFoundCount() {
    let state = OnboardingKitchenReview.state(
      fridge: scanned([detection(egg, 0.95)], unreadCrops: 2), pantry: .notCaptured)

    XCTAssertEqual(
      OnboardingKitchenReview.announcement(for: state, selectedCount: 0),
      "Found 1 ingredient, 0 selected. Some fridge photos couldn\u{2019}t be read.")
  }

  // MARK: - Unread notices

  func testPartlyReadItemsAndAFailedScanWarnDifferentlyForTheSamePlace() {
    XCTAssertEqual(
      OnboardingKitchenReview.unreadNotice(
        for: .items([detection(egg, 0.9)], someUnread: true), place: "freezer"),
      "Some freezer photos couldn\u{2019}t be read.")
    XCTAssertEqual(
      OnboardingKitchenReview.unreadNotice(for: .failed, place: "freezer"),
      "Couldn\u{2019}t read your freezer photos.")
    // An empty list with unread photos still warns: what those photos hold is unknown.
    XCTAssertEqual(
      OnboardingKitchenReview.unreadNotice(for: .items([], someUnread: true), place: "freezer"),
      "Some freezer photos couldn\u{2019}t be read.")
  }

  func testFullyCapturedSectionsShowNoUnreadNotice() {
    XCTAssertNil(OnboardingKitchenReview.unreadNotice(for: .notCaptured, place: "fridge"))
    XCTAssertNil(OnboardingKitchenReview.unreadNotice(for: .nothingFound, place: "fridge"))
    XCTAssertNil(
      OnboardingKitchenReview.unreadNotice(
        for: .items([detection(egg, 0.9)], someUnread: false), place: "fridge"))
    // Nothing recognized and everything read: silence is the honest answer.
    XCTAssertNil(
      OnboardingKitchenReview.unreadNotice(for: .items([], someUnread: false), place: "fridge"))
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
}
