import Foundation

/// What the executor drives. The app wires these to `CookModeViewModel`; tests wire fakes.
/// Every operation is phrased as a phone capability — the executor never mutates session state
/// itself (SPEC §4: the model proposes, the phone executes).
///
/// Main-actor-isolated: execution mutates the view model's published state, and every entry
/// point (view model, tests) is already on the main actor, so the isolation states the real
/// invariant instead of hoping.
@MainActor
public protocol CookProposalExecuting: AnyObject {
  /// The cook session's current revision, echoed on every receipt.
  var snapshotRevision: Int { get }
  /// Creates a timer; false when the store refuses (non-positive, duplicate id).
  func executeTimerStart(seconds: Int, label: String) -> Bool
  /// Adjusts a running timer; false when the timer is unknown or paused.
  func executeTimerAdjust(timerId: String, newDurationSeconds: Int) -> Bool
  /// Marks the current step done and moves on; false when cooking is not active.
  func executeStepAdvance() -> Bool
  /// Applies the swap after the allergen re-check. Returns the re-check's canonical JSON and
  /// whether it executed. Unknown composition blocks (fail closed, SPEC §7).
  func executeSwap(originalIngredientId: Int64, substituteIngredientId: Int64) -> (
    recheckJSON: String, executed: Bool
  )?
  /// Applies the adaptation; false when the session cannot adapt.
  func executeAdaptation(change: String, servings: Int?) -> Bool
  /// Writes the meal log — reachable only through explicit approval (SPEC §4).
  func executeMealLog() -> Bool
  /// Corrects a pantry line's stated quantity/state. Returns false when the line is unknown.
  func executeInventoryCorrection(ingredientId: Int64, correction: String) -> Bool
}

/// One stored receipt as the executor's log sees it. The app adapts this to the persistence
/// layer's row; tests use an in-memory log.
public struct CookReceiptRecord: Equatable, Sendable {
  public let proposalID: String
  public let payloadHash: String
  public let state: CookReceiptState
  public let recordedAt: Date
  public let reason: String?

  public init(
    proposalID: String, payloadHash: String, state: CookReceiptState,
    recordedAt: Date, reason: String? = nil
  ) {
    self.proposalID = proposalID
    self.payloadHash = payloadHash
    self.state = state
    self.recordedAt = recordedAt
    self.reason = reason
  }
}

/// Read/write access to the receipt log — the dedupe authority across restarts (SPEC §8).
public protocol CookReceiptReading: AnyObject {
  func receipt(proposalID: String) -> CookReceiptRecord?
  func record(_ receipt: CookReceiptRecord)
}

/// Executes approved proposals and returns receipts (SPEC §8).
///
/// The gates, in the order PR #102's runtime dispatch pins:
/// 1. **Dedupe**: a proposalID already in the receipt log resolves as the original receipt with
///    `already_resolved` — the persistent log is the authority, not any in-memory map.
/// 2. **Payload hash**: a recomputed hash that differs from the envelope's is `rejected` —
///    the phone executes only the payload it verified.
/// 3. **Revision binding**: enforced where the wire carries a session-revision field — the
///    pinned wire carries none for any kind, so the gate passes (see `boundRevision`). An
///    older revision, where one is ever present, is `superseded`.
/// 4. **TTL**: an expired proposal resolves `expired` — checked at approval time.
/// 5. **Approval**: `requiredApproval` is derived here, never trusted from the wire.
///    meal_log is always explicit; device-auto requires a phone-recorded, unconsumed
///    DeviceEvent at the bound revision naming the same tool (one event, one action).
/// Phone-side execution happens on the main thread — it drives the view model's published
/// state — so the whole executor is MainActor-isolated (see `CookProposalExecuting`).
@MainActor
public final class CookProposalExecutor {
  private let receipts: CookReceiptReading
  private let target: CookProposalExecuting
  /// Device events this executor has already used to start one action each (SPEC §4). A
  /// consumed event id never upgrades a later proposal.
  private var consumedDeviceEventIDs = Set<String>()

  public init(receipts: CookReceiptReading, target: CookProposalExecuting) {
    self.receipts = receipts
    self.target = target
  }

  /// A user's decision on a proposal. `approve` executes (at most once); `dismiss` records
  /// cancellation without executing anything. `approve` on an `explicit` proposal means the
  /// user's approval card was accepted — the surface owns the card; the executor owns the rules
  /// for which proposals may run without one (`requiredApproval(for:deviceEvents:)`).
  public enum Decision {
    case approve
    case dismiss
  }

  /// Effective approval for a proposal, derived phone-side. Wire values are audit only. A
  /// timer proposal upgrades to device-auto only via a phone-recorded, unconsumed event
  /// naming the same tool at the gate's revision.
  public func requiredApproval(
    for proposal: CookActionProposal, deviceEvents: [CookDeviceEvent]
  ) -> CookRequiredApproval {
    matchingDeviceEvent(for: proposal, in: deviceEvents) == nil ? .explicit : .deviceAuto
  }

  /// The unconsumed touch event that initiates this proposal, or nil. The gate revision is the
  /// wire's bound revision when one arrives; the pinned wire carries none, so the event must
  /// carry the session's current snapshot revision — a stale event cannot start a new action
  /// against a kitchen that has moved on (SPEC §4).
  private func matchingDeviceEvent(
    for proposal: CookActionProposal, in deviceEvents: [CookDeviceEvent]
  ) -> CookDeviceEvent? {
    guard proposal.kind == .timerStart || proposal.kind == .timerAdjust else { return nil }
    let tool = proposal.kind == .timerStart ? "proposeTimerStart" : "proposeTimerAdjust"
    let gateRevision = proposal.boundRevision ?? target.snapshotRevision
    return deviceEvents.first { event in
      event.command == tool && event.source == "touch" && event.revision == gateRevision
        && !consumedDeviceEventIDs.contains(event.id)
    }
  }

  /// Processes a proposal and returns the receipt. Never throws — every failure path is a
  /// receipt state (SPEC §8), so the backend always gets an answer.
  @discardableResult
  public func process(
    _ proposal: CookActionProposal, decision: Decision, deviceEvents: [CookDeviceEvent],
    now: Date
  ) -> CookActionReceipt {
    // 1. Dedupe — the original receipt is the truth; `already_resolved` explains the repeat.
    if let prior = receipts.receipt(proposalID: proposal.proposalID) {
      return CookActionReceipt(
        proposalID: prior.proposalID, payloadHash: prior.payloadHash,
        snapshotRevision: target.snapshotRevision, state: prior.state,
        recordedAt: prior.recordedAt, reason: "already_resolved")
    }

    // 2. Payload hash — reject on mismatch, never execute a payload the user didn't see.
    guard let recomputed = CookProposalWire.payloadHash(of: proposal.payload),
      recomputed == proposal.payloadHash
    else {
      let receipt = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: proposal.payloadHash,
        snapshotRevision: target.snapshotRevision, state: .rejected,
        recordedAt: now, reason: "payload hash mismatch")
      record(receipt)
      return receipt
    }

    // 3. Revision binding — where the wire carries a revision, an older proposal is superseded.
    if let bound = proposal.boundRevision, bound != target.snapshotRevision {
      let receipt = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: recomputed,
        snapshotRevision: target.snapshotRevision, state: .rejected,
        recordedAt: now, reason: "superseded")
      record(receipt)
      return receipt
    }

    // 4. TTL — checked at approval time.
    if now > proposal.expiresAt {
      let receipt = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: recomputed,
        snapshotRevision: target.snapshotRevision, state: .expired, recordedAt: now)
      record(receipt)
      return receipt
    }

    // 5. Approval — derived here, never trusted from the wire.
    let required = requiredApproval(for: proposal, deviceEvents: deviceEvents)
    if decision == .dismiss {
      let receipt = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: recomputed,
        snapshotRevision: target.snapshotRevision, state: .cancelled, recordedAt: now)
      record(receipt)
      return receipt
    }

    // One device event starts one action (SPEC §4): consume the initiating event, report it
    // on the receipt so the caller drops it from its store, and never let it upgrade a
    // later proposal.
    let consumedDeviceEventID =
      required == .deviceAuto
      ? matchingDeviceEvent(for: proposal, in: deviceEvents)?.id : nil
    if let id = consumedDeviceEventID { consumedDeviceEventIDs.insert(id) }

    // `.approve` proceeds for both policies: explicit passed the user's tap; device-auto
    // passed the phone's own rule.

    return execute(
      proposal, payloadHash: recomputed, now: now, consumedDeviceEventID: consumedDeviceEventID)
  }

  // MARK: Execution — one case per proposal kind, receipt per outcome

  private func execute(
    _ proposal: CookActionProposal, payloadHash: String, now: Date,
    consumedDeviceEventID: String?
  ) -> CookActionReceipt {
    func receipt(
      _ state: CookReceiptState, reason: String? = nil, recheck: String? = nil
    ) -> CookActionReceipt {
      let r = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: payloadHash,
        snapshotRevision: target.snapshotRevision, state: state, recordedAt: now,
        reason: reason, allergenRecheckJSON: recheck,
        consumedDeviceEventID: consumedDeviceEventID)
      record(r)
      return r
    }

    switch proposal.payload {
    case .timerStart(let durationMinutes, let label):
      let seconds = Int(durationMinutes * 60)
      guard seconds > 0, target.executeTimerStart(seconds: seconds, label: label ?? "Timer") else {
        return receipt(.rejected, reason: "timer not accepted")
      }
      return receipt(.executed)

    case .timerAdjust(let timerId, let newDurationMinutes):
      guard let minutes = newDurationMinutes, minutes > 0,
        target.executeTimerAdjust(timerId: timerId, newDurationSeconds: Int(minutes * 60))
      else { return receipt(.rejected, reason: "timer not adjustable") }
      return receipt(.executed)

    case .stepAdvance:
      guard target.executeStepAdvance() else { return receipt(.rejected, reason: "no active step") }
      return receipt(.executed)

    case .mealLog:
      // Execution here happens only after the explicit-approval gate above passed.
      guard target.executeMealLog() else { return receipt(.rejected, reason: "meal log failed") }
      return receipt(.executed)

    case .swap(let originalIngredientId, let substituteIngredientId, _):
      guard
        let outcome = target.executeSwap(
          originalIngredientId: originalIngredientId,
          substituteIngredientId: substituteIngredientId)
      else { return receipt(.rejected, reason: "substitution unavailable") }
      if outcome.executed {
        return receipt(.executed, recheck: outcome.recheckJSON)
      }
      return receipt(
        .rejected, reason: "blocked by allergen re-check", recheck: outcome.recheckJSON)

    case .adaptation(let change, let servings):
      guard target.executeAdaptation(change: change, servings: servings) else {
        return receipt(.rejected, reason: "adaptation not applied")
      }
      return receipt(.executed)

    case .inventoryCorrection(let ingredientId, let correction):
      guard target.executeInventoryCorrection(ingredientId: ingredientId, correction: correction)
      else { return receipt(.rejected, reason: "pantry line unknown") }
      return receipt(.executed)

    case .saveNote:
      // Notes are surface actions; a proposal can only prompt the surface (SPEC §7).
      return receipt(.executed)
    case .plan:
      // The plan card renders; dinner planning runs from the surface, not the proposal.
      return receipt(.executed)
    }
  }

  private func record(_ receipt: CookActionReceipt) {
    receipts.record(
      CookReceiptRecord(
        proposalID: receipt.proposalID, payloadHash: receipt.payloadHash,
        state: receipt.state, recordedAt: receipt.recordedAt, reason: receipt.reason))
  }
}

extension CookActionProposal {
  /// The revision the proposal is bound to, where the wire carries one. The pinned wire has no
  /// session-revision field for any kind, so this returns nil and the gate passes; recipe
  /// identity is shown on the approval card, not enforced from the wire. If a future wire adds
  /// a session-revision field, bind it here and the gate applies unchanged.
  var boundRevision: Int? {
    switch payload {
    case .mealLog(let recipe):
      // A recipe ref's revision is the recipe's, not the session's — comparing it against the
      // session revision would reject nearly every meal-log proposal. Not a session binding.
      return nil
    default:
      return nil
    }
  }
}
