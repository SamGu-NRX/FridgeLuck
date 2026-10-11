import Foundation

/// The GS1 barcode formats FridgeLuck accepts at intake.
public enum GTINFormat: String, Sendable, CaseIterable, Equatable, Codable {
  case gtin8
  case upcA
  case ean13
  case gtin14

  public var digitCount: Int {
    switch self {
    case .gtin8: return 8
    case .upcA: return 12
    case .ean13: return 13
    case .gtin14: return 14
    }
  }
}

/// A GTIN that passed length and check-digit validation. The entered digits are kept
/// verbatim (including leading zeros); the canonical zero-padded GTIN-14 is the identity
/// used for caching and dedupe, so a UPC-A and its zero-padded GTIN-14 are one product.
public struct ValidatedGTIN: Sendable, Equatable, Hashable, Codable {
  /// The digits as entered, including any leading zeros.
  public let digits: String
  public let format: GTINFormat
  /// Zero-padded 14-digit form.
  public let canonicalGTIN14: String

  /// Construct only through `GTINValidator.validate`, which enforces length and checksum.
  init(digitsInternal: String, format: GTINFormat, canonicalGTIN14: String) {
    self.digits = digitsInternal
    self.format = format
    self.canonicalGTIN14 = canonicalGTIN14
  }
}

public enum GTINValidationError: Error, Equatable, Sendable {
  case empty
  case notDigits
  case unsupportedLength(digitCount: Int)
  case checksumMismatch
}

/// Validates GTIN-8, UPC-A (12 digits), EAN-13 (13 digits), and GTIN-14 (mod-10 check).
///
/// Leading-zero forms are accepted: a UPC-A encoded as a 13-digit EAN-13 with a leading 0,
/// or zero-padded out to 14 digits, all validate and normalize to the same canonical
/// GTIN-14. Zeros are never stripped — an entered leading zero is part of the number.
public enum GTINValidator {
  /// Strips surrounding whitespace and interior spaces or hyphens before validating, so
  /// manual entry ("0360 0029 1452") behaves like a scan.
  public static func validate(_ raw: String) throws -> ValidatedGTIN {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")

    guard !trimmed.isEmpty else { throw GTINValidationError.empty }
    guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      throw GTINValidationError.notDigits
    }
    guard let format = GTINFormat.allCases.first(where: { $0.digitCount == trimmed.count }) else {
      throw GTINValidationError.unsupportedLength(digitCount: trimmed.count)
    }
    guard Self.checkDigitMatches(trimmed) else { throw GTINValidationError.checksumMismatch }

    let padding = String(repeating: "0", count: 14 - trimmed.count)
    return ValidatedGTIN(
      digitsInternal: trimmed,
      format: format,
      canonicalGTIN14: padding + trimmed
    )
  }

  /// GS1 mod-10 check: from the rightmost body digit moving left, weights alternate 3, 1.
  /// The check digit makes the total a multiple of 10. The same rule validates every GTIN
  /// length, which is why zero-padding never changes a check digit.
  public static func checkDigit(for bodyDigits: String) -> Int? {
    let body = bodyDigits.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

    var sum = 0
    var weight = 3
    for character in body.reversed() {
      guard let digit = character.wholeNumberValue else { return nil }
      sum += digit * weight
      weight = weight == 3 ? 1 : 3
    }
    return (10 - sum % 10) % 10
  }

  static func checkDigitMatches(_ digits: String) -> Bool {
    guard let entered = digits.last?.wholeNumberValue,
      let expected = checkDigit(for: String(digits.dropLast()))
    else { return false }
    return entered == expected
  }
}
