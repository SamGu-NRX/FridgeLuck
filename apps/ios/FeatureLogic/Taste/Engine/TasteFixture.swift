import Foundation

/// Decodes a golden fixture document (`tasteFixture/v1`) for the parity tests.
/// The fixtures live in `evaluation/taste-lab/fixtures/` and are the machine
/// acceptance harness shared with the Python lab (SPEC 6).
public struct TasteFixture: Sendable {
  public let name: String
  public let evalAt: String
  public let events: [TasteEvent]
  public let exposures: [TasteExposure]
  public let statements: [TasteStatement]
  public let ruleScores: [String: Double]
  public let expectedRanking: [ExpectedRankEntry]
  public let expectedProfile: [ExpectedStatement]
  public let expectedHidden: [TasteHiddenStatement]

  public struct ExpectedRankEntry: Sendable {
    public let recipeId: String
    public let ruleScore: Double
    public let learnedFeatures: [TasteFeatureContribution]
    public let learnedContribution: Double
    public let totalScore: Double
  }

  public struct ExpectedStatement: Sendable {
    public let id: String
    public let featureKey: String?
    public let templateId: String?
  }

  // MARK: Decoding

  public static func decode(from data: Data) throws -> TasteFixture {
    let decoder = JSONDecoder()
    let root = try decoder.decode([String: TasteJSONValue].self, from: data)
    guard case .string(let name) = root["name"] ?? .null else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "missing name"))
    }
    guard case .string(let evalAt) = root["evalAt"] ?? .null else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "missing evalAt"))
    }

    func decode<T: Decodable>(_ value: TasteJSONValue, as type: T.Type) throws -> T {
      let encoded = try JSONEncoder().encode(value)
      return try decoder.decode(T.self, from: encoded)
    }

    let events = try decode(root["events"] ?? .array([]), as: [TasteEvent].self)
    let exposures = try decode(root["exposures"] ?? .array([]), as: [TasteExposure].self)
    let statements = try decode(root["statements"] ?? .array([]), as: [TasteStatement].self)

    var ruleScores: [String: Double] = [:]
    if case .object(let scores) = root["ruleScores"] ?? .object([:]) {
      for (key, value) in scores {
        ruleScores[key] = value.doubleValue ?? 0.0
      }
    }

    var ranking: [ExpectedRankEntry] = []
    var profile: [ExpectedStatement] = []
    var hidden: [TasteHiddenStatement] = []
    if case .object(let expected) = root["expected"] ?? .object([:]) {
      if case .array(let entries) = expected["ranking"] ?? .array([]) {
        for entry in entries {
          guard case .object(let fields) = entry else { continue }
          let recipeId: String
          if case .object(let recipe)? = fields["recipe"],
            case .string(let id) = recipe["id"] ?? .null
          { recipeId = id } else { continue }
          ranking.append(
            ExpectedRankEntry(
              recipeId: recipeId,
              ruleScore: fields["ruleScore"]?.doubleValue ?? 0.0,
              learnedFeatures: try decode(
                fields["learnedFeatures"] ?? .array([]), as: [TasteFeatureContribution].self),
              learnedContribution: fields["learnedContribution"]?.doubleValue ?? 0.0,
              totalScore: fields["totalScore"]?.doubleValue ?? 0.0))
        }
      }
      if case .array(let statements) = expected["profile"] ?? .array([]) {
        for statement in statements {
          guard case .object(let fields) = statement else { continue }
          profile.append(
            ExpectedStatement(
              id: fields["id"]?.stringValue ?? "",
              featureKey: fields["featureKey"]?.stringValue,
              templateId: fields["templateId"]?.stringValue))
        }
      }
      if case .array(let hiddenRaw) = expected["hidden"] ?? .array([]) {
        for item in hiddenRaw {
          guard case .object(let fields) = item,
            let featureKey = fields["featureKey"]?.stringValue,
            let reason = fields["reason"]?.stringValue
          else { continue }
          hidden.append(TasteHiddenStatement(featureKey: featureKey, reason: reason))
        }
      }
    }

    return TasteFixture(
      name: name, evalAt: evalAt, events: events, exposures: exposures, statements: statements,
      ruleScores: ruleScores, expectedRanking: ranking, expectedProfile: profile,
      expectedHidden: hidden)
  }

  /// Loads every `*.json` fixture from the lab's fixtures directory
  /// (`evaluation/taste-lab/fixtures/`, resolved from the test's own path so
  /// the harness works in checkouts on macOS CI and local machines).
  public static func loadAll(fromDirectory fixtureDir: URL) throws -> [TasteFixture] {
    let files = try FileManager.default.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map { try decode(from: Data(contentsOf: $0)) }
  }
}
