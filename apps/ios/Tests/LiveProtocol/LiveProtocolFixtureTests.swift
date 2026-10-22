import FLFeatureLogic
import Foundation
import XCTest

/// The phone end of the recorded live-protocol contract (SPEC §9.6). The fixture files are
/// byte-identical copies of the frames the gateway recorded in
/// `backend/gemini-agent/src/__tests__/liveProtocolFixtures.test.ts` — that test fails if the
/// two trees drift, and these tests pin the Swift decode/encode behavior to the same bytes:
/// every recorded proposal decodes with a matching recomputed payload hash, every recorded
/// receipt re-encodes to its exact bytes, and the executor reproduces the recorded executed
/// and rejected receipts; the expired outcome (a gateway-test stub on the recorded side) is
/// pinned through the executor's own decision after the TTL.
@MainActor
final class LiveProtocolFixtureTests: XCTestCase {
  // MARK: Fixtures

  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }

  private func fixtureData(_ name: String) -> Data {
    guard let data = try? Data(contentsOf: fixtureURL(name)) else {
      XCTFail("missing fixture \(name)")
      return Data()
    }
    return data
  }

  private func fixtureString(_ name: String) -> String {
    String(decoding: fixtureData(name), as: UTF8.self)
  }

  private func fixtureObject(_ name: String) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any]
    else {
      XCTFail("fixture \(name) is not a JSON object")
      return [:]
    }
    return object
  }

  private static let proposalFileNames: [(kind: CookProposalKind, file: String)] = [
    (.timerStart, "proposal-timer_start.json"),
    (.timerAdjust, "proposal-timer_adjust.json"),
    (.stepAdvance, "proposal-step_advance.json"),
    (.inventoryCorrection, "proposal-inventory_correction.json"),
    (.mealLog, "proposal-meal_log.json"),
    (.saveNote, "proposal-save_note.json"),
    (.plan, "proposal-plan.json"),
    (.swap, "proposal-swap.json"),
    (.swap, "proposal-swap-allow.json"),
    (.swap, "proposal-swap-blocked.json"),
    (.adaptation, "proposal-adaptation.json"),
  ]

  // MARK: Proposals decode with a matching recomputed hash

  func testEveryRecordedProposalDecodesWithMatchingPayloadHash() {
    for (kind, file) in Self.proposalFileNames {
      let proposal = LiveProposalFrames.proposal(fromEnvelopeJSON: fixtureData(file))
      guard let proposal else {
        XCTFail("\(file) did not decode")
        continue
      }
      XCTAssertEqual(proposal.kind, kind, file)
      XCTAssertEqual(
        CookProposalWire.payloadHash(of: proposal.payload), proposal.payloadHash,
        "\(file): the recomputed hash must match the envelope's")
      XCTAssertFalse(proposal.rationale.isEmpty, file)
      XCTAssertEqual(
        proposal.requiredApproval, .explicit,
        "\(file): the recorded session records no DeviceEvents, so every proposal is explicit")
      XCTAssertTrue(proposal.expiresAt > proposal.createdAt, file)
    }
  }

  func testRecordedReceiptsReencodeByteIdentically() {
    for file in [
      "receipt-executed.json", "receipt-rejected.json", "receipt-expired.json",
      "receipt-executed-swap.json", "receipt-rejected-swap.json",
    ] {
      let receipt = LiveProposalFrames.receipt(fromEnvelopeJSON: fixtureData(file))
      guard let receipt else {
        XCTFail("\(file) did not decode")
        continue
      }
      XCTAssertEqual(
        LiveProposalFrames.receiptEnvelope(receipt), fixtureString(file),
        "\(file): decode → re-encode must reproduce the recorded bytes exactly")
    }
  }

  // MARK: The executor produces the recorded receipts

  /// In-memory receipt log — the dedupe authority for these tests.
  private final class MemoryReceiptLog: CookReceiptReading {
    private var records: [String: CookReceiptRecord] = [:]
    func receipt(proposalID: String) -> CookReceiptRecord? { records[proposalID] }
    func record(_ receipt: CookReceiptRecord) { records[receipt.proposalID] = receipt }
  }

  /// A cook target with a known revision (the fixtures' snapshotRevision is 7).
  private final class StubCookTarget: CookProposalExecuting {
    let snapshotRevision = 7
    /// The swap outcome the next replay expects — the recheck story pins both
    /// outcomes (verified executes, unsupported refuses) as exact bytes.
    var swapOutcome: (recheckJSON: String, executed: Bool)? = (
      recheckJSON: "{\"verdict\":\"verified\",\"eaters\":[\"you\"],\"blockedPath\":null}",
      executed: true
    )
    func executeTimerStart(seconds: Int, label: String) -> Bool { true }
    func executeTimerAdjust(timerId: String, newDurationSeconds: Int) -> Bool { true }
    func executeStepAdvance() -> Bool { true }
    func executeSwap(originalIngredientId: Int64, substituteIngredientId: Int64)
      -> (recheckJSON: String, executed: Bool)?
    { swapOutcome }
    func executeAdaptation(change: String, servings: Int?) -> Bool { true }
    func executeMealLog() -> Bool { true }
    func executeInventoryCorrection(ingredientId: Int64, correction: String) -> Bool { true }
  }

  /// The recheck story's receipts, replayed through the executor: a clean
  /// screen against a known composition executes and the receipt carries the
  /// contract's verified recheck; the wheat-blocked swap refuses with the
  /// unsupported recheck and the executor's blocked reason. Both envelopes must
  /// be the recorded bytes — the two protocol ends pinned to one audit shape.
  func testApprovedSwapsProduceTheRecordedRecheckReceipts() throws {
    let cases: [(proposal: String, receipt: String, recheck: CookSubstitutionRecheck)] = [
      (
        "proposal-swap-allow.json", "receipt-executed-swap.json",
        CookSubstitutionRecheck(verdict: .verified, eaters: ["you"], blockedPath: nil)
      ),
      (
        "proposal-swap-blocked.json", "receipt-rejected-swap.json",
        CookSubstitutionRecheck(
          verdict: .unsupported, eaters: ["you"],
          blockedPath: "Contains wheat via soy sauce")
      ),
    ]
    for entry in cases {
      let proposal = try XCTUnwrap(
        LiveProposalFrames.proposal(fromEnvelopeJSON: fixtureData(entry.proposal)),
        "\(entry.proposal) did not decode")
      let recorded = try XCTUnwrap(
        LiveProposalFrames.receipt(fromEnvelopeJSON: fixtureData(entry.receipt)),
        "\(entry.receipt) did not decode")
      let target = StubCookTarget()
      target.swapOutcome = (
        recheckJSON: recorded.allergenRecheckJSON ?? "", executed: entry.recheck.allowsSwap
      )

      let receipt = CookProposalExecutor(receipts: MemoryReceiptLog(), target: target).process(
        proposal, decision: .approve, deviceEvents: [], now: recorded.recordedAt)

      XCTAssertEqual(receipt.state, entry.recheck.allowsSwap ? .executed : .rejected, entry.receipt)
      XCTAssertEqual(receipt.allergenRecheckJSON, entry.recheck.canonicalJSON, entry.receipt)
      XCTAssertEqual(
        LiveProposalFrames.receiptEnvelope(receipt), fixtureString(entry.receipt),
        "\(entry.receipt): the executor's envelope must be the recorded bytes")
    }
  }

  /// A recheck object that is not the contract's shape — an unknown verdict, a
  /// missing key — is a malformed frame: the receipt decodes to nil, never to a
  /// guessed pass.
  func testMalformedRecheckObjectsDoNotDecode() throws {
    let payload = try XCTUnwrap(
      fixtureObject("receipt-executed-swap.json")["payload"] as? [String: Any])
    var receiptWire = try XCTUnwrap(payload["receipt"] as? [String: Any])

    receiptWire["allergenRecheck"] = [
      "verdict": "not-a-verdict", "eaters": ["you"], "blockedPath": NSNull(),
    ]
    XCTAssertNil(
      LiveProposalFrames.receipt(fromWireObject: receiptWire),
      "an unknown verdict is malformed, not a pass")

    receiptWire["allergenRecheck"] = ["verdict": "verified", "eaters": ["you"]]
    XCTAssertNil(
      LiveProposalFrames.receipt(fromWireObject: receiptWire),
      "a recheck without blockedPath is not the contract's shape")
  }

  private func makeExecutor() -> CookProposalExecutor {
    CookProposalExecutor(receipts: MemoryReceiptLog(), target: StubCookTarget())
  }

  func testApprovedTimerStartProducesTheRecordedExecutedReceipt() {
    guard
      let proposal = LiveProposalFrames.proposal(
        fromEnvelopeJSON: fixtureData("proposal-timer_start.json"))
    else {
      return XCTFail("proposal did not decode")
    }
    guard
      let recorded = LiveProposalFrames.receipt(
        fromEnvelopeJSON: fixtureData("receipt-executed.json"))
    else {
      return XCTFail("receipt did not decode")
    }

    let receipt = makeExecutor().process(
      proposal, decision: .approve, deviceEvents: [], now: recorded.recordedAt)

    XCTAssertEqual(receipt.state, .executed)
    XCTAssertEqual(
      LiveProposalFrames.receiptEnvelope(receipt), fixtureString("receipt-executed.json"))
  }

  /// The recorded session's expired receipt is a gateway-test stub stamped at the session's
  /// fixed time — the phone's executor stamps its own `recordedAt` at decision time. So the
  /// executor behavior is pinned against a locally built envelope, and the recorded stub is
  /// pinned through decode → re-encode (the byte round-trip) instead.
  func testApprovalAfterTheTTLProducesAnExpiredReceipt() {
    guard
      let proposal = LiveProposalFrames.proposal(
        fromEnvelopeJSON: fixtureData("proposal-step_advance.json"))
    else {
      return XCTFail("proposal did not decode")
    }
    guard
      let recorded = LiveProposalFrames.receipt(
        fromEnvelopeJSON: fixtureData("receipt-expired.json"))
    else {
      return XCTFail("receipt did not decode")
    }

    // The recorded stub belongs to the same proposal and settled as expired.
    XCTAssertEqual(recorded.state, .expired)
    XCTAssertEqual(recorded.proposalID, proposal.proposalID)
    XCTAssertEqual(recorded.payloadHash, proposal.payloadHash)

    // The phone's executor, deciding after the TTL, stamps and settles an expired receipt.
    let now = proposal.expiresAt.addingTimeInterval(1)
    let receipt = makeExecutor().process(proposal, decision: .approve, deviceEvents: [], now: now)

    XCTAssertEqual(receipt.state, .expired)
    XCTAssertEqual(
      LiveProposalFrames.receiptEnvelope(receipt),
      "{\"type\":\"proposal_receipt\",\"payload\":{\"receipt\":{\"proposalID\":\"prop_000mv9v93rs3\",\"payloadHash\":\"\(proposal.payloadHash)\",\"snapshotRevision\":7,\"state\":\"expired\",\"recordedAt\":\"2026-10-15T18:27:32.000Z\"}}}",
      "the phone's expired receipt carries the recorded envelope's shape, stamped at decision time")
  }

  func testModifiedPayloadProducesTheRecordedHashMismatchReceipt() {
    guard
      let proposal = LiveProposalFrames.proposal(
        fromEnvelopeJSON: fixtureData("proposal-swap.json"))
    else {
      return XCTFail("proposal did not decode")
    }
    guard
      let recorded = LiveProposalFrames.receipt(
        fromEnvelopeJSON: fixtureData("receipt-rejected.json"))
    else {
      return XCTFail("receipt did not decode")
    }

    // The user approved a different payload than the one the hash covers: keep the
    // envelope's claimed hash, change the role underneath it.
    let tampered = CookActionProposal(
      proposalID: proposal.proposalID, createdAt: proposal.createdAt, expiresAt: proposal.expiresAt,
      payloadHash: proposal.payloadHash, kind: proposal.kind,
      payload: .swap(originalIngredientId: 11, substituteIngredientId: 7, role: "liquid"),
      rationale: proposal.rationale, requiredApproval: proposal.requiredApproval)

    let receipt = makeExecutor().process(
      tampered, decision: .approve, deviceEvents: [], now: recorded.recordedAt)

    XCTAssertEqual(receipt.state, .rejected)
    XCTAssertEqual(receipt.reason, "payload hash mismatch")
    XCTAssertEqual(
      LiveProposalFrames.receiptEnvelope(receipt), fixtureString("receipt-rejected.json"))
  }

  // MARK: meal_log is always explicit

  func testMealLogRequiresExplicitApprovalEvenWithADeviceEvent() {
    guard
      let proposal = LiveProposalFrames.proposal(
        fromEnvelopeJSON: fixtureData("proposal-meal_log.json"))
    else {
      return XCTFail("proposal did not decode")
    }
    let deviceEvent = CookDeviceEvent(
      id: "evt_1", command: "proposeMealLog", source: "touch",
      at: proposal.createdAt, revision: 7)

    XCTAssertEqual(
      makeExecutor().requiredApproval(for: proposal, deviceEvents: [deviceEvent]),
      .explicit,
      "no DeviceEvent upgrades meal_log — a voice transcript alone never authorizes it (SPEC §4)")
  }

  // MARK: The snapshot and the rejected client frame

  func testSnapshotCarriesHouseholdRestrictions() {
    let cook = CookModeViewModel(
      recipe: Recipe(
        id: 1, title: "Noodles", timeMinutes: 10, servings: 2, instructions: "1. Cook",
        tags: 0, source: .bundled, createdAt: nil),
      logsMeal: false,
      dependencies: .ephemeral())
    let payload = LiveAssistantViewModel.boundedSnapshot(
      from: cook, restrictions: ["peanut", "vegan"])
    let cookSession = payload["cookSession"] as? [String: Any]
    let eaters = cookSession?["eaters"] as? [[String: Any]]
    XCTAssertEqual(eaters?.first?["restrictions"] as? [String], ["peanut", "vegan"])
  }

  func testSnapshotFixtureHasThePhonePayloadShape() {
    let envelope = fixtureObject("snapshot.json")
    XCTAssertEqual(envelope["type"] as? String, "session_context")
    guard let payload = envelope["payload"] as? [String: Any] else {
      return XCTFail("snapshot payload missing")
    }

    let expected: [String: Any] = [
      "revision": 7,
      "pantrySnapshot": [
        "revision": 7,
        "items": [
          ["ingredientId": "eggs", "name": "eggs", "state": "sufficient", "source": "pantry"]
        ],
      ],
      "cookSession": [
        "state": "cooking",
        "currentStepIndex": 2,
        "eaters": [["name": "you", "restrictions": ["peanut", "vegan"]]],
        "activeTimers": [] as [[String: Any]],
        "cameraMode": "push-to-look",
      ],
      "recipes": [] as [[String: Any]],
    ]
    // Compare through the repo's canonical JSON: exact shape pinning without platform
    // NSNumber-bridging quirks in NSDictionary equality.
    XCTAssertEqual(
      CookProposalWire.canonicalJSON(of: payload),
      CookProposalWire.canonicalJSON(of: expected),
      "the recorded snapshot must keep the phone payload's shape: revision, pantrySnapshot, cookSession, recipes"
    )
  }

  func testRecordedClientToolResponseClassifiesAsClientAuthority() {
    let envelope = fixtureObject("client-tool-response.json")
    XCTAssertEqual(envelope["type"] as? String, "tool_response")

    XCTAssertEqual(
      LiveProposalFrames.classify(
        frameType: "tool_response", envelopeJSON: fixtureData("client-tool-response.json")),
      .clientAuthorityRejected,
      "the phone never sends a tool_response; a forged one is rejected client-side and by the gateway"
    )
  }

  func testMalformedProposalFrameDoesNotDecode() {
    let tampered = fixtureString("proposal-timer_start.json")
      .replacingOccurrences(of: "timer_start", with: "timer_rewind")
    XCTAssertNil(
      LiveProposalFrames.proposal(fromEnvelopeJSON: Data(tampered.utf8)),
      "an unknown kind decodes to nil — the client reports it malformed, never guesses")
  }
}
