import CoreGraphics
import XCTest

@testable import FridgeLuck

final class IngredientOCRLineJoiningTests: XCTestCase {
  private func line(_ text: String, x: Double = 0.2, y: Double) -> IngredientOCRLineJoining.Line {
    .init(text: text, boundingBox: CGRect(x: x, y: y, width: 0.2, height: 0.05))
  }

  func testAlignedLinesRecoverCuratedBlackBeansAndUnionTheirBoxes() {
    let lines = [line("BLACK", y: 0.5), line("BEANS", y: 0.44)]
    let joined = IngredientOCRLineJoining.joinAdjacent(lines)
    XCTAssertEqual(joined.count, 1)
    XCTAssertEqual(joined.first?.text, "BLACK BEANS")
    XCTAssertEqual(joined.first?.boundingBox, lines[0].boundingBox.union(lines[1].boundingBox))
    XCTAssertEqual(IngredientLexicon.resolveFromTextDetailed(joined[0].text)?.ingredientId, 27)
  }

  func testMisalignedLinesStaySeparate() {
    let lines = [line("BLACK", y: 0.5), line("BEANS", x: 0.4, y: 0.44)]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }

  func testGapLargerThanOneLineHeightStaysSeparate() {
    let lines = [line("BLACK", y: 0.5), line("BEANS", y: 0.39)]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }

  func testExcessiveVerticalOverlapStaysSeparate() {
    let lines = [line("BLACK", y: 0.5), line("BEANS", y: 0.49)]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }

  func testBothCuratedPartsStaySeparate() {
    let lines = [line("RICE", y: 0.5), line("ONION", y: 0.44)]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }

  func testOneCuratedPartAlsoPreventsJoining() {
    let lines = [line("BLACK", y: 0.5), line("RICE", y: 0.44)]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }

  func testThreeLinesNeverChainOrReuseAConsumedLine() {
    let lines = [line("BLACK", y: 0.5), line("BEANS", y: 0.44), line("BLACK", y: 0.38)]
    let joined = IngredientOCRLineJoining.joinAdjacent(lines)
    XCTAssertEqual(joined.map(\.text), ["BLACK", "BLACK BEANS"])
    XCTAssertEqual(joined[0], lines[2])
    XCTAssertEqual(joined[1].boundingBox, lines[0].boundingBox.union(lines[1].boundingBox))
  }

  func testObservationOrderDoesNotReverseThePhrase() {
    let joined = IngredientOCRLineJoining.joinAdjacent([line("BEANS", y: 0.44), line("BLACK", y: 0.5)])
    XCTAssertEqual(joined.map(\.text), ["BLACK BEANS"])
  }

  func testAlignedButUnresolvedPhraseStaysSeparate() {
    let lines = [line("BLACK", y: 0.5), line("LABEL", y: 0.44)]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }

  func testZeroWidthCannotJoin() {
    let lines = [
      IngredientOCRLineJoining.Line(text: "BLACK", boundingBox: CGRect(x: 0.2, y: 0.5, width: 0, height: 0.05)),
      line("BEANS", y: 0.44),
    ]
    XCTAssertEqual(IngredientOCRLineJoining.joinAdjacent(lines), lines)
  }
}
