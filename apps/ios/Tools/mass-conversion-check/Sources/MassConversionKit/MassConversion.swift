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
public struct MassConversionEntry: Decodable, Sendable, Equatable {
  public let fdcId: Int
  public let food: String
  public let unit: HouseholdUnit
  public let magnitude: Double
  public let grams: Double

  /// Grams for a single unit of the entry's household measure.
  public var gramsPerUnit: Double { grams / magnitude }
}

/// Provenance recorded inside the conversion table resource.
public struct MassConversionSource: Decodable, Sendable, Equatable {
  public let dataset: String
  public let edition: String
  public let url: String
  public let archiveSha256: String
  public let surveyJsonSha256: String
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

  /// Finds the best entry for a food description and unit.
  ///
  /// Matching is token-based: the query is lowercased and split into word
  /// tokens; the entry maximizing token overlap wins, with ties broken by
  /// shorter food descriptions (more specific entries) and then by FDC id so
  /// results are deterministic. Returns nil when the query shares no token
  /// with any food of that unit.
  public func entry(food: String, unit: HouseholdUnit) -> MassConversionEntry?
  {
    let query = Self.tokens(food)
    guard !query.isEmpty else { return nil }

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
      let score = coverage * 1000 - Double(entryTokens.count)
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

  static func tokens(_ text: String) -> Set<String> {
    Set(
      text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { String($0) }
    )
  }
}
