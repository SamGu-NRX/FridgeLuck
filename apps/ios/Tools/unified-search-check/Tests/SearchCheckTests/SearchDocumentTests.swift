import XCTest
@testable import SearchCheck

final class SearchDocumentTests: XCTestCase {
  // MARK: - SearchText

  func testFoldedRemovesCaseAndDiacritics() {
    XCTAssertEqual(SearchText.folded("Café au LAIT"), "cafe au lait")
    XCTAssertEqual(SearchText.folded("ÅNGSTRÖM"), "angstrom")
    XCTAssertEqual(SearchText.folded(""), "")
  }

  func testTokensPreserveUnderscoreCompoundsAndSplitOtherSeparators() {
    // "_" is kept so multiword phrases survive tokenization; FTS5's tokenizer
    // splits on it, so compounds still match word queries.
    XCTAssertEqual(SearchText.tokens(in: "Soy_Sauce v2!"), ["soy_sauce", "v2"])
    XCTAssertEqual(SearchText.tokens(in: "  Garlic   Butter "), ["garlic", "butter"])
    XCTAssertEqual(SearchText.tokens(in: ""), [])
    XCTAssertEqual(SearchText.tokens(in: "!!!"), [])
    XCTAssertEqual(SearchText.tokens(in: "Crème Fraîche"), ["creme", "fraiche"])
  }

  func testTokensLimitCapsCount() {
    let many = (1...20).map { "t\($0)" }.joined(separator: " ")
    XCTAssertEqual(SearchText.tokens(in: many).count, 12)
    XCTAssertEqual(SearchText.tokens(in: many, limit: 3).count, 3)
  }

  func testStableHashIsDeterministicAndInputSensitive() {
    let a = SearchText.stableHash("chicken breast")
    XCTAssertEqual(a, SearchText.stableHash("chicken breast"))
    XCTAssertNotEqual(a, SearchText.stableHash("chicken  breast"))
  }

  // MARK: - SearchRecordKind

  func testKindRawValuesMatchCanonicalIDFormat() {
    XCTAssertEqual(SearchRecordKind.kitchenIngredient.rawValue, "kitchen_ingredient")
    XCTAssertEqual(SearchRecordKind.kitchenInventory.rawValue, "kitchen_inventory")
    XCTAssertEqual(SearchRecordKind.recipe.rawValue, "recipe")
    XCTAssertEqual(SearchRecordKind.journal.rawValue, "journal")
    XCTAssertEqual(SearchRecordKind.allCases.count, 4)
  }

  func testKindGroupOrderIsDeterministic() {
    XCTAssertEqual(SearchRecordKind.kitchenInventory.sortPriority, 0)
    XCTAssertEqual(SearchRecordKind.kitchenIngredient.sortPriority, 1)
    XCTAssertEqual(SearchRecordKind.recipe.sortPriority, 2)
    XCTAssertEqual(SearchRecordKind.journal.sortPriority, 3)
    XCTAssertTrue(SearchRecordKind.kitchenInventory < .kitchenIngredient)
    XCTAssertTrue(SearchRecordKind.recipe < .journal)
  }

  // MARK: - Canonical IDs

  func testCanonicalIDDescriptionRoundTrips() {
    let id = SearchCanonicalID(kind: .kitchenInventory, rawID: "42_fridge")
    XCTAssertEqual(id.description, "kitchen_inventory:42_fridge")
    XCTAssertEqual(SearchCanonicalID(parsing: id.description), id)
  }

  func testCanonicalIDParsingRejectsMalformedInput() {
    XCTAssertNil(SearchCanonicalID(parsing: ""))
    XCTAssertNil(SearchCanonicalID(parsing: "no-separator-here"))
    XCTAssertNil(SearchCanonicalID(parsing: "kitchen_ingredient:"))
    XCTAssertNil(SearchCanonicalID(parsing: "unknown_kind:1"))
    // colons inside the raw ID survive parsing
    let parsed = SearchCanonicalID(parsing: "recipe:1:2")
    XCTAssertEqual(parsed?.rawID, "1:2")
  }

  // MARK: - Documents and hits

  func testDocumentCarriesAllIndexableFields() {
    let document = SearchFixtures.doc(
      .recipe, "7",
      title: "Garlic Chicken",
      subtitle: "30 min · 2 servings",
      keywords: "chicken garlic",
      dateTokens: "2026-04-02 2026-04 2026 02 april apr",
      revision: 99)
    XCTAssertEqual(document.canonicalID.kind, .recipe)
    XCTAssertEqual(document.title, "Garlic Chicken")
    XCTAssertEqual(document.revision, 99)
  }
}
