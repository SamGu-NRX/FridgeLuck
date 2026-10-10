import XCTest
import CoreGraphics
import FridgeLuck
import GRDB
@testable import GroceryOCRHarness

/// Golden-vector tests pinning the harness flow to the production recognition
/// behavior: lexicon resolution kinds, catalog fallback, confidence routing, and
/// per-ingredient dedup. Vectors are hand-derived from the production sources on
/// this branch (IngredientLexicon.swift, IngredientCatalogResolver.swift,
/// ConfidenceRouter.swift, VisionService.swift).
final class EquivalenceTests: XCTestCase {
  private func makeResolver() throws -> IngredientCatalogResolver {
    let db = try DatabaseQueue()
    try db.write { db in
      try db.execute(sql: "CREATE TABLE ingredients (id INTEGER PRIMARY KEY, name TEXT)")
      try db.execute(sql: "CREATE TABLE ingredient_aliases (alias TEXT, ingredient_id INTEGER)")
      try db.execute(sql: "INSERT INTO ingredients (id, name) VALUES (101, 'tomato ketchup')")
      try db.execute(sql: "INSERT INTO ingredients (id, name) VALUES (102, 'dijon mustard')")
      try db.execute(sql: "INSERT INTO ingredients (id, name) VALUES (201, 'gouda')")
      try db.execute(sql: "INSERT INTO ingredients (id, name) VALUES (202, 'edam')")
      try db.execute(sql: "INSERT INTO ingredient_aliases (alias, ingredient_id) VALUES ('smoked cheese', 201)")
      try db.execute(sql: "INSERT INTO ingredient_aliases (alias, ingredient_id) VALUES ('smoked cheese', 202)")
    }
    return IngredientCatalogResolver(db: db)
  }

  func testLexiconExactSynonymPhrase() {
    let m = IngredientLexicon.resolveFromTextDetailed("FRESH LARGE EGGS, GRADE A")
    XCTAssertEqual(m?.ingredientId, 1)
    XCTAssertEqual(m?.kind, .exact)
    XCTAssertEqual(m?.matchedToken, "large eggs")
  }

  func testLexiconExactSynonymMilk() {
    let m = IngredientLexicon.resolveFromTextDetailed("Whole Milk 1 gal")
    XCTAssertEqual(m?.ingredientId, 13)
    XCTAssertEqual(m?.kind, .exact)
  }

  func testLexiconFuzzyTokenDepluralizes() {
    let m = IngredientLexicon.resolveFromTextDetailed("Premium Natural Tomatoes")
    XCTAssertEqual(m?.ingredientId, 7)
    XCTAssertEqual(m?.kind, .fuzzy)
    XCTAssertEqual(m?.matchedToken, "tomatoes")
  }

  func testLexiconNoMatch() {
    XCTAssertNil(IngredientLexicon.resolveFromTextDetailed("Made in Canada"))
    XCTAssertNil(IngredientLexicon.resolveFromTextDetailed(""))
  }

  func testCatalogExactNameAndSlidingWindow() throws {
    let resolver = try makeResolver()
    XCTAssertEqual(resolver.resolve("tomato ketchup"), 101)
    XCTAssertEqual(resolver.resolveFromText("HEINZ TOMATO KETCHUP 500 G"), 101)
  }

  func testCatalogAmbiguousAliasReturnsNil() throws {
    let resolver = try makeResolver()
    XCTAssertNil(resolver.resolve("smoked cheese"))
  }

  func testCatalogDisplayNameCapitalizes() throws {
    let resolver = try makeResolver()
    XCTAssertEqual(resolver.displayName(for: 101), "Tomato ketchup")
    XCTAssertNil(resolver.displayName(for: 999))
  }

  func testConfidenceBucketsMirrorConfidenceRouter() {
    func det(kind: OCRMatchKind, confidence: Float) -> Detection {
      Detection(
        ingredientId: 1, label: "Egg", confidence: confidence, source: .ocr,
        originalVisionLabel: "x", ocrMatchKind: kind)
    }
    XCTAssertEqual(ConfidenceRouter.bucket(for: det(kind: .exact, confidence: 0.90)), .auto)
    XCTAssertEqual(ConfidenceRouter.bucket(for: det(kind: .exact, confidence: 0.60)), .confirm)
    XCTAssertEqual(ConfidenceRouter.bucket(for: det(kind: .exact, confidence: 0.59)), .possible)
    XCTAssertEqual(ConfidenceRouter.bucket(for: det(kind: .fuzzy, confidence: 0.55)), .confirm)
    XCTAssertEqual(ConfidenceRouter.bucket(for: det(kind: .fuzzy, confidence: 0.54)), .possible)
  }

  func testProcessOCRRecordGoldenFlow() throws {
    let resolver = try makeResolver()
    let record = OCRRecordInput(
      imageId: "case1__front", code: nil, role: "front",
      width: 1000, height: 800,
      lines: [
        LineInput(text: "FRESH LARGE EGGS GRADE A", x0: 10, y0: 10, x1: 300, y1: 30, conf: 90),
        LineInput(text: "Whole Milk 1 gal", x0: 10, y0: 40, x1: 300, y1: 60, conf: 88),
        LineInput(text: "Premium Natural Tomatoes", x0: 10, y0: 70, x1: 300, y1: 90, conf: 70),
        LineInput(text: "HEINZ TOMATO KETCHUP 500 G", x0: 10, y0: 100, x1: 300, y1: 120, conf: 85),
        LineInput(text: "Made in Canada", x0: 10, y0: 130, x1: 300, y1: 150, conf: 92),
      ])
    let out = processOCRRecord(record, resolver: resolver)

    XCTAssertEqual(out.imageId, "case1__front")
    XCTAssertEqual(out.lineCount, 5)
    XCTAssertEqual(out.detections.count, 4)

    let ids = out.detections.map(\.ingredientId)
    XCTAssertTrue(ids.contains(1))    // egg (lexicon exact)
    XCTAssertTrue(ids.contains(13))   // milk (lexicon exact)
    XCTAssertTrue(ids.contains(7))    // tomato (lexicon fuzzy)
    XCTAssertTrue(ids.contains(101))  // tomato ketchup (catalog fuzzy)

    for d in out.detections {
      switch d.ingredientId {
      case 1, 13:
        XCTAssertEqual(d.bucket, "auto")
        XCTAssertEqual(d.kind, "exact")
        XCTAssertEqual(d.confidence, 0.90, accuracy: 0.0001)
      case 7:
        XCTAssertEqual(d.bucket, "confirm")
        XCTAssertEqual(d.kind, "fuzzy")
        XCTAssertEqual(d.confidence, 0.60, accuracy: 0.0001)
      case 101:
        XCTAssertEqual(d.bucket, "confirm")
        XCTAssertEqual(d.kind, "fuzzy")
        XCTAssertEqual(d.confidence, 0.55, accuracy: 0.0001)
      default:
        XCTFail("unexpected ingredient \(d.ingredientId)")
      }
      XCTAssertEqual(d.boundingBox?.count, 4)
    }

    // Egg line first in the record; sorted by confidence (all ties here keep stable order).
    XCTAssertEqual(out.detections.first?.ingredientId, 1)
  }

  func testProcessOCRRecordDedupKeepsHighestConfidenceThenExactKind() throws {
    let resolver = try makeResolver()
    let record = OCRRecordInput(
      imageId: "case2__front", code: nil, role: "front",
      width: 1000, height: 800,
      lines: [
        LineInput(text: "eggs", x0: 0, y0: 0, x1: 100, y1: 20, conf: 80),
        LineInput(text: "large eggs", x0: 0, y0: 30, x1: 100, y1: 50, conf: 81),
      ])
    let out = processOCRRecord(record, resolver: resolver)
    XCTAssertEqual(out.detections.count, 1)
    XCTAssertEqual(out.detections.first?.ingredientId, 1)
    XCTAssertEqual(out.detections.first?.kind, "exact")
  }

  func testNormalizedBoundingBoxConvertsToVisionSpace() {
    let line = LineInput(text: "x", x0: 100, y0: 700, x1: 300, y1: 750, conf: 90)
    let bbox = normalizedBoundingBox(line, width: 1000, height: 800)
    XCTAssertNotNil(bbox)
    XCTAssertEqual(bbox?.minX ?? -1, 0.10, accuracy: 0.0001)
    XCTAssertEqual(bbox?.minY ?? -1, 1 - 750.0 / 800.0, accuracy: 0.0001)
    XCTAssertEqual(bbox?.width ?? -1, 0.20, accuracy: 0.0001)
    XCTAssertEqual(bbox?.height ?? -1, 50.0 / 800.0, accuracy: 0.0001)
    XCTAssertNil(normalizedBoundingBox(line, width: 0, height: 800))
  }
}
