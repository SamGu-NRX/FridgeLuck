import Foundation

/// The live gateway's proposal-envelope codec — the phone end of the LeChef live protocol
/// (SPEC §9.6). The frames this decodes and encodes are recorded byte-exactly by the
/// gateway's round-trip test (`backend/gemini-agent/src/__tests__/liveProtocolFixtures.test.ts`),
/// whose fixture files are mirrored under `apps/ios/Tests/LiveProtocol/Fixtures/`; both
/// protocol ends fail their tests unless the two copies stay byte-identical.
///
/// Receipt encoding is byte-exact: the envelope's key order is pinned as
/// `proposalID`, `payloadHash`, `snapshotRevision`, `state`, `recordedAt`, then the optional
/// `reason` and `allergenRecheck` extensions — the same order the gateway's recorded
/// phone-side receipts use — so a Swift-encoded receipt and a recorded fixture are the same
/// bytes. Proposal and receipt decoding is strict: a frame that does not match the contract
/// decodes to nil, and the client reports a malformed frame instead of guessing.
public enum LiveProposalFrames {
  // MARK: Timestamps — ISO 8601 with millisecond precision, the schema's wire form

  // ISO8601DateFormatter is documented thread-safe; shared for determinism.
  nonisolated(unsafe) private static let isoMillis: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let isoSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  public static func isoMillisString(_ date: Date) -> String {
    isoMillis.string(from: date)
  }

  /// Accepts both the millisecond form the gateway emits and a seconds-precision form,
  /// so hand-written contract examples decode unchanged.
  public static func date(fromISO value: String) -> Date? {
    isoMillis.date(from: value) ?? isoSeconds.date(from: value)
  }

  // MARK: Proposal decode

  /// Decodes the gateway's `{"type":"proposal","payload":{"proposal":{...}}}` envelope.
  public static func proposal(fromEnvelopeJSON data: Data) -> CookActionProposal? {
    guard
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["type"] as? String == "proposal",
      let payload = envelope["payload"] as? [String: Any],
      let wire = payload["proposal"] as? [String: Any]
    else { return nil }
    return proposal(fromWireObject: wire)
  }

  /// Decodes the inner proposal object (the envelope's `payload.proposal`).
  public static func proposal(fromWireObject wire: [String: Any]) -> CookActionProposal? {
    guard
      let proposalID = wire["proposalID"] as? String,
      let createdAtText = wire["createdAt"] as? String,
      let createdAt = date(fromISO: createdAtText),
      let expiresAtText = wire["expiresAt"] as? String,
      let expiresAt = date(fromISO: expiresAtText),
      let payloadHash = wire["payloadHash"] as? String,
      let kindRaw = wire["kind"] as? String,
      let kind = CookProposalKind(rawValue: kindRaw),
      let payloadObject = wire["payload"] as? [String: Any],
      let payload = CookProposalWire.payload(fromJSON: payloadObject, kind: kind),
      let rationale = wire["rationale"] as? String
    else { return nil }
    // The wire value is audit only — the executor derives the effective policy itself —
    // so a missing or unrecognized annotation decodes to the strict default.
    let requiredApproval =
      (wire["requiredApproval"] as? String)
      .flatMap(CookRequiredApproval.init(rawValue:)) ?? .explicit
    return CookActionProposal(
      proposalID: proposalID, createdAt: createdAt, expiresAt: expiresAt,
      payloadHash: payloadHash, kind: kind, payload: payload, rationale: rationale,
      requiredApproval: requiredApproval)
  }

  // MARK: Receipt decode / encode

  /// Decodes a `proposal_receipt` envelope — the phone's answer frame. The fixtures
  /// record exactly these bytes; tests decode them to re-encode and compare.
  public static func receipt(fromEnvelopeJSON data: Data) -> CookActionReceipt? {
    guard
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["type"] as? String == "proposal_receipt",
      let payload = envelope["payload"] as? [String: Any],
      let wire = payload["receipt"] as? [String: Any]
    else { return nil }
    return receipt(fromWireObject: wire)
  }

  public static func receipt(fromWireObject wire: [String: Any]) -> CookActionReceipt? {
    guard
      let proposalID = wire["proposalID"] as? String,
      let payloadHash = wire["payloadHash"] as? String,
      let revision = wire["snapshotRevision"] as? NSNumber,
      let stateRaw = wire["state"] as? String,
      let state = CookReceiptState(rawValue: stateRaw),
      let recordedAtText = wire["recordedAt"] as? String,
      let recordedAt = date(fromISO: recordedAtText)
    else { return nil }

    // The allergen re-check audit extension rides as the contract's object —
    // verdict | eaters | blockedPath. Decode through `CookSubstitutionRecheck`
    // so the re-encoded bytes are the type's canonical form (the same bytes the
    // phone's encoder produces); a frame carrying anything else — a string, an
    // unknown verdict, a non-string eater — is malformed and decodes to nil
    // rather than guessing (SPEC §8).
    var recheckJSON: String?
    if wire.keys.contains("allergenRecheck") {
      guard
        let object = wire["allergenRecheck"] as? [String: Any],
        let verdictRaw = object["verdict"] as? String,
        let verdict = CookSubstitutionRecheck.Verdict(rawValue: verdictRaw),
        let eatersAny = object["eaters"] as? [Any],
        eatersAny.count == eatersAny.compactMap({ $0 as? String }).count,
        object.count == 3, object.keys.contains("blockedPath")
      else { return nil }
      let eaters = eatersAny.compactMap { $0 as? String }
      let blockedPath = object["blockedPath"] as? String
      recheckJSON =
        CookSubstitutionRecheck(
          verdict: verdict, eaters: eaters, blockedPath: blockedPath
        ).canonicalJSON
    }

    return CookActionReceipt(
      proposalID: proposalID, payloadHash: payloadHash, snapshotRevision: revision.intValue,
      state: state, recordedAt: recordedAt,
      reason: wire["reason"] as? String,
      allergenRecheckJSON: recheckJSON)
  }

  /// Encodes the exact `proposal_receipt` envelope bytes the gateway's receipt path expects.
  /// Key order is pinned (see the type doc); strings are JSON-escaped; the allergen re-check
  /// audit extension (SPEC §7) rides as raw canonical JSON when present.
  public static func receiptEnvelope(_ receipt: CookActionReceipt) -> String {
    var object =
      "\"proposalID\":\(Self.escaped(receipt.proposalID))"
      + ",\"payloadHash\":\(Self.escaped(receipt.payloadHash))"
      + ",\"snapshotRevision\":\(receipt.snapshotRevision)"
      + ",\"state\":\(Self.escaped(receipt.state.rawValue))"
      + ",\"recordedAt\":\(Self.escaped(isoMillisString(receipt.recordedAt)))"
    if let reason = receipt.reason {
      object += ",\"reason\":\(Self.escaped(reason))"
    }
    if let recheck = receipt.allergenRecheckJSON {
      object += ",\"allergenRecheck\":\(recheck)"
    }
    return "{\"type\":\"proposal_receipt\",\"payload\":{\"receipt\":{\(object)}}}"
  }

  // MARK: Inbound frame classification

  /// What an inbound gateway frame is, for the client layer. `tool_response` is client
  /// authority: the phone never sends one, and the gateway answers one with `client_error`
  /// without relaying it to the model (SPEC §9.6 — verified by the recorded fixture).
  public enum InboundFrame: Equatable {
    case proposal(CookActionProposal)
    case clientAuthorityRejected
    case other
  }

  public static func classify(frameType: String, envelopeJSON: Data) -> InboundFrame {
    switch frameType {
    case "proposal":
      if let proposal = proposal(fromEnvelopeJSON: envelopeJSON) {
        return .proposal(proposal)
      }
      return .other
    case "tool_response":
      return .clientAuthorityRejected
    default:
      return .other
    }
  }

  private static func escaped(_ string: String) -> String {
    guard
      let data = try? JSONEncoder().encode(string),
      let encoded = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return encoded
  }
}
