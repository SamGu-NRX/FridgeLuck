import CoreFoundation
import Foundation

// MARK: - Surfaces

/// Canonical `surface` values for the events the app emits today. The pattern is dotted
/// lowercase (docs/spec/taste/contracts/taste-event.schema.json); new surfaces must match
/// the schema's surface pattern `^[a-z][a-z0-9_]{2,31}(\.[a-z][a-z0-9_]{1,31}){0,3}$`.
enum TasteSurface {
  public static let cookComplete = "cook.complete"
  public static let cookIngredients = "cook.ingredients"
  public static let recipeDetail = "recipe.detail"
  public static let cookbookSaved = "cookbook.saved"
  public static let homeTonight = "home.tonight"
  public static let tasteProfile = "taste.profile"
}

// MARK: - RecipeRef

/// Versioned recipe reference shared by every burst5 taste contract
/// (docs/spec/taste/contracts/taste-event.schema.json).
enum TasteRecipeSource: String, Codable, Sendable, CaseIterable {
  case catalog
  case user
  case community
  case generated

  /// Maps the local `recipes.source` column onto the contract's source vocabulary.
  init(recipeSource: RecipeSource) {
    switch recipeSource {
    case .bundled: self = .catalog
    case .user: self = .user
    case .aiGenerated: self = .generated
    }
  }
}

struct TasteRecipeRef: Codable, Equatable, Hashable, Sendable {
  var source: TasteRecipeSource
  var id: String
  var revision: Int

  init(source: TasteRecipeSource, id: String, revision: Int = 1) {
    self.source = source
    self.id = id
    self.revision = revision
  }
}

// MARK: - Feature keys

/// Feature families of the rule-anchored residual ranker
/// (docs/spec/taste/SPEC.md §2.1). Feature keys are `<kind>:<id-or-name>`.
enum TasteFeatureKind: String, Codable, Sendable, CaseIterable {
  case ingredient
  case cuisine
  case technique
  case time
  case nutrient
  case spice
  case tool
  case other
}

// MARK: - Event kinds

/// The twelve observed taste-relevant actions
/// (docs/spec/taste/contracts/taste-event.schema.json).
enum TasteEventKind: String, Codable, Sendable, CaseIterable {
  case recipeViewed = "recipe_viewed"
  case recipeOpened = "recipe_opened"
  case recipeSaved = "recipe_saved"
  case recipeUnsaved = "recipe_unsaved"
  case recipeSkipped = "recipe_skipped"
  case recipeCooked = "recipe_cooked"
  case recipeRated = "recipe_rated"
  case ingredientSubstituted = "ingredient_substituted"
  case servingsEdited = "servings_edited"
  case lechefFeedback = "lechef_feedback"
  case profileEdited = "profile_edited"
  case correctionApplied = "correction_applied"
}

/// Why a swap happened. `recipeRecommended` substitutions are experiments suggested by the
/// ranker and carry no preference evidence; the other two are the cook's own choice
/// (docs/spec/taste/SPEC.md §2.3).
enum TasteSwapMotivation: String, Codable, Sendable, CaseIterable {
  case preferred
  case noneAvailable = "none_available"
  case recipeRecommended = "recipe_recommended"
}

// MARK: - Payloads

/// Payload of `recipe_viewed` / `recipe_opened`. Skips and views resolve against their
/// `exposureId` (docs/spec/taste/SPEC.md §2.4).
struct TasteSlateInteractionPayload: Codable, Equatable, Sendable {
  var exposureId: String?
  var slatePosition: Int?
}

/// Payload of `recipe_saved`.
struct TasteSavedPayload: Codable, Equatable, Sendable {
  var exposureId: String?
}

/// Payload of `recipe_unsaved` — intentionally empty.
struct TasteUnsavedPayload: Codable, Equatable, Sendable {}

/// Payload of `recipe_skipped`.
struct TasteSkippedPayload: Codable, Equatable, Sendable {
  var exposureId: String?
  var reason: String?
}

/// Payload of `recipe_cooked`. The rating rides on the cook when it is known at cook time;
/// a later rating arrives as a separate `recipe_rated` event that merges into the cook's
/// transaction window via `cookEventId` (docs/spec/taste/SPEC.md §2.3).
struct TasteCookedPayload: Codable, Equatable, Sendable {
  var cookSessionId: String?
  var exposureId: String?
  var rating: Int?
  var servings: Int?
  var slatePosition: Int?
  var wouldMakeAgain: Bool?
}

/// Payload of `recipe_rated`.
struct TasteRatedPayload: Codable, Equatable, Sendable {
  var cookEventId: String?
  var rating: Int
}

/// Payload of `ingredient_substituted`.
struct TasteSubstitutionPayload: Codable, Equatable, Sendable {
  var cookEventId: String?
  var motivation: TasteSwapMotivation
  var ratio: Double?
  var substituteIngredientId: Int64?
}

/// Payload of `servings_edited`.
struct TasteServingsEditedPayload: Codable, Equatable, Sendable {
  var cookEventId: String?
  var from: Int
  var to: Int
}

/// Payload of `lechef_feedback`.
struct TasteLechefFeedbackPayload: Codable, Equatable, Sendable {
  var cookEventId: String?
  var tag: String
  var note: String?
}

/// Payload of `profile_edited`.
struct TasteProfileEditedPayload: Codable, Equatable, Sendable {
  var featureKey: String?
  var featureKind: TasteFeatureKind?
  var op: String
  var note: String?
}

/// Payload of `correction_applied`.
struct TasteCorrectionAppliedPayload: Codable, Equatable, Sendable {
  var statementId: String
  var action: String?
  var note: String?
}

// MARK: - Payload envelope

/// Kind-specific payload of a taste event, one case per event kind. The JSON encoding of
/// each case is exactly the flat payload object the contract examples show (camelCase
/// keys); the kind is carried by the event itself, never re-encoded into the payload.
enum TasteEventPayload: Equatable, Sendable {
  case viewed(TasteSlateInteractionPayload)
  case opened(TasteSlateInteractionPayload)
  case saved(TasteSavedPayload)
  case unsaved(TasteUnsavedPayload)
  case skipped(TasteSkippedPayload)
  case cooked(TasteCookedPayload)
  case rated(TasteRatedPayload)
  case substituted(TasteSubstitutionPayload)
  case servingsEdited(TasteServingsEditedPayload)
  case lechefFeedback(TasteLechefFeedbackPayload)
  case profileEdited(TasteProfileEditedPayload)
  case correctionApplied(TasteCorrectionAppliedPayload)

  var kind: TasteEventKind {
    switch self {
    case .viewed: return .recipeViewed
    case .opened: return .recipeOpened
    case .saved: return .recipeSaved
    case .unsaved: return .recipeUnsaved
    case .skipped: return .recipeSkipped
    case .cooked: return .recipeCooked
    case .rated: return .recipeRated
    case .substituted: return .ingredientSubstituted
    case .servingsEdited: return .servingsEdited
    case .lechefFeedback: return .lechefFeedback
    case .profileEdited: return .profileEdited
    case .correctionApplied: return .correctionApplied
    }
  }
}

// MARK: - Event

/// One observed taste-relevant action, shaped after
/// docs/spec/taste/contracts/taste-event.schema.json. `id` is a stable UUID v4 string
/// (lowercase); replaying an id is a no-op.
struct TasteEvent: Equatable, Sendable {
  var id: String
  var at: Date
  var eater: String?
  var recipe: TasteRecipeRef?
  var ingredient: Int64?
  var surface: String
  var payload: TasteEventPayload
  /// Internal cook-transaction linkage, not part of the contract JSON: set on the cook
  /// event itself and on every event that merges into that cook's window.
  var cookEventId: String?

  var kind: TasteEventKind { payload.kind }

  init(
    id: String = UUID().uuidString.lowercased(),
    at: Date = Date(),
    eater: String? = nil,
    recipe: TasteRecipeRef? = nil,
    ingredient: Int64? = nil,
    surface: String,
    payload: TasteEventPayload,
    cookEventId: String? = nil
  ) {
    self.id = id
    self.at = at
    self.eater = eater
    self.recipe = recipe
    self.ingredient = ingredient
    self.surface = surface
    self.payload = payload
    self.cookEventId = cookEventId
  }
}

// MARK: - Payload JSON

/// Canonical serialization of payloads: JSON with sorted keys, matching the contract
/// examples. The store uses it for the `payload` column and the export uses it so a
/// replayed event re-encodes byte-identically. Encoders are created per call because
/// JSONEncoder is not Sendable and the taste log is written from arbitrary threads.
enum TasteEventPayloadJSON {
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func encode(_ payload: TasteEventPayload) throws -> Data {
    let encoder = makeEncoder()
    switch payload {
    case .viewed(let p): return try encoder.encode(p)
    case .opened(let p): return try encoder.encode(p)
    case .saved(let p): return try encoder.encode(p)
    case .unsaved(let p): return try encoder.encode(p)
    case .skipped(let p): return try encoder.encode(p)
    case .cooked(let p): return try encoder.encode(p)
    case .rated(let p): return try encoder.encode(p)
    case .substituted(let p): return try encoder.encode(p)
    case .servingsEdited(let p): return try encoder.encode(p)
    case .lechefFeedback(let p): return try encoder.encode(p)
    case .profileEdited(let p): return try encoder.encode(p)
    case .correctionApplied(let p): return try encoder.encode(p)
    }
  }

  static func decode(_ data: Data, kind: TasteEventKind) throws -> TasteEventPayload {
    let decoder = JSONDecoder()
    func decode<P: Decodable>(_ type: P.Type) throws -> P {
      try decoder.decode(type, from: data)
    }
    switch kind {
    case .recipeViewed: return .viewed(try decode(TasteSlateInteractionPayload.self))
    case .recipeOpened: return .opened(try decode(TasteSlateInteractionPayload.self))
    case .recipeSaved: return .saved(try decode(TasteSavedPayload.self))
    case .recipeUnsaved: return .unsaved(try decode(TasteUnsavedPayload.self))
    case .recipeSkipped: return .skipped(try decode(TasteSkippedPayload.self))
    case .recipeCooked: return .cooked(try decode(TasteCookedPayload.self))
    case .recipeRated: return .rated(try decode(TasteRatedPayload.self))
    case .ingredientSubstituted: return .substituted(try decode(TasteSubstitutionPayload.self))
    case .servingsEdited: return .servingsEdited(try decode(TasteServingsEditedPayload.self))
    case .lechefFeedback: return .lechefFeedback(try decode(TasteLechefFeedbackPayload.self))
    case .profileEdited: return .profileEdited(try decode(TasteProfileEditedPayload.self))
    case .correctionApplied: return .correctionApplied(try decode(TasteCorrectionAppliedPayload.self))
    }
  }
}

// MARK: - Export JSON

/// Minimal JSON value tree so contract-shaped export JSON can embed an arbitrary payload
/// object inside a Codable `Codable` container.
enum TasteJSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([TasteJSONValue])
  case object([String: TasteJSONValue])
}

extension TasteJSONValue: Codable {
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int64.self) {
      self = .int(int)
    } else if let double = try? container.decode(Double.self) {
      self = .double(double)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([TasteJSONValue].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: TasteJSONValue].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// Bridges a `JSONSerialization` tree into values (unused by the store; kept for tools
  /// that export taste JSON through serialization APIs).
  static func from(any: Any) -> TasteJSONValue {
    switch any {
    case is NSNull:
      return .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      let encoding = String(cString: number.objCType)
      switch encoding {
      case "c", "i", "s", "l", "q", "B":
        return .int(number.int64Value)
      default:
        return .double(number.doubleValue)
      }
    case let string as String:
      return .string(string)
    case let array as [Any]:
      return .array(array.map { from(any: $0) })
    case let dictionary as [String: Any]:
      var mapped: [String: TasteJSONValue] = [:]
      for (key, value) in dictionary {
        mapped[key] = from(any: value)
      }
      return .object(mapped)
    default:
      return .string(String(describing: any))
    }
  }
}

/// ISO-8601 UTC with millisecond precision — the timestamp shape the taste contracts
/// pin (`"2026-10-12T18:30:00.000Z"`).
enum TasteTimestamp {
  static let iso8601Milliseconds: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
  }()

  static func string(from date: Date) -> String {
    iso8601Milliseconds.string(from: date)
  }
}

// MARK: - Event export shape

extension TasteEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, at, kind, eater, recipe, ingredient, surface, payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    at = try container.decode(Date.self, forKey: .at)
    eater = try container.decodeIfPresent(String.self, forKey: .eater)
    recipe = try container.decodeIfPresent(TasteRecipeRef.self, forKey: .recipe)
    ingredient = try container.decodeIfPresent(Int64.self, forKey: .ingredient)
    surface = try container.decode(String.self, forKey: .surface)
    let kindRaw = try container.decode(String.self, forKey: .kind)
    guard let decodedKind = TasteEventKind(rawValue: kindRaw) else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "unknown taste event kind: \(kindRaw)")
    }
    let payloadValue = try container.decode(TasteJSONValue.self, forKey: .payload)
    let reencoded = try JSONEncoder().encode(payloadValue)
    payload = try TasteEventPayloadJSON.decode(reencoded, kind: decodedKind)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(at, forKey: .at)
    try container.encode(kind.rawValue, forKey: .kind)
    try container.encodeIfPresent(eater, forKey: .eater)
    try container.encodeIfPresent(recipe, forKey: .recipe)
    try container.encodeIfPresent(ingredient, forKey: .ingredient)
    try container.encode(surface, forKey: .surface)
    let payloadData = try TasteEventPayloadJSON.encode(payload)
    let payloadValue = try JSONDecoder().decode(TasteJSONValue.self, from: payloadData)
    try container.encode(payloadValue, forKey: .payload)
  }
}

/// Result of "export everything": the full on-device taste log in one Codable value.
/// `deleteAll` is the counterpart.
struct TasteExport: Codable, Equatable, Sendable {
  var exportedAt: Date
  var events: [TasteEvent]
  var exposures: [TasteExposure]
  var statements: [TasteProfileStatement]
}

