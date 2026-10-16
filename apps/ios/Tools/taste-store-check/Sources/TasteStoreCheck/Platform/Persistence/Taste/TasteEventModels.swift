import Foundation

import FLFeatureLogic

// The taste event and exposure models are the public contract types
// (`FLFeatureLogic.TasteEvent`, `FLFeatureLogic.TasteExposure`): one event model, so
// what the log persists replays through `TasteResidualEngine` unchanged. This file
// keeps the store's typed vocabulary — the enum kinds, per-kind payload structs, and
// canonical payload JSON — as a writer/reader view over the contract event, plus the
// record wrappers that carry store-only fields (cook-transaction linkage, session and
// context columns) the contract types deliberately omit.

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

// MARK: - Recipe source vocabulary

/// Versioned recipe source vocabulary of the burst5 taste contracts
/// (docs/spec/taste/contracts/taste-event.schema.json). The contract event carries the
/// source as its string form; this enum is the store's vocabulary for validating and
/// mapping it.
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

  /// The payload as the contract event's dynamic JSON object. Built key by key (not by
  /// re-encoding the typed struct) so building an event never throws; the store re-encodes
  /// the typed payload canonically at the persistence boundary.
  var dictionaryValue: [String: TasteJSONValue] {
    func number(_ value: Int?) -> TasteJSONValue? {
      value.map { .number(Double($0)) }
    }
    func number(_ value: Int64?) -> TasteJSONValue? {
      value.map { .number(Double($0)) }
    }
    func number(_ value: Double?) -> TasteJSONValue? {
      value.map { .number($0) }
    }
    func string(_ value: String?) -> TasteJSONValue? {
      value.map { .string($0) }
    }
    func bool(_ value: Bool?) -> TasteJSONValue? {
      value.map { .bool($0) }
    }

    var dict: [String: TasteJSONValue] = [:]
    func put(_ values: (String, TasteJSONValue?)...) {
      for (key, value) in values {
        if let value { dict[key] = value }
      }
    }

    switch self {
    case .viewed(let payload), .opened(let payload):
      put(("exposureId", string(payload.exposureId)), ("slatePosition", number(payload.slatePosition)))
    case .saved(let payload):
      put(("exposureId", string(payload.exposureId)))
    case .unsaved:
      break
    case .skipped(let payload):
      put(("exposureId", string(payload.exposureId)), ("reason", string(payload.reason)))
    case .cooked(let payload):
      put(
        ("cookSessionId", string(payload.cookSessionId)),
        ("exposureId", string(payload.exposureId)),
        ("rating", number(payload.rating)),
        ("servings", number(payload.servings)),
        ("slatePosition", number(payload.slatePosition)),
        ("wouldMakeAgain", bool(payload.wouldMakeAgain)))
    case .rated(let payload):
      put(("cookEventId", string(payload.cookEventId)), ("rating", number(payload.rating)))
    case .substituted(let payload):
      put(
        ("cookEventId", string(payload.cookEventId)),
        ("motivation", string(payload.motivation.rawValue)),
        ("ratio", number(payload.ratio)),
        ("substituteIngredientId", number(payload.substituteIngredientId)))
    case .servingsEdited(let payload):
      put(
        ("cookEventId", string(payload.cookEventId)),
        ("from", number(payload.from)),
        ("to", number(payload.to)))
    case .lechefFeedback(let payload):
      put(
        ("cookEventId", string(payload.cookEventId)),
        ("tag", string(payload.tag)),
        ("note", string(payload.note)))
    case .profileEdited(let payload):
      put(
        ("featureKey", string(payload.featureKey)),
        ("featureKind", string(payload.featureKind?.rawValue)),
        ("op", string(payload.op)),
        ("note", string(payload.note)))
    case .correctionApplied(let payload):
      put(
        ("statementId", string(payload.statementId)),
        ("action", string(payload.action)),
        ("note", string(payload.note)))
    }
    return dict
  }
}

// MARK: - Event record

/// The store's taste-event record: the public contract event — the one event model the
/// log persists and the engine replays — plus the store-only cook-transaction linkage and
/// the row's `at` instant. The contract event carries the same instant as an ISO-8601
/// string; `at` is the typed form the row stores.
struct TasteEventRecord: Equatable, Sendable {
  /// The contract event (FLFeatureLogic): id, ISO-8601 `at`, `kind`, payload object.
  var event: TasteEvent
  var at: Date
  /// Store-only cook-transaction linkage, not part of the contract JSON: set on the cook
  /// event itself and on every event that merges into that cook's window.
  var cookEventId: String?

  private var kindValue: TasteEventKind
  private var payloadValue: TasteEventPayload

  /// The event kind (also carried by `event.kind` as its string form).
  var kind: TasteEventKind { kindValue }
  /// The store's typed payload view over the event's JSON payload.
  var payload: TasteEventPayload { payloadValue }
  /// Ingredient id for substitution events (the contract event carries it as a JSON
  /// number).
  var ingredientId: Int64? { event.ingredient?.intValue.map(Int64.init) }
  var id: String { event.id }

  /// Builds a record from the store's typed vocabulary — how writers (the meal log, the
  /// corrections) construct events.
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
    self.at = at
    self.cookEventId = cookEventId
    self.kindValue = payload.kind
    self.payloadValue = payload
    self.event = TasteEvent(
      id: id,
      at: TasteTimestamp.string(from: at),
      kind: payload.kind.rawValue,
      eater: eater,
      recipe: recipe,
      ingredient: ingredient.map { TasteJSONValue.number(Double($0)) },
      surface: surface,
      payload: payload.dictionaryValue)
  }

  /// Builds a record from a validated contract event — how the store hands loaded rows
  /// back out. The kind and typed payload must decode from the event's own payload
  /// object; the store validates before calling this.
  init(event: TasteEvent, at: Date, cookEventId: String?) throws {
    guard let kind = TasteEventKind(rawValue: event.kind) else {
      throw TasteStoreError.unknownEventKind(event.kind)
    }
    let payloadData = try JSONEncoder().encode(event.payload)
    let payload = try TasteEventPayloadJSON.decode(payloadData, kind: kind)
    self.event = event
    self.at = at
    self.cookEventId = cookEventId
    self.kindValue = kind
    self.payloadValue = payload
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

  static func date(from string: String) -> Date? {
    iso8601Milliseconds.date(from: string)
  }
}

// MARK: - Export shape

/// Result of "export everything": the full on-device taste log in one Codable value.
/// Events are the contract events; exposures are the store records (they carry the
/// store-only session and context columns alongside the contract fields).
/// `deleteAll` is the counterpart.
struct TasteExport: Codable, Equatable, Sendable {
  var exportedAt: Date
  var events: [TasteEvent]
  var exposures: [TasteExposureRecord]
  var statements: [TasteProfileStatement]
}
