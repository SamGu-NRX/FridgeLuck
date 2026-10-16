import FLFeatureLogic
import XCTest

/// Codable contracts against the recipe bundle v2 wire shape
/// (`docs/spec/recipes/contracts/recipe-bundle-v2.schema.json`): the schema's
/// `additionalProperties: false` means every key we emit must be one it names.
final class CookStepCodableTests: XCTestCase {
  // MARK: - Thermometer

  func testThermometerDecodesTheBundleV2WireShape() throws {
    // The schema's `$defs.step.thermometer` uses snake_case; the decoder must read it verbatim.
    let json = #"{"endpoint_c": 74, "food": "chicken thigh, thickest piece", "source": "usda-fsis: poultry 165 F"}"#
    let data = Data(json.utf8)

    let thermometer = try JSONDecoder().decode(CookThermometer.self, from: data)
    XCTAssertEqual(thermometer.endpointC, 74)
    XCTAssertEqual(thermometer.food, "chicken thigh, thickest piece")
    XCTAssertEqual(thermometer.source, "usda-fsis: poultry 165 F")
  }

  func testThermometerStepDecodesAndRoundTripsThroughTheWireShape() throws {
    let json = """
    {"text": "Roast until done.", "uses": [0], "timer_seconds": 2700,
     "thermometer": {"endpoint_c": 74, "food": "chicken thigh", "source": "usda-fsis: poultry 165 F"}}
    """
    let step = try JSONDecoder().decode(CookStep.self, from: Data(json.utf8))
    XCTAssertEqual(step.thermometer?.endpointC, 74)
    XCTAssertEqual(step.timerSeconds, 2700)

    // Encoding writes only schema-named keys and reads back identically.
    let encoded = try JSONEncoder().encode(step)
    let roundTripped = try JSONDecoder().decode(CookStep.self, from: encoded)
    XCTAssertEqual(roundTripped, step)
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let thermometerObject = try XCTUnwrap(object["thermometer"] as? [String: Any])
    XCTAssertEqual(thermometerObject["endpoint_c"] as? Double, 74, "the wire key is endpoint_c, not endpointC")
    XCTAssertNil(thermometerObject["endpointC"], "no camelCase key may reach the wire")
  }

  // MARK: - Quantity

  func testQuantityEncodingKeepsTheSchemaRequiredGramsKey() throws {
    // `$defs.quantity`'s household/count variants require the `grams` key (nullable):
    // an unknown conversion is an explicit null on the wire, never an absent key.
    for quantity in [CookQuantity.household(amount: 2, unit: "cans", grams: nil),
                     CookQuantity.count(amount: 3, unit: "large", grams: nil)] {
      let encoded = try JSONEncoder().encode([quantity])
      let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
      XCTAssertEqual(object.first?["grams"] as? NSNull, NSNull(), "\(quantity): grams stays an explicit null")
    }

    // A known conversion still encodes its number, and everything round-trips.
    let known = CookQuantity.household(amount: 1, unit: "cup", grams: 240)
    let encoded = try JSONEncoder().encode([known])
    let back = try JSONDecoder().decode([CookQuantity].self, from: encoded)
    XCTAssertEqual(back, [known])
  }
}
