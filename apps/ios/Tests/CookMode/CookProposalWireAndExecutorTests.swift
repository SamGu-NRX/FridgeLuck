import FLFeatureLogic
import XCTest

/// The proposal wire's canonical JSON and hashing, cross-checked against SHA-256 digests
/// computed with Node's `crypto` (an independent implementation), plus payload round-trips.
final class CookProposalWireTests: XCTestCase {
  // MARK: Canonical JSON

  func testCanonicalJSONSortsKeysRecursivelyAndCompacts() {
    let object: [String: Any] = [
      "b": 1, "a": true,
      "c": ["z": 1.5, "y": "x"],
      "d": ["two", "one"],
    ]
    XCTAssertEqual(
      CookProposalWire.canonicalJSON(of: object),
      #"{"a":true,"b":1,"c":{"y":"x","z":1.5},"d":["two","one"]}"#)
  }

  func testCanonicalJSONBooleansEncodeAsTrueFalse() {
    // Bool bridges to NSNumber in Swift; the canonical form must still be true/false, never 1/0.
    XCTAssertEqual(CookProposalWire.canonicalJSON(of: true), "true")
    XCTAssertEqual(
      CookProposalWire.canonicalJSON(of: ["noteSavedMarker": true, "prompt": "Taste?"]),
      #"{"noteSavedMarker":true,"prompt":"Taste?"}"#)
  }

  func testCanonicalJSONIntegersPrintBareAndDoublesKeepFraction() {
    XCTAssertEqual(CookProposalWire.canonicalJSON(of: 12.0), "12")
    XCTAssertEqual(CookProposalWire.canonicalJSON(of: 1.5), "1.5")
  }

  // MARK: Payload hashing — digests computed with Node crypto over the canonical bytes

  func testPayloadHashMatchesIndependentReferenceDigests() {
    // Each expectation is `sha256(canonicalJSON)` where canonicalJSON was produced and hashed
    // with Node's crypto module (scripts in the PR body); the strings are the canonical bytes.
    let expectations: [(CookProposalPayload, String, String)] = [
      (
        .timerStart(durationMinutes: 12, label: "Udon broth"),
        #"{"durationMinutes":12,"label":"Udon broth"}"#,
        "sha256:8f84756aa4fe930873667da146cd56b1259bab1e823ba3c519c3c827584c491a"
      ),
      (
        .timerStart(durationMinutes: 1.5, label: nil),
        #"{"durationMinutes":1.5}"#,
        "sha256:128d9ab7301a13bfaba31db17789b365d53d15a42ae528fb22998852eb6fc7fe"
      ),
      (
        .swap(originalIngredientId: 42, substituteIngredientId: 7, role: "required"),
        #"{"originalIngredientId":42,"role":"required","substituteIngredientId":7}"#,
        "sha256:593e1a12d17914800c5f2f0b44fc3fee8b0e09040bb4ae7ad25012ebf9bcb03a"
      ),
      (
        .adaptation(change: "servings", servings: 4),
        #"{"change":"servings","servings":4}"#,
        "sha256:dfd99f2eb0c6d919406b8059a1ef0fef93176b759510aecb4580a7fadcf868c8"
      ),
      (
        .stepAdvance(stepIndex: 2),
        #"{"stepIndex":2}"#,
        "sha256:03683d59c738f266be2602ed6ab1588c498f464106dac6722c1b7a9c291a929e"
      ),
      (
        .saveNote(prompt: "How did it taste?", noteSavedMarker: true),
        #"{"noteSavedMarker":true,"prompt":"How did it taste?"}"#,
        "sha256:874b5d9884c43532e8a99fcbab4cbba56b4a6ad9c8d06ffdcabfbdaa35d1f7bc"
      ),
    ]
    for (payload, canonical, digest) in expectations {
      XCTAssertEqual(
        CookProposalWire.canonicalJSON(of: CookProposalWire.payloadJSONObject(payload)), canonical)
      XCTAssertEqual(CookProposalWire.payloadHash(of: payload), digest)
    }
  }

  // MARK: Payload round-trips

  func testPayloadRoundTrips() {
    let payloads: [CookProposalPayload] = [
      .timerStart(durationMinutes: 12, label: "Udon broth"),
      .timerStart(durationMinutes: 1.5, label: nil),
      .timerAdjust(timerId: "t1", newDurationMinutes: 3),
      .stepAdvance(stepIndex: 2),
      .inventoryCorrection(ingredientId: 9, correction: "half used"),
      .mealLog(recipe: CookRecipeRef(source: .catalog, id: "udon", revision: 3)),
      .mealLog(recipe: nil),
      .saveNote(prompt: "Salty?", noteSavedMarker: nil),
      .plan(dinnerCount: 4, constraints: ["vegetarian"]),
      .swap(originalIngredientId: 42, substituteIngredientId: 7, role: "required"),
      .adaptation(change: "servings", servings: 4),
      .adaptation(change: "less salt", servings: nil),
    ]
    for payload in payloads {
      let kind: CookProposalKind
      switch payload {
      case .timerStart: kind = .timerStart
      case .timerAdjust: kind = .timerAdjust
      case .stepAdvance: kind = .stepAdvance
      case .inventoryCorrection: kind = .inventoryCorrection
      case .mealLog: kind = .mealLog
      case .saveNote: kind = .saveNote
      case .plan: kind = .plan
      case .swap: kind = .swap
      case .adaptation: kind = .adaptation
      }
      XCTAssertEqual(
        CookProposalWire.payload(fromJSON: CookProposalWire.payloadJSONObject(payload), kind: kind),
        payload)
    }
  }

  func testInvalidPayloadsDecodeNil() {
    XCTAssertNil(
      CookProposalWire.payload(
        fromJSON: ["durationMinutes": 0], kind: .timerStart))
    XCTAssertNil(
      CookProposalWire.payload(
        fromJSON: ["durationMinutes": 200], kind: .timerStart))
    XCTAssertNil(
      CookProposalWire.payload(
        fromJSON: ["dinnerCount": 8], kind: .plan))
    XCTAssertNil(
      CookProposalWire.payload(
        fromJSON: ["stepIndex": -1], kind: .stepAdvance))
    XCTAssertNil(
      CookProposalWire.payload(
        fromJSON: ["originalIngredientId": 1, "substituteIngredientId": 2], kind: .swap))
  }
}

// MARK: - Executor fakes

private final class TestTarget: CookProposalExecuting {
  var revision = 1
  var timerStartResult = true
  var timerAdjustResult = true
  var stepAdvanceResult = true
  var swapOutcome: (recheckJSON: String, executed: Bool)?
  var adaptationResult = true
  var mealLogResult = true
  var inventoryResult = true

  private(set) var startedTimers: [(seconds: Int, label: String)] = []
  private(set) var adjustedTimers: [(id: String, seconds: Int)] = []
  private(set) var stepAdvances = 0
  private(set) var swaps: [(original: Int64, substitute: Int64)] = []
  private(set) var adaptations: [(change: String, servings: Int?)] = []
  private(set) var mealLogs = 0
  private(set) var corrections: [(id: Int64, correction: String)] = []

  var snapshotRevision: Int { revision }
  func executeTimerStart(seconds: Int, label: String) -> Bool {
    startedTimers.append((seconds, label))
    return timerStartResult
  }
  func executeTimerAdjust(timerId: String, newDurationSeconds: Int) -> Bool {
    adjustedTimers.append((timerId, newDurationSeconds))
    return timerAdjustResult
  }
  func executeStepAdvance() -> Bool {
    stepAdvances += 1
    return stepAdvanceResult
  }
  func executeSwap(originalIngredientId: Int64, substituteIngredientId: Int64)
    -> (recheckJSON: String, executed: Bool)?
  {
    swaps.append((originalIngredientId, substituteIngredientId))
    return swapOutcome
  }
  func executeAdaptation(change: String, servings: Int?) -> Bool {
    adaptations.append((change, servings))
    return adaptationResult
  }
  func executeMealLog() -> Bool {
    mealLogs += 1
    return mealLogResult
  }
  func executeInventoryCorrection(ingredientId: Int64, correction: String) -> Bool {
    corrections.append((ingredientId, correction))
    return inventoryResult
  }
}

private final class InMemoryReceipts: CookReceiptReading {
  private var records: [String: CookReceiptRecord] = [:]
  func receipt(proposalID: String) -> CookReceiptRecord? { records[proposalID] }
  func record(_ receipt: CookReceiptRecord) { records[receipt.proposalID] = receipt }
}

/// Executor gates: dedupe, hash, TTL, approval derivation, and one execution case per kind.
/// Executor tests run on the main actor: the executor is MainActor-isolated because
/// phone-side execution drives the view model's published state.
@MainActor
final class CookProposalExecutorTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

  private func proposal(
    id: String = "prop_1",
    payload: CookProposalPayload,
    expires: TimeInterval = 300,
    hashOverride: String? = nil
  ) -> CookActionProposal {
    CookActionProposal(
      proposalID: id, createdAt: t0, expiresAt: t0.addingTimeInterval(expires),
      payloadHash: hashOverride ?? CookProposalWire.payloadHash(of: payload)!,
      kind: kind(of: payload), payload: payload, rationale: "test",
      requiredApproval: .explicit)
  }

  private func kind(of payload: CookProposalPayload) -> CookProposalKind {
    switch payload {
    case .timerStart: return .timerStart
    case .timerAdjust: return .timerAdjust
    case .stepAdvance: return .stepAdvance
    case .inventoryCorrection: return .inventoryCorrection
    case .mealLog: return .mealLog
    case .saveNote: return .saveNote
    case .plan: return .plan
    case .swap: return .swap
    case .adaptation: return .adaptation
    }
  }

  private func touchEvent(command: String, revision: Int = 1, source: String = "touch")
    -> CookDeviceEvent
  {
    CookDeviceEvent(id: "evt_1", command: command, source: source, at: t0, revision: revision)
  }

  func testApprovedTimerStartExecutesOnceAndReplayDedupes() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)
    let p = proposal(payload: .timerStart(durationMinutes: 12, label: "Udon broth"))

    let first = executor.process(p, decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(first.state, .executed)
    XCTAssertEqual(target.startedTimers.count, 1)
    XCTAssertEqual(target.startedTimers.first?.seconds, 720)

    let replay = executor.process(p, decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(replay.state, .executed)
    XCTAssertEqual(replay.reason, "already_resolved")
    XCTAssertEqual(target.startedTimers.count, 1, "a replayed proposal must not execute twice")
  }

  func testDedupeResolvesFromASharedLogAcrossExecutorInstances() {
    // A fresh executor over the same (shared) log sees the prior receipt. Cross-restart
    // persistence is covered by CookReviewFixRegressionTests over the real GRDB store.
    let log = InMemoryReceipts()
    let firstExecutor = CookProposalExecutor(receipts: log, target: TestTarget())
    let p = proposal(payload: .stepAdvance(stepIndex: 1))
    _ = firstExecutor.process(p, decision: .approve, deviceEvents: [], now: t0)

    let secondTarget = TestTarget()
    let secondExecutor = CookProposalExecutor(receipts: log, target: secondTarget)
    let replay = secondExecutor.process(p, decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(replay.reason, "already_resolved")
    XCTAssertEqual(secondTarget.stepAdvances, 0)
  }

  func testPayloadHashMismatchRejectsWithoutExecuting() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)
    let p = proposal(
      payload: .timerStart(durationMinutes: 12, label: "Udon broth"),
      hashOverride: "sha256:0000000000000000000000000000000000000000000000000000000000000000")

    let receipt = executor.process(p, decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(receipt.state, .rejected)
    XCTAssertEqual(target.startedTimers.count, 0, "an unverified payload never executes")
  }

  func testExpiredProposalResolvesExpired() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)
    let p = proposal(payload: .timerStart(durationMinutes: 5, label: nil), expires: 300)

    let receipt = executor.process(
      p, decision: .approve, deviceEvents: [], now: t0.addingTimeInterval(301))
    XCTAssertEqual(receipt.state, .expired)
    XCTAssertEqual(target.startedTimers.count, 0)
  }

  func testDismissCancelsWithoutExecuting() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)
    let receipt = executor.process(
      proposal(payload: .timerStart(durationMinutes: 5, label: nil)),
      decision: .dismiss, deviceEvents: [], now: t0)
    XCTAssertEqual(receipt.state, .cancelled)
    XCTAssertEqual(target.startedTimers.count, 0)
  }

  // MARK: Approval derivation (SPEC §4 — the model cannot manufacture approval)

  func testMealLogAlwaysRequiresExplicitApproval() {
    // Even a phone-recorded touch event naming the tool cannot make meal_log device-auto.
    let events = [touchEvent(command: "proposeMealLog")]
    let p = proposal(payload: .mealLog(recipe: nil))
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: TestTarget())
    XCTAssertEqual(executor.requiredApproval(for: p, deviceEvents: events), .explicit)
  }

  func testDeviceAutoRequiresUnconsumedTouchEventNamingSameTool() {
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: TestTarget())
    let timerStart = proposal(payload: .timerStart(durationMinutes: 5, label: nil))
    let timerAdjust = proposal(payload: .timerAdjust(timerId: "t1", newDurationMinutes: 3))

    let valid = [touchEvent(command: "proposeTimerStart", revision: 1)]
    XCTAssertEqual(executor.requiredApproval(for: timerStart, deviceEvents: valid), .deviceAuto)

    // Voice never upgrades.
    let voice = [touchEvent(command: "proposeTimerStart", source: "voice")]
    XCTAssertEqual(executor.requiredApproval(for: timerStart, deviceEvents: voice), .explicit)

    // Different tool never upgrades.
    XCTAssertEqual(executor.requiredApproval(for: timerAdjust, deviceEvents: valid), .explicit)
  }

  func testDeviceAutoRequiresTheEventToCarryTheSnapshotRevision() {
    // The gate revision is the session's current snapshot revision — a stale event cannot
    // start a new action against a kitchen that has moved on (SPEC §4).
    let laterTarget = TestTarget()
    laterTarget.revision = 2
    let laterExecutor = CookProposalExecutor(receipts: InMemoryReceipts(), target: laterTarget)
    let timerStart = proposal(payload: .timerStart(durationMinutes: 5, label: nil))

    XCTAssertEqual(
      laterExecutor.requiredApproval(
        for: timerStart, deviceEvents: [touchEvent(command: "proposeTimerStart", revision: 2)]),
      .deviceAuto)
    XCTAssertEqual(
      laterExecutor.requiredApproval(
        for: timerStart, deviceEvents: [touchEvent(command: "proposeTimerStart", revision: 1)]),
      .explicit, "a stale event never upgrades")
  }

  func testOneDeviceEventStartsExactlyOneAction() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)
    let events = [touchEvent(command: "proposeTimerStart", revision: 1)]

    let first = executor.process(
      proposal(id: "prop_a", payload: .timerStart(durationMinutes: 5, label: nil)),
      decision: .approve, deviceEvents: events, now: t0)
    XCTAssertEqual(first.state, .executed)
    XCTAssertEqual(first.consumedDeviceEventID, "evt_1", "the initiating event is reported")

    let second = executor.process(
      proposal(id: "prop_b", payload: .timerStart(durationMinutes: 8, label: nil)),
      decision: .approve, deviceEvents: events, now: t0)
    XCTAssertNil(second.consumedDeviceEventID, "a consumed event never starts a second action")
    XCTAssertEqual(
      executor.requiredApproval(
        for: proposal(id: "prop_c", payload: .timerStart(durationMinutes: 9, label: nil)),
        deviceEvents: events),
      .explicit)
    XCTAssertEqual(target.startedTimers.count, 2, "both approvals were explicit-consented")
  }

  func testMealLogExecutesOnlyOnExplicitApproval() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)
    let receipt = executor.process(
      proposal(payload: .mealLog(recipe: nil)), decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(receipt.state, .executed)
    XCTAssertEqual(target.mealLogs, 1)
  }

  // MARK: Execution cases

  func testStepAdvanceAndAdjustAndCorrectionAndAdaptationExecute() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)

    // Distinct ids: dedupe is keyed on proposalID, so a reused id would return the prior
    // receipt without executing a second kind.
    XCTAssertEqual(
      executor.process(
        proposal(id: "prop_step", payload: .stepAdvance(stepIndex: 1)), decision: .approve,
        deviceEvents: [], now: t0
      ).state, .executed)
    XCTAssertEqual(
      executor.process(
        proposal(
          id: "prop_adjust",
          payload: .timerAdjust(timerId: "t1", newDurationMinutes: 3)),
        decision: .approve, deviceEvents: [], now: t0
      ).state, .executed)
    XCTAssertEqual(
      executor.process(
        proposal(
          id: "prop_correction",
          payload: .inventoryCorrection(ingredientId: 9, correction: "half used")),
        decision: .approve, deviceEvents: [], now: t0
      ).state, .executed)
    XCTAssertEqual(
      executor.process(
        proposal(id: "prop_adapt", payload: .adaptation(change: "servings", servings: 4)),
        decision: .approve, deviceEvents: [], now: t0
      ).state, .executed)

    XCTAssertEqual(target.stepAdvances, 1)
    XCTAssertEqual(target.adjustedTimers.first?.seconds, 180)
    XCTAssertEqual(target.corrections.first?.correction, "half used")
    XCTAssertEqual(target.adaptations.first?.servings, 4)
  }

  func testSwapExecutedCarriesRecheckJSON() {
    let target = TestTarget()
    target.swapOutcome = (recheckJSON: #"{"blocked":false,"checkedIDs":[]}"#, executed: true)
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)

    let receipt = executor.process(
      proposal(
        payload: .swap(originalIngredientId: 42, substituteIngredientId: 7, role: "required")),
      decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(receipt.state, .executed)
    XCTAssertEqual(receipt.allergenRecheckJSON, #"{"blocked":false,"checkedIDs":[]}"#)
  }

  func testSwapBlockedByRecheckIsRejectedWithAudit() {
    let target = TestTarget()
    target.swapOutcome = (recheckJSON: #"{"blocked":true,"checkedIDs":[]}"#, executed: false)
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)

    let receipt = executor.process(
      proposal(
        payload: .swap(originalIngredientId: 42, substituteIngredientId: 7, role: "required")),
      decision: .approve, deviceEvents: [], now: t0)
    XCTAssertEqual(receipt.state, .rejected, "a blocked re-check must not execute the swap")
    XCTAssertEqual(receipt.reason, "blocked by allergen re-check")
    XCTAssertEqual(receipt.allergenRecheckJSON, #"{"blocked":true,"checkedIDs":[]}"#)
  }

  func testFailedCapabilitiesReject() {
    let target = TestTarget()
    target.timerStartResult = false
    target.mealLogResult = false
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)

    XCTAssertEqual(
      executor.process(
        proposal(id: "p1", payload: .timerStart(durationMinutes: 5, label: nil)),
        decision: .approve, deviceEvents: [], now: t0
      ).state, .rejected)
    XCTAssertEqual(
      executor.process(
        proposal(id: "p2", payload: .mealLog(recipe: nil)), decision: .approve, deviceEvents: [],
        now: t0
      )
      .state, .rejected)
  }

  func testSaveNoteAndPlanResolveExecutedWithoutTargetEffects() {
    let target = TestTarget()
    let executor = CookProposalExecutor(receipts: InMemoryReceipts(), target: target)

    XCTAssertEqual(
      executor.process(
        proposal(payload: .saveNote(prompt: "Salty?", noteSavedMarker: nil)), decision: .approve,
        deviceEvents: [], now: t0
      )
      .state, .executed)
    XCTAssertEqual(
      executor.process(
        proposal(payload: .plan(dinnerCount: 4, constraints: [])), decision: .approve,
        deviceEvents: [], now: t0
      )
      .state, .executed)
    XCTAssertTrue(target.startedTimers.isEmpty && target.mealLogs == 0)
  }
}
