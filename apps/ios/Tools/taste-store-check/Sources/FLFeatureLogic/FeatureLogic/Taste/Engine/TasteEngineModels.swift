import Foundation

// MARK: - Recipe reference (taste contracts RecipeRef subset)

/// The recipe reference carried by taste events and exposures. `id` is the
/// contract's string id (the app maps `recipes.id` to `String(id)`).
public struct TasteRecipeRef: Codable, Hashable, Sendable {
  public let id: String
  public let revision: Int?
  public let source: String?

  public init(id: String, revision: Int? = nil, source: String? = nil) {
    self.id = id
    self.revision = revision
    self.source = source
  }
}

// MARK: - Dynamic JSON payload

/// A lossless JSON value for event payloads and heterogeneous fixture arrays.
/// Payloads vary per event kind, so the engine reads them by key instead of
/// one struct per kind.
public enum TasteJSONValue: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([TasteJSONValue])
  case object([String: TasteJSONValue])
}

extension TasteJSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([TasteJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: TasteJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public var stringValue: String? {
    switch self {
    case .string(let value): return value
    case .number(let value):
      // Fixture ingredient ids arrive as JSON numbers ("ingredient": 101) or
      // strings; the contracts treat both as the id's string form.
      return TasteJSONValue.integerString(for: value)
    default: return nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .number(let value): return value
    case .string(let value): return Double(value)
    default: return nil
    }
  }

  public var intValue: Int? {
    doubleValue.map { Int($0) }
  }

  private static func integerString(for value: Double) -> String {
    if value == value.rounded(), value <= 9_007_199_254_740_991, value >= -9_007_199_254_740_991 {
      return String(Int(value))
    }
    return String(value)
  }
}

// MARK: - Events

public struct TasteEvent: Codable, Hashable, Sendable {
  public let id: String
  public let at: String
  public let kind: String
  public let eater: String?
  public let recipe: TasteRecipeRef?
  /// Ingredient id for substitution events; JSON number or string in fixtures.
  public let ingredient: TasteJSONValue?
  public let surface: String?
  public let payload: [String: TasteJSONValue]

  public init(
    id: String, at: String, kind: String, eater: String? = nil,
    recipe: TasteRecipeRef? = nil, ingredient: TasteJSONValue? = nil,
    surface: String? = nil, payload: [String: TasteJSONValue] = [:]
  ) {
    self.id = id
    self.at = at
    self.kind = kind
    self.eater = eater
    self.recipe = recipe
    self.ingredient = ingredient
    self.surface = surface
    self.payload = payload
  }
}

// MARK: - Exposures

/// One logged recommendation surface: the shown slate (ordered) and the full
/// feasible set the ranker chose from (SPEC 2.4). Fixtures encode `feasible`
/// either as recipe ids or as recipe refs; the engine only needs its length.
public struct TasteExposure: Codable, Hashable, Sendable {
  public let id: String
  public let at: String?
  public let surface: String?
  public let slate: [TasteSlateItem]
  public let feasible: [TasteJSONValue]

  public init(
    id: String, at: String? = nil, surface: String? = nil,
    slate: [TasteSlateItem], feasible: [TasteJSONValue] = []
  ) {
    self.id = id
    self.at = at
    self.surface = surface
    self.slate = slate
    self.feasible = feasible
  }

  public var feasibleCount: Int { feasible.count }
}

public struct TasteSlateItem: Codable, Hashable, Sendable {
  public let position: Int?
  public let recipe: TasteRecipeRef

  public init(position: Int? = nil, recipe: TasteRecipeRef) {
    self.position = position
    self.recipe = recipe
  }
}

// MARK: - Profile statements

public struct TasteStatement: Codable, Hashable, Sendable {
  public let id: String
  public let layer: String
  public let featureKind: String?
  public let featureKey: String?
  public let templateId: String?
  public let numerator: Int?
  public let denominator: Int?
  public let state: String
  public let mutedUntil: String?
  public let pinnedValue: Double?
  public let lastEvidenceAt: String?
  public let createdAt: String?
  public let updatedAt: String?
  public let text: String?
}

public struct TasteHiddenStatement: Codable, Hashable, Sendable {
  public let featureKey: String
  public let reason: String
}

// MARK: - Ranking output

public struct TasteFeatureContribution: Codable, Hashable, Sendable {
  public let featureKey: String
  public let contribution: Double
}

public struct TasteRankEntry: Codable, Hashable, Sendable {
  public let recipeID: String
  public let ruleScore: Double
  public let learnedFeatures: [TasteFeatureContribution]
  public let learnedContribution: Double
  public let totalScore: Double

  enum CodingKeys: String, CodingKey {
    case recipeID = "recipeId"
    case ruleScore
    case learnedFeatures
    case learnedContribution
    case totalScore
  }
}

public struct TasteDecayedPosterior: Codable, Hashable, Sendable {
  public let featureClass: String
  public let featureKey: String
  public let alpha: Double
  public let beta: Double
  public let lastEvidenceAt: String?
}
