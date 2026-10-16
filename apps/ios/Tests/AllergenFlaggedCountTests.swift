import XCTest

@testable import FridgeLuck

/// One tap on an allergen group selects every ingredient the group matches. The onboarding
/// finish line said "3 allergens flagged" after a single Peanut tap because it counted those
/// ingredients. These pin the count to what the user picked.
final class AllergenFlaggedCountTests: XCTestCase {
  private let groups: [String: Set<Int64>] = [
    "peanut": [1, 2, 3],
    "tree_nut": [10, 11],
    "milk": [20],
    "egg": [],
  ]

  func testNothingSelectedCountsZero() {
    XCTAssertEqual(count([]), 0)
  }

  func testOneFullGroupCountsOnceWhateverItCovers() {
    XCTAssertEqual(count([1, 2, 3]), 1)
  }

  func testTwoFullGroupsCountTwice() {
    XCTAssertEqual(count([1, 2, 3, 20]), 2)
  }

  func testIngredientsPickedOneByOneCountEach() {
    // Two tree nuts picked in the ingredient picker, not the whole group.
    XCTAssertEqual(count([10, 99]), 2)
  }

  func testFullGroupPlusLooseIngredientCountsBoth() {
    XCTAssertEqual(count([1, 2, 3, 99]), 2)
  }

  func testPartlySelectedGroupCountsItsIngredients() {
    // Peanut tapped, then one peanut ingredient removed in the picker.
    XCTAssertEqual(count([1, 2]), 2)
  }

  func testGroupWithNoCatalogMatchesNeverCounts() {
    XCTAssertEqual(count([99]), 1)
  }

  func testEveryGroupSubtitleSaysMoreThanItsTitle() {
    for group in AllergenSupport.groups {
      XCTAssertFalse(group.subtitle.isEmpty, "\(group.id) has no subtitle")
      XCTAssertNotEqual(
        group.subtitle.lowercased(), group.title.lowercased(),
        "\(group.id) card reads \"\(group.title) / \(group.subtitle)\"")
    }
  }

  private func count(_ selected: Set<Int64>) -> Int {
    AllergenSupport.flaggedAllergenCount(selectedIngredientIDs: selected, groupMatchesByID: groups)
  }
}
