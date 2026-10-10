import FLBarcode
import XCTest

/// Package mass normalization: grams come only from explicit mass evidence; prices,
/// counts, serving sizes, and volumes never become grams.
final class PackageMassTests: XCTestCase {
  func testExplicitGrams() {
    let parsed = PackageMassParser.mass(in: "250 g")
    XCTAssertEqual(parsed.grams, 250.0)
    XCTAssertEqual(parsed.rawText, "250 g")
    XCTAssertNil(parsed.rejection)
  }

  func testExplicitKilograms() {
    XCTAssertEqual(PackageMassParser.mass(in: "1 kg").grams, 1000.0)
    XCTAssertEqual(PackageMassParser.mass(in: "1,5 kg").grams, 1500.0)
    XCTAssertEqual(PackageMassParser.mass(in: "2.5kg").grams, 2500.0)
  }

  func testExplicitOunces() {
    let parsed = PackageMassParser.mass(in: "16 oz")
    XCTAssertEqual(parsed.grams ?? 0, 453.6, accuracy: 0.1)
    XCTAssertEqual(parsed.rawText, "16 oz")
  }

  func testExplicitPounds() {
    XCTAssertEqual(PackageMassParser.mass(in: "1 lb").grams ?? 0, 453.6, accuracy: 0.1)
    XCTAssertEqual(PackageMassParser.mass(in: "2 lbs").grams ?? 0, 907.2, accuracy: 0.1)
  }

  /// "NET WT" context: the net weight is explicit mass evidence wherever it appears.
  func testNetWeightPrefix() {
    let parsed = PackageMassParser.mass(in: "NET WT 454 G")
    XCTAssertEqual(parsed.grams, 454.0)
    XCTAssertNotNil(parsed.rawText)
  }

  /// First explicit mass wins; the parenthetical metric duplicate is not double-counted.
  func testParentheticalDuplicateWeight() {
    let parsed = PackageMassParser.mass(in: "NET WT 16 OZ (454 G)")
    XCTAssertEqual(parsed.grams ?? 0, 453.6, accuracy: 0.1)
  }

  /// "6 x 250 g" is explicit: six units of a stated unit mass — 1500 g, not 250 g.
  func testMultipackTotals() {
    let parsed = PackageMassParser.mass(in: "6 x 250 g")
    XCTAssertEqual(parsed.grams, 1500.0)
    XCTAssertEqual(parsed.rawText, "6 x 250 g")
    XCTAssertEqual(PackageMassParser.mass(in: "6x250g").grams, 1500.0)
    XCTAssertEqual(PackageMassParser.mass(in: "6 × 250 g").grams, 1500.0)
    XCTAssertEqual(PackageMassParser.mass(in: "12 x 40 g").grams, 480.0)
  }

  // MARK: - Missing mass

  func testMissingMassStaysUnknown() {
    for text in [nil as String?, "", "   ", "organic", "Grande", "famille"] {
      let parsed = PackageMassParser.mass(in: text)
      XCTAssertNil(parsed.grams, String(describing: text))
      XCTAssertEqual(parsed.rejection, .noMassEvidence, String(describing: text))
    }
  }

  // MARK: - Counts never become grams

  func testBareCountsNeverBecomeGrams() {
    for text in ["6", "x6", "x 6", "12 pack", "6 bottles", "24 cans", "10 pieces", "3 ct"] {
      let parsed = PackageMassParser.mass(in: text)
      XCTAssertNil(parsed.grams, text)
      XCTAssertEqual(parsed.rejection, .countOnly, text)
    }
  }

  // MARK: - Serving sizes never become grams

  func testServingSizesNeverBecomeGrams() {
    for text in ["serving size 30 g", "per 100 g serving", "30 g per portion", "per serving"] {
      let parsed = PackageMassParser.mass(in: text)
      XCTAssertNil(parsed.grams, text)
      XCTAssertEqual(parsed.rejection, .servingSizeOnly, text)
    }
  }

  // MARK: - Prices never become grams

  func testPricesNeverBecomeGrams() {
    for text in ["$4.50", "2 for $5.00", "4,50 €", "£3.20", "2 for 5.00"] {
      let parsed = PackageMassParser.mass(in: text)
      XCTAssertNil(parsed.grams, text)
      XCTAssertEqual(parsed.rejection, .priceOnly, text)
    }
  }

  // MARK: - Volumes never become grams

  func testVolumesNeverBecomeGrams() {
    for text in ["500 ml", "1 l", "1 L", "33 cl", "1.89 L", "12 fl oz"] {
      let parsed = PackageMassParser.mass(in: text)
      XCTAssertNil(parsed.grams, text)
      XCTAssertEqual(parsed.rejection, .volumeOnly, text)
    }
  }

  /// A multipack of a volume ("6 x 1 l") is still not a mass.
  func testVolumeMultipackIsNotMass() {
    let parsed = PackageMassParser.mass(in: "6 x 1 l")
    XCTAssertNil(parsed.grams)
    XCTAssertEqual(parsed.rejection, .volumeOnly)
  }

  /// Implausible masses (misreads) are rejected rather than trusted.
  func testImplausibleMassRejected() {
    let parsed = PackageMassParser.mass(in: "999999 g")
    XCTAssertNil(parsed.grams)
  }
}
