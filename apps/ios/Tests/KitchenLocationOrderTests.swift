import XCTest

@testable import FridgeLuck

/// Every storage section on the Kitchen screen needs a filter chip, including "Other"
/// (2026-10-07 walk: an "Other" section with no "Other" chip).
final class KitchenLocationOrderTests: XCTestCase {
  func testOtherGetsAChipWhenItHasItems() {
    XCTAssertEqual(
      KitchenLocationOrder.chipLocations(counts: [.fridge: 2, .unknown: 1]),
      [.fridge, .unknown])
  }

  func testLocationsWithoutItemsGetNoChip() {
    XCTAssertEqual(
      KitchenLocationOrder.chipLocations(counts: [.pantry: 1, .freezer: 0, .unknown: 0]),
      [.pantry])
    XCTAssertEqual(KitchenLocationOrder.chipLocations(counts: [:]), [])
  }

  func testChipsFollowTheSectionOrderWithOtherLast() {
    let everyLocation = Dictionary(
      uniqueKeysWithValues: InventoryStorageLocation.allCases.map { ($0, 1) })
    XCTAssertEqual(
      KitchenLocationOrder.chipLocations(counts: everyLocation),
      [.fridge, .pantry, .freezer, .unknown])
  }

  func testSectionOrderCoversEveryStorageLocation() {
    XCTAssertEqual(Set(KitchenLocationOrder.all), Set(InventoryStorageLocation.allCases))
  }
}
