import XCTest
@testable import SearchCheck

final class SearchEngineTests: XCTestCase {
  private func makeEngine(
    store: SearchIndexStore,
    resolver: StubSearchHitResolving
  ) -> SearchEngine {
    SearchEngine(store: store, resolver: resolver)
  }

  private func seed(_ store: SearchIndexStore, _ docs: [SearchDocument]) throws {
    try store.rebuild(with: docs, sourceEpoch: "test-epoch")
  }

  private func ids(_ hits: [SearchHit]) -> Set<String> {
    Set(hits.map { $0.canonicalID.description })
  }

  // MARK: - Query handling

  func testEmptyAndWhitespaceQueriesReturnNothing() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [SearchFixtures.doc(.recipe, "1", title: "Garlic Chicken")])

    XCTAssertTrue(try engine.search("").isEmpty)
    XCTAssertTrue(try engine.search("   \n\t ").isEmpty)
  }

  func testMatchExpressionBuildsImplicitAndPrefixTerms() {
    XCTAssertEqual(
      SearchEngine.matchExpression(for: ["soy", "sauce"]),
      "\"soy\"* \"sauce\"*")
    XCTAssertNil(SearchEngine.matchExpression(for: []))
  }

  func testMatchExpressionQuotesFTSSyntaxCharacters() {
    let expression = SearchEngine.matchExpression(for: ["no\"tes"])
    XCTAssertEqual(expression, "\"no\"\"tes\"*")
  }

  // MARK: - Matching

  func testSingleTokenFindsTitleAndKeywordMatches() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [
      "recipe:1", "kitchen_ingredient:2", "kitchen_ingredient:3", "journal:4",
    ])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.recipe, "1", title: "Garlic Chicken"),
      SearchFixtures.doc(.kitchenIngredient, "2", title: "Chicken Breast"),
      SearchFixtures.doc(.kitchenIngredient, "3", title: "Whole Egg", keywords: "eggs"),
      SearchFixtures.doc(.journal, "4", title: "Chicken Noodle Soup"),
    ])

    let results = try engine.search("chicken")
    XCTAssertEqual(ids(results), ["recipe:1", "kitchen_ingredient:2", "journal:4"])
  }

  func testPrefixMatchingFindsKnownItemsWhileTyping() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [
      "kitchen_ingredient:1", "kitchen_ingredient:2", "kitchen_ingredient:3",
    ])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.kitchenIngredient, "1", title: "Chicken Breast"),
      SearchFixtures.doc(.kitchenIngredient, "2", title: "Canned Chickpeas"),
      SearchFixtures.doc(.kitchenIngredient, "3", title: "Whole Milk"),
    ])

    // "chick" is a prefix of both "chicken" and "chickpeas".
    XCTAssertEqual(
      ids(try engine.search("chick")),
      ["kitchen_ingredient:1", "kitchen_ingredient:2"])
    // "chicke" disambiguates.
    XCTAssertEqual(ids(try engine.search("chicke")), ["kitchen_ingredient:1"])
  }

  func testAliasesMakeKnownItemRetrievalWorkByCommonName() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: ["kitchen_ingredient:22", "recipe:1"])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(
        .kitchenIngredient, "22", title: "Aubergine", keywords: "eggplant"),
      SearchFixtures.doc(.recipe, "1", title: "Eggplant Parmigiana", keywords: "eggplant"),
    ])

    // Both directions: alias in keywords, and query by the display name.
    XCTAssertEqual(
      ids(try engine.search("eggplant")),
      ["kitchen_ingredient:22", "recipe:1"])
    XCTAssertEqual(
      ids(try engine.search("aubergine")),
      ["kitchen_ingredient:22"])
  }

  func testCompoundTokensMatchWhenTokenizerSplitsOnUnderscore() throws {
    // Content "soy_sauce" tokenizes to soy + sauce, so the two-word query
    // matches exactly the way single-word content does.
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [
      "kitchen_ingredient:7", "recipe:8", "recipe:9",
    ])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.kitchenIngredient, "7", title: "Soy Sauce"),
      SearchFixtures.doc(.recipe, "8", title: "Salmon Teriyaki", keywords: "soy sauce"),
      SearchFixtures.doc(.recipe, "9", title: "Teriyaki", keywords: "soy"),
    ])

    XCTAssertEqual(
      ids(try engine.search("soy sauce")),
      ["kitchen_ingredient:7", "recipe:8"])
  }

  func testMultiTokenQueriesRequireEveryToken() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [
      "recipe:1", "recipe:2", "recipe:3", "kitchen_ingredient:4",
    ])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.recipe, "1", title: "Garlic Butter Chicken"),
      SearchFixtures.doc(.recipe, "2", title: "Lemon Chicken"),
      SearchFixtures.doc(.recipe, "3", title: "Garlic Bread"),
      SearchFixtures.doc(.kitchenIngredient, "4", title: "Garlic"),
    ])

    XCTAssertEqual(
      ids(try engine.search("garlic chicken")),
      ["recipe:1"])
  }

  func testDiacriticInsensitiveQueriesMatchFoldedContent() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: ["kitchen_ingredient:1"])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.kitchenIngredient, "1", title: "Crème Fraîche"),
    ])

    XCTAssertEqual(ids(try engine.search("creme fraiche")), ["kitchen_ingredient:1"])
    XCTAssertEqual(ids(try engine.search("crème fraîche")), ["kitchen_ingredient:1"])
  }

  func testDateTokenQueriesFindJournalEntriesByMonthAndDay() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: ["journal:1", "journal:2", "journal:3"])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(
        .journal, "1", title: "Egg Fried Rice",
        dateTokens: "2026-06-02 2026-06 2026 02 june jun"),
      SearchFixtures.doc(
        .journal, "2", title: "Salmon Teriyaki",
        dateTokens: "2026-07-04 2026-07 2026 04 july jul"),
      SearchFixtures.doc(
        .journal, "3", title: "Chicken Noodle Soup",
        dateTokens: "2026-06-09 2026-06 2026 09 june jun"),
    ])

    XCTAssertEqual(
      ids(try engine.search("june")),
      ["journal:1", "journal:3"])
    XCTAssertEqual(ids(try engine.search("2026-06-02")), ["journal:1"])
    XCTAssertEqual(ids(try engine.search("july")).count, 1)
  }

  // MARK: - Ranking

  func testExactTitleMatchesRankFirst() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [
      "recipe:1", "kitchen_ingredient:2", "kitchen_ingredient:3",
    ])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.recipe, "1", title: "Butter Chicken Curry"),
      SearchFixtures.doc(.kitchenIngredient, "2", title: "Butter Chicken"),
      SearchFixtures.doc(.kitchenIngredient, "3", title: "Butter"),
    ])

    let results = try engine.search("butter chicken")
    XCTAssertEqual(results.first?.canonicalID.description, "kitchen_ingredient:2")
  }

  func testRankingIsDeterministicAcrossRuns() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(
      liveIDs: Set((1...12).map { "recipe:\($0)" }))
    let engine = makeEngine(store: store, resolver: resolver)
    let docs = (1...12).map {
      SearchFixtures.doc(.recipe, String($0), title: "Chicken Dish \($0)")
    }
    try seed(store, docs)

    let first = try engine.search("chicken")
    let second = try engine.search("chicken")
    XCTAssertEqual(
      first.map { $0.canonicalID.description },
      second.map { $0.canonicalID.description })
  }

  func testKindGroupOrderBreaksRankTies() throws {
    // Same title text, same token weight: kind priority decides
    // (inventory before ingredient before recipe before journal).
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: [
      "kitchen_inventory:1_fridge", "kitchen_ingredient:1", "recipe:1", "journal:1",
    ])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.journal, "1", title: "Matcha"),
      SearchFixtures.doc(.recipe, "1", title: "Matcha"),
      SearchFixtures.doc(.kitchenIngredient, "1", title: "Matcha"),
      SearchFixtures.doc(.kitchenInventory, "1_fridge", title: "Matcha"),
    ])

    let results = try engine.search("matcha")
    XCTAssertEqual(
      results.map { $0.canonicalID.kind },
      [.kitchenInventory, .kitchenIngredient, .recipe, .journal])
  }

  // MARK: - Revalidation

  func testSearchDropsDeletedRecordsAndRepairsTheIndex() throws {
    let store = try SearchIndexStore()
    // Only the first hit's record still exists.
    let resolver = StubSearchHitResolving(liveIDs: ["recipe:1"])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.recipe, "1", title: "Garlic Chicken"),
      SearchFixtures.doc(.recipe, "2", title: "Lemon Chicken"),
    ])

    let results = try engine.search("chicken")
    XCTAssertEqual(ids(results), ["recipe:1"])
    // The deleted record was repaired out of the index, not just filtered.
    XCTAssertEqual(try store.count(), 1)
  }

  func testSearchSurfacesLiveRevisionsForRevisionedKinds() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: ["recipe:1"])
    resolver.revisions["recipe:1"] = 123_456
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [SearchFixtures.doc(.recipe, "1", title: "Garlic Chicken", revision: 7)])

    let results = try engine.search("chicken")
    XCTAssertEqual(results.first?.revision, 123_456)
  }

  func testKindFiltersRestrictResults() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(liveIDs: ["recipe:1", "kitchen_ingredient:2"])
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, [
      SearchFixtures.doc(.recipe, "1", title: "Chicken Soup"),
      SearchFixtures.doc(.kitchenIngredient, "2", title: "Chicken Breast"),
    ])

    let recipesOnly = try engine.search("chicken", kinds: [.recipe])
    XCTAssertEqual(ids(recipesOnly), ["recipe:1"])

    let ingredientsOnly = try engine.search("chicken", kinds: [.kitchenIngredient])
    XCTAssertEqual(ids(ingredientsOnly), ["kitchen_ingredient:2"])
  }

  func testLimitIsRespected() throws {
    let store = try SearchIndexStore()
    let resolver = StubSearchHitResolving(
      liveIDs: Set((1...20).map { "recipe:\($0)" }))
    let engine = makeEngine(store: store, resolver: resolver)
    try seed(store, (1...20).map {
      SearchFixtures.doc(.recipe, String($0), title: "Chicken Dish \($0)")
    })

    XCTAssertEqual(try engine.search("chicken", limit: 5).count, 5)
  }
}
