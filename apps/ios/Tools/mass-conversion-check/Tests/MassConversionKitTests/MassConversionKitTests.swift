import XCTest

@testable import MassConversionKit

/// Contract tests binding the MassConversionKit API to the pinned USDA FNDDS
/// household-measure evidence (edition 2024-10-31).
final class MassConversionTableTests: XCTestCase {
  var table: MassConversionTable!

  override func setUpWithError() throws {
    table = try MassConversionTable.bundled
  }

  func testBundledTableLoadsAndCoversEvidence() throws {
    XCTAssertGreaterThanOrEqual(table.portions.count, 7000)
    XCTAssertEqual(table.source.edition, "2024-10-31")
    XCTAssertEqual(
      table.source.dataset, "USDA FoodData Central Survey Foods (FNDDS)")
    XCTAssertFalse(table.source.archiveSha256.isEmpty)
    XCTAssertFalse(table.source.surveyJsonSha256.isEmpty)
  }

  func testOliveOilTablespoon() throws {
    let grams = table.grams(food: "olive oil", unit: .tbsp)
    let value = try XCTUnwrap(grams)
    XCTAssertEqual(value, 14.0, accuracy: 1e-6)
  }

  func testWholeMilkCup() throws {
    let grams = table.grams(food: "milk, whole", unit: .cup)
    let value = try XCTUnwrap(grams)
    XCTAssertEqual(value, 244.0, accuracy: 1e-6)
  }

  func testWholeMilkFluidOunceIsNotWeightOunce() throws {
    let fluid = try XCTUnwrap(table.grams(food: "milk, whole", unit: .floz))
    XCTAssertEqual(fluid, 30.5, accuracy: 1e-6)
    // A fluid ounce of milk must not collapse to the 28.35 g weight ounce.
    XCTAssertGreaterThan(fluid - 28.35, 1.5)
  }

  func testEggUnit() throws {
    let grams = table.grams(food: "egg, whole, raw", unit: .egg)
    let value = try XCTUnwrap(grams)
    XCTAssertEqual(value, 50.0, accuracy: 1e-6)
  }

  func testCheddarStick() throws {
    let grams = table.grams(food: "cheese, cheddar", unit: .stick)
    let value = try XCTUnwrap(grams)
    XCTAssertEqual(value, 28.35, accuracy: 1e-6)
  }

  func testButterPat() throws {
    let grams = table.grams(food: "butter, nfs", unit: .pat)
    let value = try XCTUnwrap(grams)
    XCTAssertEqual(value, 7.0, accuracy: 1e-6)
  }

  func testMagnitudeScalesLinearly() throws {
    let one = try XCTUnwrap(table.grams(food: "milk, whole", unit: .cup))
    let two = try XCTUnwrap(table.grams(food: "milk, whole", unit: .cup, magnitude: 2))
    let half = try XCTUnwrap(table.grams(food: "milk, whole", unit: .cup, magnitude: 0.5))
    XCTAssertEqual(two, one * 2, accuracy: 1e-6)
    XCTAssertEqual(half, one * 0.5, accuracy: 1e-6)
  }

  func testUnknownFoodReturnsNil() {
    XCTAssertNil(table.grams(food: "qxyzplk widget", unit: .cup))
    XCTAssertNil(table.grams(food: "", unit: .cup))
  }

  func testUnitWithoutPortionReturnsNil() {
    // Milk has cup and fluid-ounce portions in FNDDS but no tablespoon row.
    XCTAssertNil(table.entry(food: "milk, whole", unit: .tsp))
  }

  func testEntryExposesFdcIdAndGramsPerUnit() throws {
    let entry = try XCTUnwrap(table.entry(food: "milk, whole", unit: .cup))
    XCTAssertEqual(entry.fdcId, 2705385)
    XCTAssertEqual(entry.food, "Milk, whole")
    XCTAssertEqual(entry.gramsPerUnit, 244.0, accuracy: 1e-6)
  }

  func testFlexibleUnitNames() {
    XCTAssertEqual(HouseholdUnit(flexibleName: "Tablespoons"), .tbsp)
    XCTAssertEqual(HouseholdUnit(flexibleName: "cups"), .cup)
    XCTAssertEqual(HouseholdUnit(flexibleName: "fl oz"), .floz)
    XCTAssertEqual(HouseholdUnit(flexibleName: "fluid ounce"), .floz)
    XCTAssertEqual(HouseholdUnit(flexibleName: "ounce"), .oz)
    XCTAssertEqual(HouseholdUnit(flexibleName: "pkg"), .package)
    XCTAssertEqual(HouseholdUnit(flexibleName: "eggs"), .egg)
    XCTAssertNil(HouseholdUnit(flexibleName: "handful"))
  }

  func testLookupIsDeterministic() throws {
    let first = table.entry(food: "milk", unit: .cup)
    for _ in 0..<10 {
      XCTAssertEqual(table.entry(food: "milk", unit: .cup), first)
    }
  }
}

final class ConversionEvidenceTests: XCTestCase {
  private func syntheticTable() throws -> MassConversionTable {
    let source = MassConversionSource(
      dataset: "test", edition: "test", url: "test", archiveSha256: "test",
      surveyJsonSha256: "test")
    let entries = [
      MassConversionEntry(
        fdcId: 1, food: "Tomatoes, red, fresh", unit: .cup, magnitude: 1,
        grams: 150, state: "raw", packing: nil),
      MassConversionEntry(
        fdcId: 2, food: "Tomatoes, red, canned", unit: .cup, magnitude: 1,
        grams: 240, state: nil, packing: "canned"),
      MassConversionEntry(
        fdcId: 3, food: "Beans, baked, canned", unit: .cup, magnitude: 1,
        grams: 255, state: "cooked", packing: "canned"),
      MassConversionEntry(
        fdcId: 4, food: "Instant coffee, dry powder", unit: .tsp,
        magnitude: 1, grams: 1, state: "dried", packing: nil),
    ]
    return MassConversionTable(source: source, portions: entries)
  }

  func testExactEvidenceWhenTokensFullyCoverEntry() throws {
    let table = try syntheticTable()
    let conversion = table.convert(food: "Beans, baked, canned", unit: .cup)
    XCTAssertEqual(conversion?.evidence, .exact)
    XCTAssertEqual(conversion?.grams, 255)
  }

  func testPartialEvidenceOnTokenOverlap() throws {
    let table = try syntheticTable()
    // "tomatoes" overlaps entry tokens without fully covering them —
    // singular "tomato" would not overlap at all (no stemming).
    let conversion = table.convert(food: "tomatoes, red", unit: .cup)
    XCTAssertEqual(conversion?.evidence, .partial)
  }

  func testUnknownFoodYieldsNoConversion() throws {
    let table = try syntheticTable()
    XCTAssertNil(table.convert(food: "wasabi", unit: .cup))
  }

  func testCannedQueryPrefersCannedPacking() throws {
    let table = try syntheticTable()
    let conversion = table.convert(food: "canned tomatoes", unit: .cup)
    XCTAssertEqual(conversion?.packing, "canned")
    XCTAssertEqual(conversion?.grams, 240)
  }

  func testDryQueryAvoidsConflictingState() throws {
    let table = try syntheticTable()
    let conversion = table.convert(food: "coffee, dry", unit: .tsp)
    XCTAssertEqual(conversion?.state, "dried")
    XCTAssertEqual(conversion?.grams, 1)
  }

  func testQueryStateNegation() {
    XCTAssertEqual(
      MassConversionTable.queryState(in: ["not", "reconstituted"]), "dried")
    XCTAssertEqual(
      MassConversionTable.queryState(in: ["reconstituted"]), "cooked")
    XCTAssertEqual(MassConversionTable.queryState(in: ["prepared"]), "cooked")
  }
}

final class HouseholdQuantityTests: XCTestCase {
  func testSingleQuantity() {
    let q = HouseholdQuantity(text: "2 tbsp")
    XCTAssertEqual(q?.unit, .tbsp)
    XCTAssertEqual(q?.low, 2)
    XCTAssertFalse(q?.isRange ?? true)
  }

  func testFractionQuantity() {
    let q = HouseholdQuantity(text: "1/2 cup")
    XCTAssertEqual(q?.low, 0.5)
    XCTAssertEqual(q?.high, 0.5)
  }

  func testMixedFractionQuantity() {
    let q = HouseholdQuantity(text: "1-1/2 cups")
    XCTAssertEqual(q?.low ?? 0, 1.5, accuracy: 0.0001)
    XCTAssertFalse(q?.isRange ?? true)
  }

  func testRangeQuantity() {
    let q = HouseholdQuantity(text: "1-2 cups")
    XCTAssertEqual(q?.low, 1)
    XCTAssertEqual(q?.high, 2)
    XCTAssertTrue(q?.isRange ?? false)
  }

  func testFractionRangeQuantity() {
    let q = HouseholdQuantity(text: "1/2-1 cup")
    XCTAssertEqual(q?.low ?? 0, 0.5, accuracy: 0.0001)
    XCTAssertEqual(q?.high, 1)
  }

  func testMidpoint() {
    let q = HouseholdQuantity(text: "1-2 cups")
    XCTAssertEqual(q?.midpoint ?? 0, 1.5, accuracy: 0.0001)
  }

  func testRejectsUnknownUnitAndGarbage() {
    XCTAssertNil(HouseholdQuantity(text: "2 splashes"))
    XCTAssertNil(HouseholdQuantity(text: "cups"))
    XCTAssertNil(HouseholdQuantity(text: ""))
    XCTAssertNil(HouseholdQuantity(text: "0-1 cup"))
  }

  func testGramsRangeConvertsBothEnds() throws {
    let source = MassConversionSource(
      dataset: "test", edition: "test", url: "test", archiveSha256: "test",
      surveyJsonSha256: "test")
    let table = MassConversionTable(
      source: source,
      portions: [
        MassConversionEntry(
          fdcId: 9, food: "whole milk", unit: .cup, magnitude: 1, grams: 244)
      ])
    guard let q = HouseholdQuantity(text: "1-2 cups") else {
      return XCTFail("quantity should parse")
    }
    let range = table.gramsRange(food: "whole milk", quantity: q)
    XCTAssertEqual(range?.low ?? 0, 244, accuracy: 0.0001)
    XCTAssertEqual(range?.high ?? 0, 488, accuracy: 0.0001)
  }
}

/// Guards that the bundled resource stays byte-identical to the pinned
/// reference table generated by scripts/data/extract_household_measures.py.
final class ResourceSyncTests: XCTestCase {
  func testBundledResourceMatchesPinnedReference() throws {
    // Test file: apps/ios/Tools/mass-conversion-check/Tests/MassConversionKitTests/
    let testFile = URL(fileURLWithPath: #filePath)
    let repoRoot = testFile
      .deletingLastPathComponent()  // the test file itself -> Tests/MassConversionKitTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // mass-conversion-check
      .deletingLastPathComponent()  // Tools
      .deletingLastPathComponent()  // apps/ios
      .deletingLastPathComponent()  // apps
      .deletingLastPathComponent()  // repo root
    let pinned = repoRoot
      .appendingPathComponent("scripts/data/reference/household_measures/mass_conversion_table.json")
    let pinnedData = try Data(contentsOf: pinned)

    let bundleURL = try XCTUnwrap(
      Bundle.module.url(
        forResource: "mass_conversion_table", withExtension: "json"))
    let bundledData = try Data(contentsOf: bundleURL)

    XCTAssertEqual(bundledData, pinnedData)
  }
}
