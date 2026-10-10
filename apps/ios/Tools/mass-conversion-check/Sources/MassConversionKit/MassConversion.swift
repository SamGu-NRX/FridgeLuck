import Foundation

/// Canonical household units modeled from USDA FNDDS portion descriptions.
///
/// Raw names such as "cups", "Tablespoon", "fluid ounces", or "pkg" resolve to
/// a canonical case via `init(flexibleName:)`.
public enum HouseholdUnit: String, CaseIterable, Sendable, Encodable, Decodable {
  case cup, tbsp, tsp, floz, oz, lb, quart, pint, gallon, liter
  case stick, slice, piece, strip, pat, clove, ear
  case small, medium, large, regular, egg
  case can, package, envelope

  /// Resolves a loose unit name to its canonical case, or nil when unknown.
  public init?(flexibleName: String) {
    let lowered = flexibleName.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let canonical: HouseholdUnit
    switch lowered {
    case "cup", "cups": canonical = .cup
    case "tbsp", "tbsps", "tbl", "tablespoon", "tablespoons":
      canonical = .tbsp
    case "tsp", "tsps", "teaspoon", "teaspoons": canonical = .tsp
    case "floz", "fl oz", "fluid ounce", "fluid ounces": canonical = .floz
    case "oz", "ozs", "ounce", "ounces": canonical = .oz
    case "lb", "lbs", "pound", "pounds": canonical = .lb
    case "quart", "quarts": canonical = .quart
    case "pint", "pints": canonical = .pint
    case "gallon", "gallons": canonical = .gallon
    case "liter", "liters", "litre", "litres": canonical = .liter
    case "stick", "sticks": canonical = .stick
    case "slice", "slices": canonical = .slice
    case "piece", "pieces": canonical = .piece
    case "strip", "strips": canonical = .strip
    case "pat", "pats": canonical = .pat
    case "clove", "cloves": canonical = .clove
    case "ear", "ears": canonical = .ear
    case "small": canonical = .small
    case "medium": canonical = .medium
    case "large": canonical = .large
    case "regular": canonical = .regular
    case "egg", "eggs": canonical = .egg
    case "can", "cans": canonical = .can
    case "package", "packages", "pack", "packs", "pkg": canonical = .package
    case "envelope", "envelopes", "env": canonical = .envelope
    default: return nil
    }
    self = canonical
  }
}

/// One USDA FNDDS portion record: `grams` is the mass of `magnitude` units of
/// `unit` for the food named `food` (FDC survey food `fdcId`).
///
/// `state` and `packing` carry the FNDDS preparation state ("cooked",
/// "frozen", "raw", "dried", "thawed") and packing ("canned", "jarred",
/// "packaged") classified from the portion qualifier and modifier; nil when
/// the source records none. Matching treats a nil state as compatible with
/// any query.
public struct MassConversionEntry: Decodable, Sendable, Equatable {
  public let fdcId: Int
  public let food: String
  public let unit: HouseholdUnit
  public let magnitude: Double
  public let grams: Double
  public let state: String?
  public let packing: String?

  /// Grams for a single unit of the entry's household measure.
  public var gramsPerUnit: Double { grams / magnitude }

  private enum CodingKeys: String, CodingKey {
    case fdcId, food, unit, magnitude, grams, state, packing
  }

  public init(
    fdcId: Int, food: String, unit: HouseholdUnit, magnitude: Double,
    grams: Double, state: String? = nil, packing: String? = nil
  ) {
    self.fdcId = fdcId
    self.food = food
    self.unit = unit
    self.magnitude = magnitude
    self.grams = grams
    self.state = state
    self.packing = packing
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fdcId = try container.decode(Int.self, forKey: .fdcId)
    food = try container.decode(String.self, forKey: .food)
    unit = try container.decode(HouseholdUnit.self, forKey: .unit)
    magnitude = try container.decode(Double.self, forKey: .magnitude)
    grams = try container.decode(Double.self, forKey: .grams)
    state = try container.decodeIfPresent(String.self, forKey: .state)
    packing = try container.decodeIfPresent(String.self, forKey: .packing)
  }
}

/// Provenance recorded inside the conversion table resource.
public struct MassConversionSource: Decodable, Sendable, Equatable {
  public let dataset: String
  public let edition: String
  public let url: String
  public let archiveSha256: String
  public let surveyJsonSha256: String
}

/// How strongly a conversion result is backed by the pinned evidence.
public enum ConversionEvidence: String, Sendable, Equatable, Codable {
  /// The query token set exactly covers a pinned (food, unit) entry's food
  /// tokens — the strongest evidence the table can offer.
  case exact
  /// Token-overlap match: related FNDDS survey food, same household unit.
  case partial
  /// No entry matched; no grams are reported.
  case unknown
}

/// The outcome of converting a food + household unit to grams.
public struct Conversion: Sendable, Equatable {
  public let grams: Double
  public let fdcId: Int
  public let unit: HouseholdUnit
  public let evidence: ConversionEvidence
  public let state: String?
  public let packing: String?
}

/// A parsed quantity that may be a range ("1-2 cups") or a single amount
/// ("1/2 cup", "1-1/2 cups", "2 tbsp"). Range magnitudes convert both ends
/// independently against the same per-unit gram weight.
public struct HouseholdQuantity: Sendable, Equatable {
  public let unit: HouseholdUnit
  public let low: Double
  /// Equal to `low` unless the text names a range.
  public let high: Double

  public var isRange: Bool { high != low }
  public var midpoint: Double { (low + high) / 2 }

  public init?(text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    let magnitudeToken = parts[0].lowercased()
    let unitToken = parts[1...].joined(separator: " ")
    guard let unit = HouseholdUnit(flexibleName: unitToken) else { return nil }

    func scalar(_ token: String) -> Double? {
      let piece = token.split(separator: "/")
      switch piece.count {
      case 1: return Double(piece[0])
      case 2:
        guard let n = Double(piece[0]), let d = Double(piece[1]), d != 0 else {
          return nil
        }
        return n / d
      default: return nil
      }
    }

    // Hyphenated magnitude forms, per FNDDS convention: "1-1/2" is a mixed
    // fraction (trailing fractional part), while "1-2" or "1/2-1" are ranges.
    let hyphenSplit = magnitudeToken.split(separator: "-", maxSplits: 1)
      .map(String.init)
    var low: Double?
    var high: Double?
    if hyphenSplit.count == 2 {
      if hyphenSplit[1].contains("/") {
        // Mixed fraction: whole + fractional part.
        if let whole = Double(hyphenSplit[0]),
          let frac = scalar(hyphenSplit[1])
        {
          low = whole + frac
          high = low
        }
      } else if let a = scalar(hyphenSplit[0]), let b = scalar(hyphenSplit[1]) {
        low = a
        high = b
      }
    } else if let single = scalar(hyphenSplit[0]) {
      low = single
      high = single
    }
    guard let l = low, let h = high, l > 0, h >= l else { return nil }
    self.unit = unit
    self.low = l
    self.high = h
  }
}

/// Lookup table converting household measures to grams from pinned USDA
/// FNDDS Survey Foods portion data.
///
/// Pure Foundation — no UIKit, no GRDB — so it can be exercised on Linux.
public struct MassConversionTable: Sendable {
  public let source: MassConversionSource
  public let portions: [MassConversionEntry]

  /// Loads the table from JSON data matching the pinned resource schema.
  public init(json: Data) throws {
    let payload = try JSONDecoder().decode(Payload.self, from: json)
    self.source = payload.source
    self.portions = payload.portions
  }

  /// In-memory initializer for tests and held-out evaluation, which rebuild
  /// the table with entries withheld.
  public init(source: MassConversionSource, portions: [MassConversionEntry]) {
    self.source = source
    self.portions = portions
  }

  /// Loads the table bundled with the MassConversionKit target.
  public static var bundled: MassConversionTable {
    get throws {
      guard let url = Bundle.module.url(
        forResource: "mass_conversion_table", withExtension: "json"
      ) else {
        throw MassConversionError.missingBundledResource
      }
      return try MassConversionTable(json: try Data(contentsOf: url))
    }
  }

  private struct Payload: Decodable {
    let source: MassConversionSource
    let portions: [MassConversionEntry]
  }

  public enum MassConversionError: Error, Equatable {
    case missingBundledResource
  }

  /// Preparation-state words the query text asserts, canonicalized with the
  /// same priority as the extractor (frozen outranks cooked, and so on).
  static func queryState(in tokens: Set<String>) -> String? {
    let priorities: [(String, Set<String>)] = [
      ("frozen", ["frozen"]),
      ("thawed", ["thawed"]),
      ("dried", ["dry", "dried"]),
      (
        "cooked",
        [
          "cooked", "baked", "boiled", "braised", "fried", "grilled", "heated",
          "prepared", "roasted", "steamed", "stewed",
        ],
      ),
      ("raw", ["raw"]),
    ]
    for (state, words) in priorities where !tokens.isDisjoint(with: words) {
      return state
    }
    if tokens.contains("reconstituted") {
      return tokens.contains("not") ? "dried" : "cooked"
    }
    return nil
  }

  static func queryPacking(in tokens: Set<String>) -> String? {
    let families: [(String, Set<String>)] = [
      ("canned", ["canned"]),
      ("jarred", ["jar", "jars"]),
      ("packaged", ["packaged"]),
    ]
    for (packing, words) in families where !tokens.isDisjoint(with: words) {
      return packing
    }
    return nil
  }

  /// Finds the best entry for a food description and unit.
  ///
  /// Matching is token-based: the query is lowercased and split into word
  /// tokens; the entry maximizing token overlap wins, with ties broken by
  /// shorter food descriptions (more specific entries) and then by FDC id so
  /// results are deterministic. Returns nil when the query shares no token
  /// with any food of that unit.
  ///
  /// When the query asserts a preparation state or packing (e.g. "canned"),
  /// entries recorded with the same state/packing are preferred and entries
  /// recorded with a conflicting one are penalized, so a "canned" query does
  /// not silently take a fresh entry's grams. Stateless entries stay
  /// compatible with any query.
  public func entry(food: String, unit: HouseholdUnit) -> MassConversionEntry? {
    let query = Self.tokens(food)
    guard !query.isEmpty else { return nil }
    let queryState = Self.queryState(in: query)
    let queryPacking = Self.queryPacking(in: query)

    var best: MassConversionEntry?
    var bestScore = 0.0
    for portion in portions where portion.unit == unit {
      let entryTokens = Self.tokens(portion.food)
      guard !entryTokens.isEmpty else { continue }
      let matches = query.intersection(entryTokens).count
      guard matches > 0 else { continue }
      // Fraction of the entry's tokens the query covers, rewarding queries
      // that fully describe a food; then prefer shorter (more specific)
      // descriptions, then the lowest FDC id for determinism.
      let coverage = Double(matches) / Double(entryTokens.count)
      var score = coverage * 1000 - Double(entryTokens.count)
      if let queryState {
        if let entryState = portion.state {
          score += entryState == queryState ? 50 : -50
        }
      }
      if let queryPacking {
        if let entryPacking = portion.packing {
          score += entryPacking == queryPacking ? 50 : -50
        }
      }
      if best == nil || score > bestScore
        || (score == bestScore && portion.fdcId < best!.fdcId)
      {
        best = portion
        bestScore = score
      }
    }
    return best
  }

  /// Grams for `magnitude` units of `unit` of the matched food, or nil.
  public func grams(
    food: String, unit: HouseholdUnit, magnitude: Double = 1
  ) -> Double? {
    guard let matched = entry(food: food, unit: unit) else { return nil }
    return magnitude * matched.gramsPerUnit
  }

  /// Grams for a quantity of the matched food, with evidence provenance.
  ///
  /// Returns nil when no entry matches (`evidence: .unknown` is never
  /// fabricated into a number): unknown means unknown.
  public func convert(
    food: String, unit: HouseholdUnit, magnitude: Double = 1
  ) -> Conversion? {
    guard let matched = entry(food: food, unit: unit) else { return nil }
    let query = Self.tokens(food)
    let entryTokens = Self.tokens(matched.food)
    let evidence: ConversionEvidence =
      query == entryTokens ? .exact : .partial
    return Conversion(
      grams: magnitude * matched.gramsPerUnit,
      fdcId: matched.fdcId,
      unit: unit,
      evidence: evidence,
      state: matched.state,
      packing: matched.packing
    )
  }

  /// Low/high gram weights for a (possibly ranged) household quantity, or
  /// nil when the food does not match. Range quantities convert each end
  /// against the same per-unit gram weight.
  public func gramsRange(
    food: String, quantity: HouseholdQuantity
  ) -> (low: Double, high: Double)? {
    guard let matched = entry(food: food, unit: quantity.unit) else {
      return nil
    }
    return (
      quantity.low * matched.gramsPerUnit,
      quantity.high * matched.gramsPerUnit
    )
  }

  static func tokens(_ text: String) -> Set<String> {
    Set(
      text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { String($0) }
    )
  }
}
