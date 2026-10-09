import XCTest

@testable import FridgeLuck

/// The words VoiceOver says around the kitchen review's scan: what a scan start announces and
/// the labels the photo strip reads. Pinned as exact strings, so a rewording is a deliberate
/// choice that shows up here.
final class OnboardingKitchenScanAnnouncementTests: XCTestCase {
  // MARK: - Scan started

  func testScanStartWithNoPhotosSaysThereIsNothingToScan() {
    XCTAssertEqual(
      OnboardingKitchenReview.scanStartedAnnouncement(fridgePhotos: 0, pantryPhotos: 0),
      "No photos to scan.")
  }

  func testScanStartNamesASinglePhotoSingular() {
    XCTAssertEqual(
      OnboardingKitchenReview.scanStartedAnnouncement(fridgePhotos: 1, pantryPhotos: 0),
      "Scanning 1 fridge photo\u{2026}")
    XCTAssertEqual(
      OnboardingKitchenReview.scanStartedAnnouncement(fridgePhotos: 0, pantryPhotos: 1),
      "Scanning 1 pantry photo\u{2026}")
  }

  func testScanStartNamesSeveralPhotosPlural() {
    XCTAssertEqual(
      OnboardingKitchenReview.scanStartedAnnouncement(fridgePhotos: 3, pantryPhotos: 0),
      "Scanning 3 fridge photos\u{2026}")
    XCTAssertEqual(
      OnboardingKitchenReview.scanStartedAnnouncement(fridgePhotos: 2, pantryPhotos: 1),
      "Scanning 2 fridge photos and 1 pantry photo\u{2026}")
    XCTAssertEqual(
      OnboardingKitchenReview.scanStartedAnnouncement(fridgePhotos: 1, pantryPhotos: 2),
      "Scanning 1 fridge photo and 2 pantry photos\u{2026}")
  }

  // MARK: - Photo strip labels

  func testPhotoStripLabelsCoverFridgeThenPantry() {
    XCTAssertEqual(
      OnboardingKitchenReview.photoStripLabels(fridgeCount: 2, pantryCount: 1),
      ["Fridge photo 1 of 2", "Fridge photo 2 of 2", "Pantry photo 1 of 1"])
  }

  func testPhotoStripLabelsCapAtSixWithPantryCrowdedOutFirst() {
    let labels = OnboardingKitchenReview.photoStripLabels(fridgeCount: 3, pantryCount: 5)

    XCTAssertEqual(labels.count, 6)
    XCTAssertEqual(labels.first, "Fridge photo 1 of 3")
    XCTAssertEqual(labels.last, "Pantry photo 3 of 5")
  }

  func testPhotoStripLabelsWithOnlyPantryPhotos() {
    XCTAssertEqual(
      OnboardingKitchenReview.photoStripLabels(fridgeCount: 0, pantryCount: 2),
      ["Pantry photo 1 of 2", "Pantry photo 2 of 2"])
  }

  func testPhotoStripLabelsWithNoPhotosAreEmpty() {
    XCTAssertEqual(
      OnboardingKitchenReview.photoStripLabels(fridgeCount: 0, pantryCount: 0), [])
  }
}
