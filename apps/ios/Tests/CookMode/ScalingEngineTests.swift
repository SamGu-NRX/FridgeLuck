import FLFeatureLogic
import XCTest

/// Quantity scaling across servings — the LeChef §5 table: linear by default, the reviewed
/// exceptions, and unknown evidence that never scales.
final class ScalingEngineTests: XCTestCase {
  private func line(_ key: String, _ quantity: CookQuantity, class ingredientClass: String? = nil, required: Bool = true) -> CookScaleLine {
    CookScaleLine(key: key, ingredientClass: ingredientClass, quantity: quantity, required: required)
  }

  private func amount(_ quantity: CookQuantity) -> Double {
    switch quantity {
    case let .grams(grams): return grams
    case let .household(grams, _, _): return grams
    case let .count(grams, _, _): return grams
    case .unknown: return .nan
    }
  }

  // MARK: - Linear default

  func testLinearGramsAndHousehold() {
    let scaled = ScalingEngine.scale(
      [
        line("flour", .grams(400)),
        line("stock", .household(amount: 2, unit: "cans", grams: 800)),
        line("parsley", .count(amount: 2, unit: "bunches", grams: 60), required: false),
      ],
      from: 2, to: 6)

    XCTAssertEqual(scaled[0].quantity, .grams(1200))
    XCTAssertTrue(scaled[0].changed)
    XCTAssertNil(scaled[0].caption)
    XCTAssertEqual(scaled[1].quantity, .household(amount: 6, unit: "cans", grams: 2400), "household amounts keep their unit text")
    XCTAssertEqual(scaled[2].quantity, .count(amount: 6, unit: "bunches", grams: 180), "counted amounts round to whole items")
  }

  func testHalvingServesTwo() {
    let scaled = ScalingEngine.scale([line("rice", .grams(300))], from: 4, to: 2)
    XCTAssertEqual(scaled[0].quantity, .grams(150))
  }

  func testUnknownEvidenceNeverScales() {
    let scaled = ScalingEngine.scale([line("salt_pinch", .unknown(note: "to taste"))], from: 2, to: 8)
    XCTAssertEqual(scaled[0].quantity, .unknown(note: "to taste"))
    XCTAssertFalse(scaled[0].changed)
    XCTAssertEqual(scaled[0].caption, "check amount", "an unknown line holds and says to check — never an invented mass")
  }

  func testDegenerateServingsKeepQuantitiesAndSayCheck() {
    let scaled = ScalingEngine.scale([line("flour", .grams(400))], from: 0, to: 4)
    XCTAssertEqual(scaled[0].quantity, .grams(400))
    XCTAssertEqual(scaled[0].caption, "check amount")
  }

  // MARK: - Rule table

  func testToTasteDoesNotScale() {
    let scaled = ScalingEngine.scale(
      [
        line("salt", .household(amount: 1, unit: "tsp", grams: 6), class: "salt"),
        line("chili", .grams(2), class: "chili"),
      ],
      from: 2, to: 10)

    XCTAssertEqual(scaled[0].quantity, .household(amount: 1, unit: "tsp", grams: 6))
    XCTAssertFalse(scaled[0].changed)
    XCTAssertEqual(scaled[0].rule, .toTaste)
    XCTAssertEqual(scaled[0].caption, "season to taste — didn't scale")
    XCTAssertEqual(scaled[1].quantity, .grams(2))
    XCTAssertEqual(scaled[1].rule, .toTaste)
  }

  func testDriedHerbsScaleSubLinearly() {
    // 2 → 8 servings: the multiplier is √(8/2) = 2, so 2 tsp → 4 tsp (not 8).
    let scaled = ScalingEngine.scale([line("oregano", .household(amount: 2, unit: "tsp", grams: 2), class: "dried_herbs")], from: 2, to: 8)
    XCTAssertEqual(amount(scaled[0].quantity), 4, accuracy: 0.001, "√(8/2) = 2×")
    XCTAssertEqual(scaled[0].rule, .subLinear)
    XCTAssertEqual(scaled[0].caption, "dried herbs — scaled less, they concentrate")

    // 2 → 3 servings: √(3/2) ≈ 1.2247; 2 tsp → 2.4494 → rounds to 2.5 tsp at ¼ steps.
    let gentle = ScalingEngine.scale([line("thyme", .household(amount: 2, unit: "tsp", grams: 2), class: "dried_herbs")], from: 2, to: 3)
    XCTAssertEqual(amount(gentle[0].quantity), 2.5, accuracy: 0.001, "quarter-tsp rounding on small household measures")
  }

  func testCountHoldScalesAndFlagsEquipment() {
    let scaled = ScalingEngine.scale([line("eggs", .count(amount: 2, unit: "eggs", grams: 100), class: "egg")], from: 2, to: 6)
    XCTAssertEqual(scaled[0].quantity, .count(amount: 6, unit: "eggs", grams: 300))
    XCTAssertEqual(scaled[0].rule, .countHold)
    XCTAssertTrue(scaled[0].needsEquipmentCheck, "count-hold lines ask for an equipment check")
    XCTAssertEqual(scaled[0].caption, "eggs scaled — check the pan fits them")
  }

  func testLinearCountKeepsHalfItemsHonest() {
    let scaled = ScalingEngine.scale([line("carrots", .count(amount: 3, unit: "carrots", grams: 180))], from: 4, to: 6)
    XCTAssertEqual(amount(scaled[0].quantity), 4.5, accuracy: 0.001, "4.5 carrots is the honest linear result; the unit text says what it is")
  }

  // MARK: - Time adaptation (LeChef §5, PR #86 §3.1)

  func testTimeAdaptationTable() {
    let table: [(String, Int, Int, Int, Bool, Double?, Int, Bool, Int?, String?)] = [
      // (name, seconds, from, to, thicknessChanged, panFactor, batchCount, singlePanLoadDoubled,
      //  expectedSeconds — nil means unchanged, expectedCaptionSubstring)
      ("no rule applies — check, don't trust the timer", 600, 2, 4, false, nil, 1, false, nil, "check"),
      ("thickness in proportion, in bounds", 600, 2, 2, true, nil, 1, false, 600, "thickness changed"),
      ("thickness bound caps at +25%", 600, 2, 4, true, nil, 1, false, 750, "thickness changed"),
      ("pan factor divides and bounds", 600, 2, 2, false, 2, 1, false, 450, "pan changed"),
      ("pan factor bound holds the proposal", 600, 2, 2, false, 3, 1, false, 450, "pan changed"),
      ("batches multiply the total", 600, 2, 4, false, nil, 3, false, 1800, "3 batches"),
      ("single pan load doubled never invents a number", 600, 2, 4, false, nil, 1, true, 600, "check, don't trust the timer"),
      ("zero-second steps are untouched", 0, 2, 4, true, 2, 2, false, 0, "check"),
    ]

    for (name, seconds, from, to, thickness, panFactor, batches, doubled, expectedSeconds, captionPart) in table {
      let result = ScalingEngine.adaptTime(
        seconds: seconds, from: from, to: to,
        thicknessChanged: thickness, panFactor: panFactor, batchCount: batches, singlePanLoadDoubled: doubled)

      if let expectedSeconds, expectedSeconds != seconds {
        XCTAssertEqual(result.seconds, expectedSeconds, name)
        XCTAssertTrue(result.changed, name)
      } else {
        XCTAssertFalse(result.changed, name)
        XCTAssertEqual(result.seconds, seconds, name)
      }
      XCTAssertTrue(result.caption.contains(captionPart ?? ""), "\(name): \(result.caption)")
    }

    // The −25 % bound: a 4× servings change × 600 s clamps at 450 s.
    let shrink = ScalingEngine.adaptTime(seconds: 600, from: 4, to: 1, thicknessChanged: true)
    XCTAssertEqual(shrink.seconds, 450)
    XCTAssertTrue(shrink.caption.contains("thickness changed"))
  }

  func testThicknessAdaptationIsBounded() {
    // 2 → 20 servings would be 10× the time; the rule caps it at +25 %.
    let result = ScalingEngine.adaptTime(seconds: 600, from: 2, to: 20, thicknessChanged: true)
    XCTAssertEqual(result.seconds, 750, "the ±25 % bound holds")
  }

  func testPanFactorSmallerPanChecksLaterWithinBounds() {
    let result = ScalingEngine.adaptTime(seconds: 600, from: 2, to: 2, panFactor: 0.5)
    XCTAssertEqual(result.seconds, 750, "a halved pan factor proposes 2× the time, clamped to +25 %")
  }

  func testUnchangedProposalCarriesTheCheckCaption() {
    // A thickness flag with no actual servings change proposes the same seconds and still
    // tells the cook what to watch.
    let result = ScalingEngine.adaptTime(seconds: 600, from: 2, to: 2, thicknessChanged: true)
    XCTAssertFalse(result.changed)
    XCTAssertTrue(result.caption.contains("thickness changed"))
  }
}
