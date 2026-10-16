import Foundation

/// One cook-mode step, in the recipe bundle v2 shape (`docs/spec/recipes/contracts/recipe-bundle-v2.schema.json`,
/// `$defs.step`), which the LeChef spec §8.4 adopts in place of its own minimum shape (RECONCILE resolved
/// in the recipe spec's favour, per LeChef §16.3).
///
/// A step without a real duration has no timer — no fake timers (LeChef §8.4). A step with a thermometer
/// check renders that check before any timer suggestion, and nothing in this module ever derives doneness
/// from colour or elapsed time: the only doneness answer is the thermometer's endpoint temperature.
public struct CookStep: Equatable, Hashable, Sendable, Codable {
  /// The step text as written, with quantities and times in place for highlighting.
  public let text: String
  /// Indexes into the recipe's ingredient lines that this step consumes.
  public let uses: [Int]
  /// Real duration in seconds, or nil where no duration exists (assembly, plating).
  public let timerSeconds: Int?
  /// A checkable thermometer test, when the recipe's safety data provides one.
  public let thermometer: CookThermometer?

  public init(text: String, uses: [Int] = [], timerSeconds: Int? = nil, thermometer: CookThermometer? = nil) {
    self.text = text
    self.uses = uses
    self.timerSeconds = timerSeconds
    self.thermometer = thermometer
  }

  enum CodingKeys: String, CodingKey {
    case text, uses, thermometer
    case timerSeconds = "timer_seconds"
  }

  /// The step's checkable safety test, or nil when it carries none.
  ///
  /// Deliberately derived only from the step's thermometer data. A step with a timer but no thermometer
  /// has no safety prompt — elapsed time is never a doneness verdict (PR #86 §3.1, LeChef §3.1).
  public var safetyPrompt: CookSafetyPrompt? {
    guard let thermometer else { return nil }
    return CookSafetyPrompt(
      instruction: "Check the \(thermometer.food): \(Self.temperatureText(thermometer.endpointC)) °C.",
      temperatureC: thermometer.endpointC,
      source: thermometer.source)
  }

  /// Renders a temperature without a trailing ".0" so it reads "74 °C", not "74.0 °C".
  public static func temperatureText(_ celsius: Double) -> String {
    let rounded = (celsius * 10).rounded() / 10
    if rounded == rounded.rounded() {
      return String(Int(rounded))
    }
    return String(format: "%.1f", rounded)
  }
}

/// A thermometer check carried verbatim from the recipe bundle's safety data
/// (`$defs.step.thermometer`). Nothing derives it; the recipe states it or the step has none.
public struct CookThermometer: Equatable, Hashable, Sendable, Codable {
  /// The endpoint temperature in Celsius — the only doneness answer this module knows.
  public let endpointC: Double
  /// What to measure, e.g. "chicken thigh, thickest piece".
  public let food: String
  /// The pinned safety-source citation, e.g. "usda-fsis: poultry 165 F".
  public let source: String

  /// The bundle v2 wire keys (`$defs.step.thermometer`, `additionalProperties: false`):
  /// the schema names `endpoint_c`, so the synthesized camelCase conformance would neither
  /// decode a schema-valid thermometer nor encode one it would accept.
  enum CodingKeys: String, CodingKey {
    case endpointC = "endpoint_c"
    case food, source
  }

  public init(endpointC: Double, food: String, source: String) {
    self.endpointC = endpointC
    self.food = food
    self.source = source
  }
}

/// A checkable thermometer test surfaced in cook mode.
///
/// The endpoint temperature and its source are carried verbatim from the recipe bundle
/// (source is pinned to the FSIS rule in the food-safety canon, e.g. "usda-fsis: poultry 165 F").
public struct CookSafetyPrompt: Equatable, Hashable, Sendable, Codable {
  /// The checkable instruction, e.g. "Check the chicken thigh, thickest piece: 74 °C."
  public let instruction: String
  public let temperatureC: Double
  /// The pinned source citation, e.g. "usda-fsis: poultry 165 F".
  public let source: String
}

/// A quantity in the recipe bundle v2 wire shape (`$defs.quantity`), kept as authored so the
/// step renders the same unit text the recipe wrote.
public enum CookQuantity: Equatable, Hashable, Sendable {
  /// A weighed mass in grams.
  case grams(Double)
  /// A household measure; `grams` is the FNDDS-pinned conversion when known, else nil
  /// (honest unknown mass — nutrition must not be synthesized).
  case household(amount: Double, unit: String, grams: Double?)
  /// A counted quantity such as "3 large" eggs.
  case count(amount: Double, unit: String, grams: Double?)
  /// No usable quantity; `note` is the recipe's own text, e.g. "to taste".
  case unknown(note: String?)

  /// The LeChef §5 evidence class of this quantity.
  ///
  /// Weighed grams are `weighed`; household measures and counted items are `household`
  /// (a count is a household measure whose unit is the item); anything else is `unknown`.
  public var evidence: CookQuantityEvidence {
    switch self {
    case .grams: return .weighed
    case .household, .count: return .household
    case .unknown: return .unknown
    }
  }

  /// True when there is no quantity to scale — the line holds at "check amount".
  public var isUnknown: Bool {
    if case .unknown = self { return true }
    return false
  }
}

extension CookQuantity: Codable {
  private enum Keys: String, CodingKey {
    case kind, grams, amount, unit, note
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "grams":
      self = .grams(try container.decode(Double.self, forKey: .grams))
    case "household":
      self = .household(
        amount: try container.decode(Double.self, forKey: .amount),
        unit: try container.decode(String.self, forKey: .unit),
        grams: try container.decodeIfPresent(Double.self, forKey: .grams))
    case "count":
      self = .count(
        amount: try container.decode(Double.self, forKey: .amount),
        unit: try container.decode(String.self, forKey: .unit),
        grams: try container.decodeIfPresent(Double.self, forKey: .grams))
    case "unknown":
      self = .unknown(note: try container.decodeIfPresent(String.self, forKey: .note))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container,
        debugDescription: "Unknown quantity kind: \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case let .grams(grams):
      try container.encode("grams", forKey: .kind)
      try container.encode(grams, forKey: .grams)
    case let .household(amount, unit, grams):
      try container.encode("household", forKey: .kind)
      try container.encode(amount, forKey: .amount)
      try container.encode(unit, forKey: .unit)
      // `grams` is schema-required (nullable): an unknown conversion is an explicit null,
      // never an absent key the schema's additionalProperties: false would still reject
      // by omission of a required property.
      try container.encode(grams, forKey: .grams)
    case let .count(amount, unit, grams):
      try container.encode("count", forKey: .kind)
      try container.encode(amount, forKey: .amount)
      try container.encode(unit, forKey: .unit)
      try container.encode(grams, forKey: .grams)
    case let .unknown(note):
      try container.encode("unknown", forKey: .kind)
      try container.encodeIfPresent(note, forKey: .note)
    }
  }
}

/// The LeChef §5 evidence classes for a quantity.
public enum CookQuantityEvidence: String, Equatable, Sendable, Codable {
  case weighed
  case sourceGrams = "source_grams"
  case household
  case unknown
}
