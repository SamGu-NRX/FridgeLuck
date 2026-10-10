import SwiftReplayProduction
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

    func testLexiconIsStateBlindOnCookedModifier() {
        // The production lexicon has no state dimension: "cooked rice" must
        // resolve to the same id as "rice". This is the exact confusion the
        // preparation-state benchmark isolates.
        XCTAssertEqual(IngredientLexicon.resolve("cooked rice"), IngredientLexicon.resolve("rice"))
        XCTAssertNil(IngredientLexicon.resolve("cooked"))
    }

    func testTextReplayMatchesThroughPhrase() {
        let match = IngredientLexicon.resolveFromTextDetailed("1 cup cooked rice")
        XCTAssertEqual(match?.ingredientId, 2)
        XCTAssertEqual(match?.matchedToken, "rice")
    }
}
