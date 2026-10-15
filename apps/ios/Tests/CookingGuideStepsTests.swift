import FLFeatureLogic
import XCTest

final class CookingGuideStepsTests: XCTestCase {
  /// The shape every bundled recipe with a source uses (data.json, 2026-10-07).
  private let bundledInstructions = """
    Source: https://www.bbcgoodfood.com/recipes/sichuan-smacked-cucumber-noodles
    1. Toast the sichuan peppercorns.
    2. Smack the cucumber.
    10. Mix well to combine, then divide between two bowls.
    """

  func testSourceLineBecomesAttributionNotAStep() {
    let guide = CookingGuideSteps(instructions: bundledInstructions)

    XCTAssertEqual(
      guide.steps,
      [
        "Toast the sichuan peppercorns.",
        "Smack the cucumber.",
        "Mix well to combine, then divide between two bowls.",
      ])
    XCTAssertEqual(guide.attribution?.label, "bbcgoodfood.com")
    XCTAssertEqual(
      guide.attribution?.url,
      URL(string: "https://www.bbcgoodfood.com/recipes/sichuan-smacked-cucumber-noodles"))
  }

  func testSourcePrefixIsCaseInsensitiveAndNeverAStepAnywhereInTheText() {
    let guide = CookingGuideSteps(instructions: "1. Boil water.\nSOURCE: https://example.org/x")
    XCTAssertEqual(guide.steps, ["Boil water."])
    XCTAssertEqual(guide.attribution?.label, "example.org")
  }

  func testFirstSourceWinsAndEmptySourceIsDropped() {
    let guide = CookingGuideSteps(
      instructions: "Source:\nSource: https://a.example/1\nSource: https://b.example/2\n1. Stir.")
    XCTAssertEqual(guide.steps, ["Stir."])
    XCTAssertEqual(guide.attribution?.label, "a.example")
  }

  func testNonWebSourceKeepsItsTextAndHasNoLink() {
    let guide = CookingGuideSteps(instructions: "Source: Grandma's notebook\n1. Stir.")
    XCTAssertEqual(guide.attribution?.label, "Grandma's notebook")
    XCTAssertNil(guide.attribution?.url)
  }

  func testNonHTTPSchemesAreNotLinked() {
    let attribution = RecipeAttribution(source: "javascript:alert(1)")
    XCTAssertNil(attribution.url)
    XCTAssertEqual(attribution.label, "javascript:alert(1)")
  }

  func testStepNumbersAreRemovedOnlyWhenFollowedBySpace() {
    let guide = CookingGuideSteps(
      instructions: """
        1) Preheat the oven.
        1.5 cups of stock go in next.
        2 eggs, beaten.
        """)
    XCTAssertEqual(
      guide.steps,
      ["Preheat the oven.", "1.5 cups of stock go in next.", "2 eggs, beaten."])
  }

  func testRecipesWithoutSourceOrNumbersAreUnchanged() {
    let guide = CookingGuideSteps(instructions: "  Chop the onion.  \r\n\r\nFry it.\n")
    XCTAssertEqual(guide.steps, ["Chop the onion.", "Fry it."])
    XCTAssertNil(guide.attribution)
  }

  func testNumberOnlyLinesAreDropped() {
    XCTAssertEqual(CookingGuideSteps(instructions: "1. \n2. Stir.").steps, ["Stir."])
  }
}
