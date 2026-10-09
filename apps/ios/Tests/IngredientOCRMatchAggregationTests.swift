import CoreGraphics
import XCTest

@testable import FridgeLuck

final class IngredientOCRMatchAggregationTests: XCTestCase {
  private func match(
    _ text: String, id: Int64, capture: Int = 0, crop: String = "full",
    catalog: Bool = false, parts: [String] = []
  ) -> IngredientOCRMatchAggregation.Match {
    .init(
      ingredientId: id, confidence: catalog ? 0.55 : 0.9, originalText: text,
      matchedToken: text, kind: catalog ? .fuzzy : .exact,
      boundingBox: .zero, cropID: crop, captureIndex: capture,
      isCatalogFallback: catalog, joinedParts: parts)
  }

  func testJoinedBlackBeansSuppressCatalogPartsAcrossCropsInTheSameCapture() {
    let matches = [
      match("BEANS", id: 169960, catalog: true),
      match("BLACK BEANS", id: 27, crop: "topLeft", parts: ["BLACK", "BEANS"]),
      match("BLACK", id: 999, crop: "center", catalog: true),
    ]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(matches).map(\.ingredientId), [27])
  }

  func testJoinedOliveOilSuppressesNormalizedLoneOlive() {
    let matches = [
      match("  Olive! ", id: 171413, catalog: true),
      match("OLIVE OIL", id: 16, crop: "center", parts: ["OLIVE", "OIL"]),
    ]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(matches).map(\.ingredientId), [16])
  }

  func testSamePartInAnotherCaptureIsNotSuppressed() {
    let matches = [
      match("BEANS", id: 169960, capture: 1, catalog: true),
      match("BLACK BEANS", id: 27, parts: ["BLACK", "BEANS"]),
    ]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(matches).map(\.ingredientId), [169960, 27])
  }

  func testCuratedMatchesAndLongerCatalogPhrasesAreUntouched() {
    let matches = [
      match("BEANS", id: 27),
      match("CANNED BEANS", id: 169960, catalog: true),
      match("BLACK BEANS", id: 27, parts: ["BLACK", "BEANS"]),
    ]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(matches).map(\.originalText),
      matches.map(\.originalText))
  }

  func testMixedLabelPreservesMultiWordCatalogFoodWhileSuppressingLoneBeans() {
    let matches = [
      match("GREEN BEANS AND BLACK", id: 169961, catalog: true),
      match("GREEN BEANS", id: 169961, crop: "center", catalog: true),
      match("  Beans! ", id: 169960, catalog: true),
      match("BLACK", id: 999, catalog: true),
      match(
        "GREEN BEANS AND BLACK BEANS", id: 27, crop: "topLeft",
        parts: ["GREEN BEANS AND BLACK", "BEANS"]),
    ]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(matches).map(\.originalText),
      ["GREEN BEANS AND BLACK", "GREEN BEANS", "BLACK", "GREEN BEANS AND BLACK BEANS"])
  }

  func testNoJoinedMatchLeavesCatalogFoodsUntouched() {
    let matches = [match("BEANS", id: 169960, catalog: true), match("BLACK BEANS", id: 27)]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(matches).map(\.ingredientId), [169960, 27])
  }

  func testSuppressionDoesNotDependOnMatchOrder() {
    let matches = [
      match("BEANS", id: 169960, catalog: true),
      match("BLACK BEANS", id: 27, parts: ["BLACK", "BEANS"]),
    ]
    XCTAssertEqual(
      IngredientOCRMatchAggregation.suppressJoinedParts(Array(matches.reversed())).map(
        \.ingredientId), [27])
  }
}
