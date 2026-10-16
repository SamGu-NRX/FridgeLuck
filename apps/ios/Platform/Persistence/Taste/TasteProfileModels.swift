import Foundation

import FLFeatureLogic

// MARK: - Exposure record

/// Decision context of a render
/// (docs/spec/taste/contracts/exposure.schema.json `context`).
struct TasteExposureContext: Codable, Equatable, Sendable {
  var kitchenIngredientCount: Int
  var householdSize: Int
  var mealContext: String?
}

/// The store's exposure record: the public contract exposure (`FLFeatureLogic.TasteExposure`
/// — what was shown, in what order, and the feasible set) plus the store-only columns the
/// contract type omits (row instant, eater, session, decision context). This record is
/// what separates availability from preference (docs/spec/taste/SPEC.md §2.4). `id` is a
/// stable UUID v4 string.
struct TasteExposureRecord: Equatable, Sendable {
  /// The contract exposure (FLFeatureLogic): id, ISO-8601 `at`?, `surface`?, slate,
  /// feasible set.
  var exposure: TasteExposure
  var at: Date
  var eater: String?
  var sessionId: String?
  var context: TasteExposureContext?

  var id: String { exposure.id }

  /// Builds a record from the store's typed vocabulary — how the ranker logs a render.
  init(
    id: String = UUID().uuidString.lowercased(),
    at: Date = Date(),
    surface: String,
    eater: String? = nil,
    sessionId: String? = nil,
    slate: [TasteSlateItem],
    feasible: [TasteRecipeRef] = [],
    context: TasteExposureContext? = nil
  ) {
    self.at = at
    self.eater = eater
    self.sessionId = sessionId
    self.context = context
    self.exposure = TasteExposure(
      id: id,
      at: TasteTimestamp.string(from: at),
      surface: surface,
      slate: slate,
      feasible: feasible.map(Self.feasibleValue))
  }

  /// Builds a record from a decoded row — how the store hands loaded rows back out.
  init(
    exposure: TasteExposure, at: Date, eater: String?, sessionId: String?,
    context: TasteExposureContext?
  ) {
    self.exposure = exposure
    self.at = at
    self.eater = eater
    self.sessionId = sessionId
    self.context = context
  }

  /// A recipe ref inside the feasible set, as the contract event's dynamic JSON value
  /// (refs encode as objects with `id`, `revision`, `source` — matching the slate's
  /// recipe refs).
  private static func feasibleValue(for ref: TasteRecipeRef) -> TasteJSONValue {
    var object: [String: TasteJSONValue] = ["id": .string(ref.id)]
    if let revision = ref.revision {
      object["revision"] = .number(Double(revision))
    }
    if let source = ref.source {
      object["source"] = .string(source)
    }
    return .object(object)
  }
}

extension TasteExposureRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, at, surface, eater, sessionId, slate, feasible, context
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let at = try container.decode(String.self, forKey: .at)
    guard let atDate = TasteTimestamp.date(from: at) else {
      throw DecodingError.dataCorruptedError(
        forKey: .at, in: container, debugDescription: "unparsable exposure timestamp: \(at)")
    }
    self.exposure = TasteExposure(
      id: id,
      at: at,
      surface: try container.decodeIfPresent(String.self, forKey: .surface),
      slate: try container.decode([TasteSlateItem].self, forKey: .slate),
      feasible: try container.decodeIfPresent([TasteJSONValue].self, forKey: .feasible) ?? [])
    self.at = atDate
    self.eater = try container.decodeIfPresent(String.self, forKey: .eater)
    self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    self.context = try container.decodeIfPresent(TasteExposureContext.self, forKey: .context)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(exposure.id, forKey: .id)
    try container.encode(TasteTimestamp.string(from: at), forKey: .at)
    try container.encodeIfPresent(exposure.surface, forKey: .surface)
    try container.encodeIfPresent(eater, forKey: .eater)
    try container.encodeIfPresent(sessionId, forKey: .sessionId)
    try container.encode(exposure.slate, forKey: .slate)
    try container.encode(exposure.feasible, forKey: .feasible)
    try container.encodeIfPresent(context, forKey: .context)
  }
}

// MARK: - Profile statements

/// Which layer a profile sentence belongs to
/// (docs/spec/taste/contracts/profile-statement.schema.json).
enum TasteStatementLayer: String, Codable, Sendable, CaseIterable {
  /// Setup allergies/diets: hard filter, edited in setup only, never machine-written.
  case restriction
  /// What the user told the app at setup or later.
  case stated
  /// User-set override with a fixed rank value in [-8, +8].
  case pinned
  /// Learned from behaviour; carries numerator/denominator evidence counts.
  case inferred
}

/// Lifecycle state of a profile statement.
enum TasteStatementState: String, Codable, Sendable, CaseIterable {
  case active
  /// The user tapped "Right".
  case confirmed
  /// "This is wrong": kept, never re-learned, shown struck-through.
  case rejected
  /// "Don't ask again" until `mutedUntil`.
  case muted
  /// Evidence went stale; revives automatically on fresh evidence.
  case expired
}

/// One sentence on the taste profile with the evidence it stands on
/// (docs/spec/taste/contracts/profile-statement.schema.json).
struct TasteProfileStatement: Codable, Equatable, Sendable {
  var id: String
  var layer: TasteStatementLayer
  var featureKind: TasteFeatureKind?
  var featureKey: String?
  var templateId: String
  /// Evidence count for the claim; required for inferred, nil otherwise.
  var numerator: Int?
  /// Distinct opportunities the numerator is out of.
  var denominator: Int?
  var state: TasteStatementState
  var mutedUntil: Date?
  var pinnedValue: Double?
  var lastEvidenceAt: Date?
  var createdAt: Date
  var updatedAt: Date
  var text: String
}
