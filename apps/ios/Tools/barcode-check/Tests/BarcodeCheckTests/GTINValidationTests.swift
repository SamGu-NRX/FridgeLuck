import FLBarcode
import XCTest

/// GTIN validation: formats, mod-10 checksums, leading-zero forms, canonical GTIN-14.
final class GTINValidationTests: XCTestCase {
  func testValidUPCA() throws {
    let gtin = try GTINValidator.validate("036000291452")
    XCTAssertEqual(gtin.format, .upcA)
    XCTAssertEqual(gtin.digits, "036000291452")
    XCTAssertEqual(gtin.canonicalGTIN14, "00036000291452")
  }

  func testValidEAN13() throws {
    let gtin = try GTINValidator.validate("4006381333931")
    XCTAssertEqual(gtin.format, .ean13)
    XCTAssertEqual(gtin.canonicalGTIN14, "04006381333931")
  }

  func testValidGTIN8() throws {
    let gtin = try GTINValidator.validate("73513537")
    XCTAssertEqual(gtin.format, .gtin8)
    XCTAssertEqual(gtin.canonicalGTIN14, "00000073513537")
  }

  func testValidGTIN14() throws {
    let gtin = try GTINValidator.validate("00036000291452")
    XCTAssertEqual(gtin.format, .gtin14)
    XCTAssertEqual(gtin.canonicalGTIN14, "00036000291452")
  }

  /// Leading-zero forms: a UPC-A entered as 13-digit EAN-13, or padded to 14, is the
  /// same product — all validate and normalize to one canonical GTIN-14.
  func testLeadingZeroFormsNormalizeToSameCanonicalGTIN() throws {
    let upcA = try GTINValidator.validate("036000291452")
    let ean13 = try GTINValidator.validate("0036000291452")
    let padded14 = try GTINValidator.validate("00036000291452")

    XCTAssertEqual(upcA.canonicalGTIN14, ean13.canonicalGTIN14)
    XCTAssertEqual(upcA.canonicalGTIN14, padded14.canonicalGTIN14)
    XCTAssertEqual(ean13.format, .ean13)
    XCTAssertEqual(padded14.format, .gtin14)
  }

  /// Leading zeros are never stripped: a 13-digit string that starts with 0 is validated
  /// as-is (and only a valid check digit passes).
  func testEnteredLeadingZerosAreKeptVerbatim() throws {
    let gtin = try GTINValidator.validate("0036000291452")
    XCTAssertEqual(gtin.digits, "0036000291452")
  }

  func testSpacesAndDashesAreIgnored() throws {
    let gtin = try GTINValidator.validate("0360 0029 1452")
    XCTAssertEqual(gtin.digits, "036000291452")
    XCTAssertEqual(try GTINValidator.validate("036-000-291-452").digits, "036000291452")
  }

  func testBadChecksumRejected() {
    XCTAssertThrowsError(try GTINValidator.validate("036000291453")) { error in
      XCTAssertEqual(error as? GTINValidationError, .checksumMismatch)
    }
    XCTAssertThrowsError(try GTINValidator.validate("4006381333932")) { error in
      XCTAssertEqual(error as? GTINValidationError, .checksumMismatch)
    }
  }

  func testWrongLengthsRejected() {
    for raw in ["1234567", "123456789", "1234567890", "12345", "1234567890123456"] {
      XCTAssertThrowsError(try GTINValidator.validate(raw), raw) { error in
        XCTAssertEqual(
          error as? GTINValidationError, .unsupportedLength(digitCount: raw.count), raw)
      }
    }
  }

  func testNonDigitsRejected() {
    assertError("03600029145X", .notDigits)
    assertError("abcdefghijkl", .notDigits)
    assertError("", .empty)
    assertError("   ", .empty)
  }

  private func assertError(
    _ raw: String,
    _ expected: GTINValidationError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      _ = try GTINValidator.validate(raw)
      XCTFail("expected \(expected) for \(raw)", file: file, line: line)
    } catch let error as GTINValidationError {
      XCTAssertEqual(error, expected, raw, file: file, line: line)
    } catch {
      XCTFail("unexpected error type \(error)", file: file, line: line)
    }
  }

  func testCheckDigitComputation() {
    XCTAssertEqual(GTINValidator.checkDigit(for: "03600029145"), 2)
    XCTAssertEqual(GTINValidator.checkDigit(for: "400638133393"), 1)
    XCTAssertEqual(GTINValidator.checkDigit(for: "7351353"), 7)
    XCTAssertNil(GTINValidator.checkDigit(for: ""))
    XCTAssertNil(GTINValidator.checkDigit(for: "abc"))
  }
}
