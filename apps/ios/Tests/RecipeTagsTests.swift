import XCTest

@testable import FridgeLuck

/// Tag labels go straight into the UI, so they must read as words, not stored keys.
final class RecipeTagsTests: XCTestCase {
  func testMultiWordTagsReadAsWords() {
    let tags: RecipeTags = [.highProtein, .lowCarb, .onePot]
    XCTAssertEqual(tags.labels, ["high protein", "low carb", "one pot"])
  }

  func testSingleWordTagsAreUnchanged() {
    let tags: RecipeTags = [.quick, .vegetarian]
    XCTAssertEqual(tags.labels, ["quick", "vegetarian"])
  }

  func testNoLabelKeepsAnUnderscore() {
    let every = RecipeTags.allTags.reduce(RecipeTags()) { $0.union($1.1) }
    XCTAssertFalse(every.labels.contains { $0.contains("_") })
  }
}
