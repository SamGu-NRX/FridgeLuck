import Foundation

/// How a grocery amount in a draft was established. Kept separate from the persistence-layer
/// provenance (mapped one-to-one in the app glue) so this module stays Foundation-only.
public enum GroceryAmountProvenance: String, Sendable, Equatable {
  /// Heuristic guess: typical unit mass or a per-name table, never read off the source.
  case estimate
  /// A value the user set by hand.
  case entered
  /// An explicit weight read from the source (package net weight, receipt line, or a value
  /// the user read off the packaging and set with its unit).
  case measured
}

/// An amount extracted from source text. `grams == nil` means the text carried no usable
/// weight — the review flow must resolve it; it never defaults to a guess here.
public struct ParsedGroceryAmount: Sendable, Equatable {
  public let grams: Double?
  /// Count evidence such as "2 @" or "x2"; kept even when grams are known.
  public let count: Int?
  /// The substring the amount was read from, for review evidence.
  public let rawText: String
  public let provenance: GroceryAmountProvenance

  public init(grams: Double?, count: Int?, rawText: String, provenance: GroceryAmountProvenance) {
    self.grams = grams
    self.count = count
    self.rawText = rawText
    self.provenance = provenance
  }
}

/// Parses amounts from receipt lines and packaging text.
///
/// Ground rules:
/// - Prices are never amounts. "$4.50" or "4,50 €" says nothing about grams, so a price-only
///   line yields `nil` — the review asks the user instead of inventing a conversion.
/// - Explicit weights (g/kg/oz/lb) become `.measured` grams.
/// - Counts ("2 @", "x2", leading "2 ") become count evidence; grams stay a `.estimate`
///   resolved through the caller's per-food unit-mass estimator, or `nil` when it has no
///   entry — an unknown food count is not silently turned into grams.
public enum GroceryReceiptParser {
  /// Upper sanity bound for a parsed weight; anything above is a misread, not groceries.
  static let maxPlausibleGrams: Double = 30_000
  static let gramsPerOunce = 28.3495
  static let gramsPerPound = 453.592

  // MARK: - Receipt lines

  /// Classifies one OCR line as a grocery line item or a structural line (totals, tax,
  /// payment, store header, nutrition). Structural lines are dropped before review.
  public static func classify(line rawLine: String) -> GroceryLineClassification {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return GroceryLineClassification(isItem: false, reason: "empty") }
    let lowered = line.lowercased()

    if let reason = excludedReason(for: lowered) {
      return GroceryLineClassification(isItem: false, reason: reason)
    }
    // Bare counts ("12 ITEMS") and phone numbers ("020 7946 0958") are not food.
    if matchesCountSummary(lowered) || looksLikePhoneNumber(line) {
      return GroceryLineClassification(isItem: false, reason: "non-item")
    }
    // An item line has some letters; a bare amount ("$4.50") is not an item.
    guard line.contains(where: { $0.isLetter }) else {
      return GroceryLineClassification(isItem: false, reason: "amount-only")
    }
    return GroceryLineClassification(isItem: true, reason: nil)
  }

  public static func parse(_ lines: [String]) -> [GroceryParsedLine] {
    lines.map { line in
      let classification = classify(line: line)
      let amount = classification.isItem ? parseAmount(line: line) : nil
      return GroceryParsedLine(rawText: line, classification: classification, amount: amount)
    }
  }

  // MARK: - Amounts

  /// Interprets one item line's amount. Returns `nil` when the line carries no amount signal
  /// a review can use (a bare price is the common case).
  public static func parseAmount(line rawLine: String) -> ParsedGroceryAmount? {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

    if let weight = parseExplicitWeight(in: line) {
      let count = parseCount(in: line)
      return ParsedGroceryAmount(
        grams: weight.grams, count: count, rawText: weight.rawText, provenance: .measured)
    }

    if let count = parseCount(in: line) {
      return ParsedGroceryAmount(grams: nil, count: count, rawText: line, provenance: .estimate)
    }

    // Price-only lines: no amount. The raw text is preserved upstream as evidence.
    return nil
  }

  /// Explicit weight anywhere in the line: "454 G", "0.5 kg", "12 OZ", "1.25 LB", "0,5 kg".
  /// Comma decimals are accepted only when a unit follows, so "1,50" stays a price.
  public static func parseExplicitWeight(in line: String) -> (grams: Double, rawText: String)? {
    let pattern = #"(\d+(?:[.,]\d{1,3})?)\s*(g|gr|gram|grams|kg|kgs|kilogram|kilograms|oz|ounce|ounces|lb|lbs|pound|pounds)(?![a-z])"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return nil }

    let range = NSRange(line.startIndex..., in: line)
    guard let match = regex.firstMatch(in: line, options: [], range: range),
      match.numberOfRanges >= 3,
      let valueRange = Range(match.range(at: 1), in: line),
      let unitRange = Range(match.range(at: 2), in: line)
    else { return nil }

    let rawValue = line[valueRange].replacingOccurrences(of: ",", with: ".")
    guard let value = Double(rawValue) else { return nil }
    let unit = line[unitRange].lowercased()

    let grams: Double
    if unit == "g" || unit == "gr" || unit.hasPrefix("gram") {
      grams = value
    } else if unit.hasPrefix("kg") || unit.hasPrefix("kilogram") {
      grams = value * 1_000
    } else if unit.hasPrefix("oz") || unit == "ounce" || unit.hasPrefix("ounce") {
      grams = value * gramsPerOunce
    } else {
      grams = value * gramsPerPound
    }

    guard grams > 0, grams <= maxPlausibleGrams else { return nil }
    let rounded = (grams * 10).rounded() / 10
    let rawText = String(line[Range(match.range, in: line)!])
    return (rounded, rawText)
  }

  /// Count evidence: "2 @ 3.99", "x2", "2 FOR 5.00", or a leading integer ("2 MILK 3.29").
  /// Leading counts ignore decimals and prices ("3.29 MILK" is not 3 items).
  public static func parseCount(in line: String) -> Int? {
    let lowered = line.lowercased()

    let atPattern = #"(?:^|\s)(\d{1,2})\s*@"#
    if let count = firstCapturedNumber(in: lowered, pattern: atPattern) { return count }

    let timesPattern = #"(?:^|\s)x\s*(\d{1,2})(?![\d.])"#
    if let count = firstCapturedNumber(in: lowered, pattern: timesPattern) { return count }

    let forPattern = #"(?:^|\s)(\d{1,2})\s+for\s"#
    if let count = firstCapturedNumber(in: lowered, pattern: forPattern) { return count }

    let leadingPattern = #"^(\d{1,2})\s+(?=\D)"#
    return firstCapturedNumber(in: lowered, pattern: leadingPattern)
  }

  /// Packaging net weight for whole-product photos: "NET WT 454 G", "NET WT. 16 OZ (454 G)",
  /// "1.89 L". Serving sizes are explicitly excluded — a portion is not the package amount.
  public static func packagingAmount(in ocrStrings: [String]) -> ParsedGroceryAmount? {
    let lowered = ocrStrings.map { $0.lowercased() }

    let netWeightLine = ocrStrings.enumerated().first { index, _ in
      let text = lowered[index]
      return text.contains("net wt") || text.contains("net weight") || text.contains("netto")
    }
    if let netWeightLine {
      if let weight = parseExplicitWeight(in: netWeightLine.element) {
        return ParsedGroceryAmount(
          grams: weight.grams, count: nil, rawText: weight.rawText, provenance: .measured)
      }
    }
    return nil
  }

  // MARK: - Classification tables

  /// Prefix-matched structural lines (lowercased keys). The prefix must end at a word
  /// boundary — "cash" must not swallow "cashews", "card" must not swallow "cardamom".
  static let excludedKeywordReasons: [(key: String, value: String)] = [
    ("subtotal", "totals"), ("sub total", "totals"), ("total", "totals"), ("balance due", "totals"),
    ("amount due", "totals"), ("tax", "tax"), ("vat", "tax"), ("gst", "tax"), ("hst", "tax"),
    ("cash", "payment"), ("change", "payment"), ("tender", "payment"), ("card", "payment"),
    ("visa", "payment"), ("mastercard", "payment"), ("amex", "payment"), ("debit", "payment"),
    ("credit", "payment"), ("payment", "payment"), ("contactless", "payment"),
    ("member savings", "discount"), ("you saved", "discount"), ("savings", "discount"),
    ("loyalty", "discount"), ("rewards", "discount"), ("points", "discount"),
    ("coupon", "discount"), ("discount", "discount"),
    ("void", "discount"), ("refund", "discount"),
    ("thank", "courtesy"), ("welcome", "courtesy"), ("receipt", "courtesy"),
    ("invoice", "courtesy"), ("order", "courtesy"), ("serving", "nutrition"),
  ]

  static let excludedPhrases: [(key: String, value: String)] = [
    ("store #", "header"), ("item count", "non-item"), ("approved code", "non-item"),
  ]

  private static func excludedReason(for lowered: String) -> String? {
    if let phrase = excludedPhrases.first(where: { lowered.contains($0.key) })?.value {
      return phrase
    }
    for keyword in excludedKeywordReasons {
      guard lowered.hasPrefix(keyword.key) else { continue }
      let rest = lowered.dropFirst(keyword.key.count)
      if rest.isEmpty || !(rest.first?.isLetter ?? false) {
        return keyword.value
      }
    }
    return nil
  }

  private static func matchesCountSummary(_ lowered: String) -> Bool {
    // "12 ITEMS", "3 ITEM(S)" — a bare tally line.
    let pattern = #"^\d{1,3}\s*items?\(?s?\)?[.:]?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(lowered.startIndex..., in: lowered)
    return regex.firstMatch(in: lowered, options: [], range: range) != nil
  }

  private static func looksLikePhoneNumber(_ line: String) -> Bool {
    let digits = line.filter { $0.isNumber }.count
    let letters = line.filter { $0.isLetter }
    return digits >= 7 && letters.isEmpty
  }

  private static func firstCapturedNumber(in text: String, pattern: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      match.numberOfRanges >= 2,
      let captureRange = Range(match.range(at: 1), in: text),
      let value = Int(text[captureRange])
    else { return nil }
    return (1...99).contains(value) ? value : nil
  }
}

/// One classified OCR line with its optional amount.
public struct GroceryParsedLine: Sendable, Equatable {
  public let rawText: String
  public let classification: GroceryLineClassification
  public let amount: ParsedGroceryAmount?

  public init(rawText: String, classification: GroceryLineClassification, amount: ParsedGroceryAmount?) {
    self.rawText = rawText
    self.classification = classification
    self.amount = amount
  }
}

/// Whether a line is a grocery item, and if not, why it was excluded (for review evidence
/// and evaluation fixtures).
public struct GroceryLineClassification: Sendable, Equatable {
  public let isItem: Bool
  public let reason: String?

  public init(isItem: Bool, reason: String?) {
    self.isItem = isItem
    self.reason = reason
  }
}
