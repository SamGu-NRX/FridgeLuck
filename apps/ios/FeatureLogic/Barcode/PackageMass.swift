import Foundation

/// Why a product's packaging text yielded no usable mass. Every rejection is a case the
/// review can show the user instead of a silently invented number.
public enum PackageMassRejection: String, Sendable, Equatable, Codable {
  /// Nothing mass-like in the text at all (empty, or free text).
  case noMassEvidence
  /// A bare count ("6", "x6", "12 pack") — a count is not a mass without a unit mass.
  case countOnly
  /// A serving size ("serving size 30 g", "per 100 g") — a portion is not the package.
  case servingSizeOnly
  /// A price ("$4.50", "2 for $5.00") — money says nothing about grams.
  case priceOnly
  /// A volume ("500 ml", "1 L") — volume without density is not mass.
  case volumeOnly
}

/// The mass read off a product's packaging. `grams == nil` means the text carried no
/// usable mass — the amount stays unknown and the review asks the user; nothing here
/// converts prices, counts, serving sizes, or volumes into grams.
public struct ParsedPackageMass: Sendable, Equatable, Codable {
  /// Explicit package mass in grams, when the text carried mass evidence.
  public let grams: Double?
  /// The exact substring the grams were read from, as review evidence.
  public let rawText: String?
  /// Why the mass is unknown; `nil` when `grams` is set.
  public let rejection: PackageMassRejection?

  public static func measured(_ grams: Double, evidence: String) -> ParsedPackageMass {
    ParsedPackageMass(grams: grams, rawText: evidence, rejection: nil)
  }

  public static func unknown(_ rejection: PackageMassRejection) -> ParsedPackageMass {
    ParsedPackageMass(grams: nil, rawText: nil, rejection: rejection)
  }
}

/// Reads an explicit package mass out of product quantity text ("250 g", "1 kg",
/// "16 oz", "NET WT 454 G", "6 x 250 g").
///
/// Ground rules, matching the grocery-intake honest-amount policy:
/// - Only explicit mass evidence becomes grams. Multipack mass ("6 x 250 g") is explicit:
///   six units of a stated unit mass.
/// - Prices, bare counts, serving sizes, and volumes never become grams — each gets its
///   own rejection so the review can say why the amount is unknown.
public enum PackageMassParser {
  /// Upper sanity bound for a parsed package mass; anything above is a misread, not food.
  static let maxPlausibleGrams: Double = 30_000
  static let gramsPerOunce = 28.3495
  static let gramsPerPound = 453.592

  private static let massUnitPattern =
    #"(g|gr|gram|grams|kg|kgs|kilogram|kilograms|oz|ounce|ounces|lb|lbs|pound|pounds)"#
  private static let numberPattern = #"(\d+(?:[.,]\d{1,3})?)"#

  /// Parses the mass in one quantity string. `nil` input or empty text is "no evidence".
  public static func mass(in quantityText: String?) -> ParsedPackageMass {
    guard let quantityText, !quantityText.isEmpty else {
      return .unknown(.noMassEvidence)
    }
    let lowered = quantityText.lowercased()

    // Serving context: a portion is not the package amount, even when it carries a unit.
    if lowered.contains("serving") || lowered.contains("portion") || lowered.hasPrefix("per ") {
      return .unknown(.servingSizeOnly)
    }

    if firstMatch(
      in: lowered,
      pattern: #"[$€£]|\b\d[\d.,]*\s*(?:usd|eur|gbp|dollars?|euros?)\b|\b\d+\s*for\s+\d"#) != nil
    {
      return .unknown(.priceOnly)
    }

    // Multipack first, so "6 x 250 g" totals 1500 g rather than reading a bare 250 g.
    if let multipack = parseMultipack(in: lowered) {
      return .measured(multipack.grams, evidence: multipack.rawText)
    }

    if let weight = parseExplicitWeight(in: lowered) {
      return .measured(weight.grams, evidence: weight.rawText)
    }

    if firstMatch(
      in: lowered,
      pattern: #"\d+(?:[.,]\d+)?\s*(?:ml|cl|dl|l|millilit\w*|liters?|litres?|fl\.?\s*oz|fluid\s*(?:ounce|oz)s?)\b"#
    ) != nil {
      return .unknown(.volumeOnly)
    }

    // Bare counts: a lone integer, "x6", or a count with a non-mass unit word.
    if firstMatch(
      in: lowered,
      pattern:
        #"^\s*x?\s*\d{1,3}\s*$|^\s*\d{1,3}\s*[x×]\s*$|\b\d{1,3}\s*(?:pack|pcs?|pieces?|units?|ct|count|bottles?|cans?|jars?|bars?|boxes?|bags?)\b"#
    ) != nil {
      return .unknown(.countOnly)
    }

    return .unknown(.noMassEvidence)
  }

  /// "6 x 250 g", "6x250g", "6 × 250 g" → total grams of the stated unit mass times count.
  static func parseMultipack(in lowered: String) -> (grams: Double, rawText: String)? {
    let pattern = numberPattern + #"\s*[x×]\s*"# + numberPattern + #"\s*"# + massUnitPattern
    guard let match = firstMatchGroups(in: lowered, pattern: pattern, groupCount: 3),
      let countText = match.groups[0],
      let valueText = match.groups[1],
      let count = Int(countText),
      let value = Double(valueText.replacingOccurrences(of: ",", with: "."))
    else { return nil }

    let total = Double(count) * Self.grams(forUnit: match.groups[2] ?? "", value: value)
    guard total > 0, total <= maxPlausibleGrams else { return nil }
    return (roundToTenth(total), match.full)
  }

  /// "454 g", "0.5 kg", "16 oz", "1.25 lb", "NET WT 454 G" — the first explicit mass anywhere
  /// in the text. Comma decimals are accepted only with a unit, so bare decimals stay prices.
  static func parseExplicitWeight(in lowered: String) -> (grams: Double, rawText: String)? {
    let pattern = numberPattern + #"\s*"# + massUnitPattern + #"(?![a-z])"#
    guard let match = firstMatchGroups(in: lowered, pattern: pattern, groupCount: 2),
      let valueText = match.groups[0],
      let value = Double(valueText.replacingOccurrences(of: ",", with: "."))
    else { return nil }

    let grams = Self.grams(forUnit: match.groups[1] ?? "", value: value)
    guard grams > 0, grams <= maxPlausibleGrams else { return nil }
    return (roundToTenth(grams), match.full)
  }

  private static func grams(forUnit unit: String, value: Double) -> Double {
    if unit == "g" || unit == "gr" || unit.hasPrefix("gram") { return value }
    if unit.hasPrefix("kg") || unit.hasPrefix("kilogram") { return value * 1_000 }
    if unit.hasPrefix("oz") || unit.hasPrefix("ounce") { return value * gramsPerOunce }
    return value * gramsPerPound
  }

  static func roundToTenth(_ grams: Double) -> Double {
    (grams * 10).rounded() / 10
  }

  // MARK: - Regex helpers (regexes built per call, matching repo parser style)

  static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      let matchRange = Range(match.range, in: text)
    else { return nil }
    return String(text[matchRange])
  }

  /// The full match plus its capture groups; `nil` when nothing matched. Missing groups
  /// come back as `nil` entries.
  static func firstMatchGroups(in text: String, pattern: String, groupCount: Int)
    -> (full: String, groups: [String?])?
  {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges > groupCount,
      let fullRange = Range(match.range, in: text)
    else { return nil }

    var groups: [String?] = []
    for index in 1...groupCount {
      guard let groupRange = Range(match.range(at: index), in: text) else {
        groups.append(nil)
        continue
      }
      groups.append(String(text[groupRange]))
    }
    return (String(text[fullRange]), groups)
  }
}
