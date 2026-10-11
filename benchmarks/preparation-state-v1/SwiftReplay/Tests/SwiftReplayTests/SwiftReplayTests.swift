// @testable: the production lexicon is intentionally internal to its module and must
// not be made public for the replay harness; SwiftPM debug builds enable -enable-testing.
@testable import SwiftReplayProduction
import XCTest

final class SwiftReplayTests: XCTestCase {
    func testLexiconResolvesPlainLabel() {
        XCTAssertEqual(IngredientLexicon.resolve("egg"), 1)
        XCTAssertEqual(IngredientLexicon.resolve("rice"), 2)
    }

    func testLexiconResolvesSynonymPhrase() {
        XCTAssertEqual(IngredientLexicon.resolve("soy sauce"), 3)
        XCTAssertEqual(IngredientLexicon.resolve("greek yogurt"), 32)
    }

    func testLexiconKeepsStateModifiersUnresolved() {
        // REAL behavior, verified by running this package (Linux, Swift 6.1.2):
        // the lexicon itself has no state dimension — it does NOT strip state
        // modifiers, so "cooked rice" resolves to nil, not to "rice" (2).
        // The state-blind modifier stripping lives in
        // IngredientCatalogResolver + IngredientIdentityResolution, which the
        // benchmark replays in Python (production_replay arm).
        XCTAssertNil(IngredientLexicon.resolve("cooked rice"))
        XCTAssertEqual(IngredientLexicon.resolve("rice"), 2)
        XCTAssertNil(IngredientLexicon.resolve("cooked"))
    }

    func testTextReplayMatchesThroughPhrase() {
        let match = IngredientLexicon.resolveFromTextDetailed("1 cup cooked rice")
        XCTAssertEqual(match?.ingredientId, 2)
        XCTAssertEqual(match?.matchedToken, "rice")
    }
}
