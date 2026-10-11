import XCTest

@testable import FridgeLuck

final class IngredientIdentityResolutionTests: XCTestCase {
  /// Stands in for a USDA alias match that returns a catalog-only ID.
  private let catalogOnlyID: Int64 = 122

  func testCuratedFoodBeatsCatalogAliasForVisionLabel() throws {
    let curatedID = try XCTUnwrap(IngredientLexicon.resolve("bell_pepper"))

    let resolved = IngredientIdentityResolution.resolveLabel(
      "bell_pepper",
      userCorrection: { _ in nil },
      curated: IngredientLexicon.resolve,
      catalog: { _ in self.catalogOnlyID }
    )

    XCTAssertEqual(resolved, curatedID)
  }

  func testVisionLabelAndOCRWordAgreeOnTheSameFood() throws {
    let fromLabel = IngredientIdentityResolution.resolveLabel(
      "bell_pepper",
      userCorrection: { _ in nil },
      curated: IngredientLexicon.resolve,
      catalog: { _ in self.catalogOnlyID }
    )
    let fromText = IngredientLexicon.resolveFromTextDetailed("bell pepper")?.ingredientId

    XCTAssertNotNil(fromLabel)
    XCTAssertEqual(fromLabel, fromText)
  }

  func testUserCorrectionWinsOverEverything() {
    let resolved = IngredientIdentityResolution.resolveLabel(
      "bell_pepper",
      userCorrection: { _ in 42 },
      curated: IngredientLexicon.resolve,
      catalog: { _ in self.catalogOnlyID }
    )

    XCTAssertEqual(resolved, 42)
  }

  func testMaskingHandlesRepeatsAndPlurals() {
    XCTAssertEqual(IngredientLexicon.maskingUnsupportedFoodPhrases("Oat milk, oat milk"), "")
    XCTAssertEqual(IngredientLexicon.maskingUnsupportedFoodPhrases("2 chicken thighs"), "2")
    XCTAssertEqual(IngredientLexicon.maskingUnsupportedFoodPhrases("oat milk and eggs"), "and eggs")
    XCTAssertNil(IngredientLexicon.resolveFromTextDetailed("chicken thighs"))
  }

  func testCatalogFallbackCannotTurnOatMilkIntoMilk() {
    // A token-level catalog that would map the word "milk" to dairy milk.
    let tokens: (String) -> Int64? = { $0.split(separator: " ").contains("milk") ? 13 : nil }

    let resolved = IngredientIdentityResolution.resolveTextFromCatalog(
      "Oat milk oat milk", catalogName: { _ in nil }, catalogTokens: tokens)

    XCTAssertNil(resolved)
  }

  func testCatalogFallbackKeepsAnExactCatalogEntryForTheWholePhrase() {
    let resolved = IngredientIdentityResolution.resolveTextFromCatalog(
      "oat milk",
      catalogName: { $0 == "oat milk" ? 700 : nil },
      catalogTokens: { _ in 13 })

    XCTAssertEqual(resolved, 700)
  }

  func testCatalogFallbackStillReadsOtherFoodsInTheText() {
    let resolved = IngredientIdentityResolution.resolveTextFromCatalog(
      "oat milk kohlrabi",
      catalogName: { _ in nil },
      catalogTokens: { $0 == "kohlrabi" ? 900 : nil })

    XCTAssertEqual(resolved, 900)
  }

  func testCatalogCoversFoodsTheCuratedListLacks() {
    let resolved = IngredientIdentityResolution.resolveLabel(
      "kohlrabi",
      userCorrection: { _ in nil },
      curated: IngredientLexicon.resolve,
      catalog: { $0 == "kohlrabi" ? 900 : nil }
    )

    XCTAssertEqual(resolved, 900)
  }
}
