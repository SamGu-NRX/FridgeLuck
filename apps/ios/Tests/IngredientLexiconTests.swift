import XCTest

@testable import FridgeLuck

final class IngredientLexiconTests: XCTestCase {
  private let unsupportedTerms = [
    "grain", "cereal", "meat", "meatball", "fish", "mackerel", "ham",
    "habanero", "jalapeno", "green_beans", "edamame", "oranges", "citrus_fruit",
    "caprese", "milkshake", "bean", "hummus", "falafel", "condiment", "mustard",
    "herb", "dill", "chives", "peanut", "coconut", "oat milk", "soy milk",
    "vegetable oil", "almond butter", "chicken thigh", "kidney beans",
  ]

  func testUnsupportedFoodsDoNotResolveToSubstitutes() {
    for term in unsupportedTerms {
      XCTAssertNil(IngredientLexicon.resolve(term), term)
      XCTAssertNil(IngredientLexicon.resolve(term.replacingOccurrences(of: "_", with: " ")), term)
    }
  }

  func testOCRDoesNotRecoverWrongFoodFromUnsupportedPhrase() {
    for term in unsupportedTerms {
      let text = term.replacingOccurrences(of: "_", with: " ")
      XCTAssertNil(IngredientLexicon.resolveFromTextDetailed(text), term)
      XCTAssertNil(IngredientLexicon.resolveFromText("\(text.uppercased()) 250 g"), term)
    }
  }

  func testTrueSynonymsStillResolveToExistingIngredients() {
    let synonyms: [(String, Int64)] = [
      ("eggs", 1), ("capsicum", 8), ("courgette", 45), ("garbanzo beans", 35),
      ("scallion", 21), ("spring onion", 21), ("green onion", 21),
      ("peanut butter", 41), ("coconut milk", 49), ("black beans", 27),
      ("soy sauce", 3), ("whole milk", 13),
    ]
    for (term, id) in synonyms {
      XCTAssertEqual(IngredientLexicon.resolve(term), id, term)
      let match = IngredientLexicon.resolveFromTextDetailed(term)
      XCTAssertEqual(match?.ingredientId, id, term)
      XCTAssertEqual(match?.kind, .exact, term)
    }
  }

  func testOCRCanStillFindSupportedFoodBesideUnsupportedPhrase() {
    XCTAssertEqual(IngredientLexicon.resolveFromText("oat milk; eggs"), 1)
    XCTAssertEqual(IngredientLexicon.resolveFromText("almond butter; soy sauce"), 3)
    XCTAssertEqual(IngredientLexicon.resolveFromText("coconut milk 400 ml"), 49)
    XCTAssertEqual(IngredientLexicon.resolveFromText("peanut butter 250 g"), 41)
  }
}
