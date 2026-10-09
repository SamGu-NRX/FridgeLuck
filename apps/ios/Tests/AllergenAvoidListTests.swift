import FLFeatureLogic
import XCTest

final class AllergenAvoidListTests: XCTestCase {
  func testMapsIDsToSortedUniqueNames() {
    let names = AllergenAvoidList.names(
      forIDs: [3, 1, 2],
      idToName: [1: "Peanut", 2: "Egg", 3: "Milk"])

    XCTAssertEqual(names, ["Egg", "Milk", "Peanut"])
  }

  func testDropsUnknownIDs() {
    let names = AllergenAvoidList.names(
      forIDs: [1, 99, 2],
      idToName: [1: "Peanut", 2: "Egg"])

    XCTAssertEqual(names, ["Egg", "Peanut"])
  }

  func testDropsBlankNames() {
    let names = AllergenAvoidList.names(
      forIDs: [1, 2, 3],
      idToName: [1: "", 2: "   ", 3: "Peanut"])

    XCTAssertEqual(names, ["Peanut"])
  }

  func testEmptyInputGivesEmptyOutput() {
    XCTAssertTrue(AllergenAvoidList.names(forIDs: [], idToName: [1: "Peanut"]).isEmpty)
  }

  func testCaseInsensitiveDedupeKeepsFirstSpelling() {
    let names = AllergenAvoidList.names(
      forIDs: [1, 2],
      idToName: [1: "Peanut", 2: "peanut"])

    XCTAssertEqual(names, ["Peanut"])
  }

  func testSortIgnoresCase() {
    let names = AllergenAvoidList.names(
      forIDs: [1, 2],
      idToName: [1: "Banana", 2: "apple"])

    XCTAssertEqual(names, ["apple", "Banana"])
  }
}
