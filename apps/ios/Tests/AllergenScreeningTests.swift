import FLFeatureLogic
import XCTest

final class AllergenScreeningTests: XCTestCase {
  func testPeanutBlocksTitleMatch() {
    let rejection = AllergenScreening.rejection(
      title: "Peanut Sauce Noodles",
      instructions: "Boil the noodles.",
      avoidingIngredients: ["peanut"])

    XCTAssertEqual(rejection?.field, .title)
    XCTAssertEqual(rejection?.avoidedIngredient, "peanut")
    XCTAssertEqual(rejection?.matchedTerm, "Peanut")
  }

  func testPeanutBlocksSimplePlural() {
    let rejection = AllergenScreening.rejection(
      title: "Peanuts",
      instructions: "Toast the peanuts.",
      avoidingIngredients: ["peanut"])

    XCTAssertEqual(rejection?.field, .title)
    XCTAssertEqual(rejection?.matchedTerm, "Peanuts")
  }

  func testEggDoesNotBlockEggplant() {
    XCTAssertNil(
      AllergenScreening.rejection(
        title: "Eggplant Parmesan",
        instructions: "Layer the eggplant slices and bake until golden.",
        avoidingIngredients: ["egg"]))
  }

  func testEmptyAvoidListPassesEverything() {
    XCTAssertNil(
      AllergenScreening.rejection(
        title: "Peanut Brittle",
        instructions: "Fold in peanuts and tree nuts with a whole egg.",
        avoidingIngredients: []))
  }

  func testRejectionCarriesFieldIngredientAndTerm() {
    let titleRejection = AllergenScreening.rejection(
      title: "Sesame Peanut Noodles",
      instructions: "No avoided ingredients here.",
      avoidingIngredients: ["sesame", "peanut"])
    XCTAssertEqual(titleRejection?.avoidedIngredient, "sesame")
    XCTAssertEqual(titleRejection?.matchedTerm, "Sesame")
    XCTAssertEqual(titleRejection?.field, .title)

    let instructionsRejection = AllergenScreening.rejection(
      title: "Veggie Stir-Fry",
      instructions: "Whisk one egg and pour it in.",
      avoidingIngredients: ["egg"])
    XCTAssertEqual(instructionsRejection?.avoidedIngredient, "egg")
    XCTAssertEqual(instructionsRejection?.matchedTerm, "egg")
    XCTAssertEqual(instructionsRejection?.field, .instructions)
  }

  func testInstructionMatchIsCaseInsensitive() {
    let rejection = AllergenScreening.rejection(
      title: "Weeknight Stir-Fry",
      instructions: "Stir in PEANUT butter until smooth.",
      avoidingIngredients: ["peanut"])

    XCTAssertEqual(rejection?.field, .instructions)
    XCTAssertEqual(rejection?.matchedTerm, "PEANUT")
  }

  func testPluralAvoidNameBlocksSingularText() {
    let rejection = AllergenScreening.rejection(
      title: "peanut brittle",
      instructions: "",
      avoidingIngredients: ["Peanuts"])

    XCTAssertEqual(rejection?.avoidedIngredient, "Peanuts")
    XCTAssertEqual(rejection?.matchedTerm, "peanut")
  }

  func testTreeNutPhraseBlocksHyphenatedAndPluralForms() {
    let hyphenated = AllergenScreening.rejection(
      title: "Tree-Nut Crust",
      instructions: "",
      avoidingIngredients: ["tree nut"])
    XCTAssertEqual(hyphenated?.matchedTerm, "Tree-Nut")

    let plural = AllergenScreening.rejection(
      title: "Cake topped with tree nuts",
      instructions: "",
      avoidingIngredients: ["tree nut"])
    XCTAssertEqual(plural?.matchedTerm, "tree nuts")
  }

  func testHyphenatedCompoundNameIsBlocked() {
    let rejection = AllergenScreening.rejection(
      title: "peanut-free cookies",
      instructions: "",
      avoidingIngredients: ["peanut"])

    XCTAssertEqual(rejection?.matchedTerm, "peanut")
  }

  func testNoMatchReturnsNil() {
    XCTAssertNil(
      AllergenScreening.rejection(
        title: "Summer Berry Salad",
        instructions: "Toss the berries with mint and lime.",
        avoidingIngredients: ["peanut", "tree nut", "egg"]))
  }
}
