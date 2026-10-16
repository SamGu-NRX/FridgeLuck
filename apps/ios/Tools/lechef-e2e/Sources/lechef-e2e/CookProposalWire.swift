#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The LeChef proposal / receipt contract (SPEC §8), adopted from PR #102's pinned wire
/// (`origin/overhaul/lechef-f1`, `contracts/proposal.schema.json`). The backend model only ever
/// proposes; the phone checks, executes at most once on approval, and returns a receipt.
///
/// Timestamps on the Swift side are `Date`; the canonical encoder emits the schema's ISO 8601
/// form. `payloadHash` is SHA-256 over compact canonical JSON of the payload — sorted keys
/// recursively, no whitespace — matching `canonicalJsonString` in `wire.ts`.
public enum CookProposalKind: String, Codable, Equatable, Sendable, CaseIterable {
  case timerStart = "timer_start"
  case timerAdjust = "timer_adjust"
  case stepAdvance = "step_advance"
  case inventoryCorrection = "inventory_correction"
  case mealLog = "meal_log"
  case saveNote = "save_note"
  case plan
  case swap
  case adaptation
}

/// Who must approve before the phone executes. `meal_log` is always explicit — a voice
/// transcript alone never authorizes it (SPEC §4). `device-auto` is only possible for timer
/// proposals citing a phone-recorded, unconsumed `DeviceEvent` at the current revision naming
/// the same tool — one event initiates one action, then it is consumed.
public enum CookRequiredApproval: String, Codable, Equatable, Sendable {
  case explicit
  case deviceAuto = "device-auto"
}

/// The payload discriminated union — the schema's `payload` oneOf. Each case encodes only its
/// own keys (no kind key); the envelope carries the kind.
public enum CookProposalPayload: Equatable, Sendable {
  case timerStart(durationMinutes: Double, label: String?)
  case timerAdjust(timerId: String, newDurationMinutes: Double?)
  case stepAdvance(stepIndex: Int)
  case inventoryCorrection(ingredientId: Int64, correction: String)
  case mealLog(recipe: CookRecipeRef?)
  case saveNote(prompt: String?, noteSavedMarker: Bool?)
  case plan(dinnerCount: Int, constraints: [String])
  case swap(originalIngredientId: Int64, substituteIngredientId: Int64, role: String)
  case adaptation(change: String, servings: Int?)
}

/// A typed action the backend proposes. Decoded from the wire; the phone then derives
/// `requiredApproval` itself — a model-sent value is never trusted (see `CookProposalExecutor`).
public struct CookActionProposal: Equatable, Sendable {
  public let proposalID: String
  public let createdAt: Date
  public let expiresAt: Date
  public let payloadHash: String
  public let kind: CookProposalKind
  public let payload: CookProposalPayload
  public let rationale: String
  /// As sent on the wire. The executor derives the effective policy; this field is audit only.
  public let requiredApproval: CookRequiredApproval

  public init(
    proposalID: String, createdAt: Date, expiresAt: Date, payloadHash: String,
    kind: CookProposalKind, payload: CookProposalPayload, rationale: String,
    requiredApproval: CookRequiredApproval
  ) {
    self.proposalID = proposalID
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.payloadHash = payloadHash
    self.kind = kind
    self.payload = payload
    self.rationale = rationale
    self.requiredApproval = requiredApproval
  }
}

/// Receipt states, exactly as `receipt.schema.json` pins them.
public enum CookReceiptState: String, Codable, Equatable, Sendable {
  case executed
  case rejected
  case expired
  case cancelled
}

/// The phone's answer to a proposal. The proposalID is the idempotency key: apply at most once.
public struct CookActionReceipt: Equatable, Sendable {
  public let proposalID: String
  public let payloadHash: String
  public let snapshotRevision: Int
  public let state: CookReceiptState
  public let recordedAt: Date
  /// `already_resolved`, `superseded`, payload-hash mismatch, or the blocked allergen path.
  public let reason: String?
  /// The allergen re-check audit extension (SPEC §7) for swap proposals.
  public let allergenRecheckJSON: String?
  /// The phone-recorded device event this execution consumed, when approval derived from one.
  /// One event initiates one action (SPEC §4); the caller drops the event from its store.
  public let consumedDeviceEventID: String?

  public init(
    proposalID: String, payloadHash: String, snapshotRevision: Int, state: CookReceiptState,
    recordedAt: Date, reason: String? = nil, allergenRecheckJSON: String? = nil,
    consumedDeviceEventID: String? = nil
  ) {
    self.proposalID = proposalID
    self.payloadHash = payloadHash
    self.snapshotRevision = snapshotRevision
    self.state = state
    self.recordedAt = recordedAt
    self.reason = reason
    self.allergenRecheckJSON = allergenRecheckJSON
    self.consumedDeviceEventID = consumedDeviceEventID
  }
}

/// A phone-authored user command — a touch, or a voice command with the transcript toggle on.
/// The model cannot create, alter, or replay one; citing a valid one is the only path to
/// `device-auto` (SPEC §4 — the model cannot manufacture approval).
public struct CookDeviceEvent: Equatable, Sendable {
  public let id: String
  /// The proposal tool this command initiates, e.g. "proposeTimerStart".
  public let command: String
  /// A voice source never upgrades meal_log — explicit always.
  public let source: String
  public let at: Date
  /// The snapshot revision at which the phone recorded the event.
  public let revision: Int

  public init(id: String, command: String, source: String, at: Date, revision: Int) {
    self.id = id
    self.command = command
    self.source = source
    self.at = at
    self.revision = revision
  }
}

public enum CookProposalWire {
  // MARK: Canonical JSON and hashing

  /// Compact canonical JSON: sorted keys recursively, no whitespace — matches `canonicalJsonString`
  /// in `wire.ts`, so the phone and the backend hash identical bytes.
  public static func canonicalJSON(of value: Any) -> String? {
    switch value {
    case is NSNull:
      return "null"
    case let string as String:
      return Self.jsonString(string)
    case let number as NSNumber:
      // Bool bridges to NSNumber in Swift, so the boolean check must be an identity check on
      // the number itself — a plain `as Bool` cast would also match integer 1 and 0.
      #if canImport(Darwin)
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
          return number.boolValue ? "true" : "false"
        }
      #else
        // Linux: Core Foundation's CFBoolean is unavailable; NSNumber bridges Bool with the
        // "c" objCType, which no signed integer width shares there.
        if number.objCType.pointee == 99 {
          return number.boolValue ? "true" : "false"
        }
      #endif
      return Self.canonicalNumber(number)
    case let boolean as Bool:
      return boolean ? "true" : "false"
    case let array as [Any]:
      return "[" + array.compactMap { canonicalJSON(of: $0) }.joined(separator: ",") + "]"
    case let dictionary as [String: Any]:
      let entries =
        dictionary
        .compactMap { key, value -> String? in
          guard let encoded = canonicalJSON(of: value) else { return nil }
          return "\(Self.jsonString(key)):\(encoded)"
        }
        .sorted()
      return "{" + entries.joined(separator: ",") + "}"
    default:
      return nil
    }
  }

  /// SHA-256 over the compact canonical JSON of the payload — the schema's `payloadHash` body.
  public static func payloadHash(of payload: CookProposalPayload) -> String? {
    guard let json = Self.canonicalJSON(of: payloadJSONObject(payload)) else { return nil }
    let digest = SHA256.hash(data: Data(json.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  /// The payload's hash as the backend computes it — cross-check in tests.
  public static func payloadHashOfJSON(_ object: [String: Any]) -> String? {
    guard let json = Self.canonicalJSON(of: object) else { return nil }
    let digest = SHA256.hash(data: Data(json.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Payload ↔ JSON

  /// The payload as a plain JSON object tree, keyed exactly as the schema's oneOf branches.
  public static func payloadJSONObject(_ payload: CookProposalPayload) -> [String: Any] {
    switch payload {
    case .timerStart(let durationMinutes, let label):
      var object: [String: Any] = ["durationMinutes": durationMinutes]
      if let label { object["label"] = label }
      return object
    case .timerAdjust(let timerId, let newDurationMinutes):
      var object: [String: Any] = ["timerId": timerId]
      if let newDurationMinutes { object["newDurationMinutes"] = newDurationMinutes }
      return object
    case .stepAdvance(let stepIndex):
      return ["stepIndex": stepIndex]
    case .inventoryCorrection(let ingredientId, let correction):
      return ["ingredientId": ingredientId, "correction": correction]
    case .mealLog(let recipe):
      var object: [String: Any] = [:]
      if let recipe {
        object["recipe"] = [
          "source": recipe.source.rawValue, "id": recipe.id, "revision": recipe.revision,
        ]
      }
      return object
    case .saveNote(let prompt, let noteSavedMarker):
      var object: [String: Any] = [:]
      if let prompt { object["prompt"] = prompt }
      if let noteSavedMarker { object["noteSavedMarker"] = noteSavedMarker }
      return object
    case .plan(let dinnerCount, let constraints):
      var object: [String: Any] = ["dinnerCount": dinnerCount]
      if !constraints.isEmpty { object["constraints"] = constraints }
      return object
    case .swap(let originalIngredientId, let substituteIngredientId, let role):
      return [
        "originalIngredientId": originalIngredientId,
        "substituteIngredientId": substituteIngredientId,
        "role": role,
      ]
    case .adaptation(let change, let servings):
      var object: [String: Any] = ["change": change]
      if let servings { object["servings"] = servings }
      return object
    }
  }

  /// Decodes a payload JSON object into the union, keyed by the envelope's kind. Unknown or
  /// mismatched shapes decode to nil — the caller rejects, never guesses.
  public static func payload(fromJSON object: [String: Any], kind: CookProposalKind)
    -> CookProposalPayload?
  {
    switch kind {
    case .timerStart:
      guard let minutes = object["durationMinutes"] as? NSNumber, minutes.doubleValue > 0,
        minutes.doubleValue <= 180
      else { return nil }
      return .timerStart(durationMinutes: minutes.doubleValue, label: object["label"] as? String)
    case .timerAdjust:
      guard let timerId = object["timerId"] as? String else { return nil }
      let minutes = (object["newDurationMinutes"] as? NSNumber)?.doubleValue
      return .timerAdjust(timerId: timerId, newDurationMinutes: minutes)
    case .stepAdvance:
      guard let stepIndex = object["stepIndex"] as? NSNumber, stepIndex.intValue >= 0
      else { return nil }
      return .stepAdvance(stepIndex: stepIndex.intValue)
    case .inventoryCorrection:
      guard let ingredientId = object["ingredientId"] as? NSNumber,
        let correction = object["correction"] as? String
      else { return nil }
      return .inventoryCorrection(ingredientId: ingredientId.int64Value, correction: correction)
    case .mealLog:
      var recipe: CookRecipeRef?
      if let refObject = object["recipe"] as? [String: Any],
        let id = refObject["id"] as? String,
        let sourceRaw = refObject["source"] as? String,
        let source = CookRecipeSource(rawValue: sourceRaw),
        let revision = refObject["revision"] as? NSNumber, revision.intValue >= 1
      {
        recipe = CookRecipeRef(source: source, id: id, revision: revision.intValue)
      }
      return .mealLog(recipe: recipe)
    case .saveNote:
      return .saveNote(
        prompt: object["prompt"] as? String,
        noteSavedMarker: object["noteSavedMarker"] as? Bool)
    case .plan:
      guard let dinnerCount = object["dinnerCount"] as? NSNumber, dinnerCount.intValue >= 1,
        dinnerCount.intValue <= 7
      else { return nil }
      return .plan(
        dinnerCount: dinnerCount.intValue, constraints: object["constraints"] as? [String] ?? [])
    case .swap:
      guard let original = object["originalIngredientId"] as? NSNumber,
        let substitute = object["substituteIngredientId"] as? NSNumber,
        let role = object["role"] as? String
      else { return nil }
      return .swap(
        originalIngredientId: original.int64Value,
        substituteIngredientId: substitute.int64Value,
        role: role)
    case .adaptation:
      guard let change = object["change"] as? String else { return nil }
      let servings = (object["servings"] as? NSNumber)?.intValue
      return .adaptation(change: change, servings: servings)
    }
  }

  // MARK: Helpers

  private static func canonicalNumber(_ number: NSNumber) -> String {
    // Match canonicalJsonString in wire.ts: integers print bare, other numbers print as JS
    // String() would — Swift's shortest round-trip Double description matches for wire values.
    if number.isExactInteger { return String(number.int64Value) }
    return "\(number.doubleValue)"
  }

  private static func jsonString(_ string: String) -> String {
    guard let data = try? JSONEncoder().encode(string),
      let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
  }
}

extension NSNumber {
  /// True when the number is an integer value (an 18.0 duration is an integer on the wire).
  var isExactInteger: Bool {
    Double(int64Value) == doubleValue
  }
}
