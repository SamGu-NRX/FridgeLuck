import Foundation

/// What the executor drives. The app wires these to `CookModeViewModel`; tests wire fakes.
/// Every operation is phrased as a phone capability — the executor never mutates session state
/// itself (SPEC §4: the model proposes, the phone executes).
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
  func executeSwap(originalIngredientId: Int64, substituteIngredientId: Int64) -> (recheckJSON: String, executed: Bool)?
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
/// 3. **Revision binding**: enforced where the pinned wire carries a revision (recipe-bound
///    payloads bind on the ref's revision); an older one is `superseded`. Kinds whose payload
///    carries no revision cannot be revision-checked from the wire and pass this gate.
/// 4. **TTL**: an expired proposal resolves `expired` — checked at approval time.
/// 5. **Approval**: `requiredApproval` is derived here, never trusted from the wire.
///    meal_log is always explicit; device-auto requires a phone-recorded, unconsumed
///    DeviceEvent at the bound revision naming the same tool (one event, one action).
public final class CookProposalExecutor {
  private let receipts: CookReceiptReading
  private let target: CookProposalExecuting

  public init(receipts: CookReceiptReading, target: CookProposalExecuting) {
    self.receipts = receipts
    self.target = target
  }

  /// A user's decision on a proposal. `approve` executes (at most once); `dismiss` records
  /// cancellation without executing anything.
  public enum Decision {
    case approve
    case dismiss
  }

  /// Effective approval for a proposal, derived phone-side. Wire values are audit only.
  public static func requiredApproval(
    for proposal: CookActionProposal, deviceEvents: [CookDeviceEvent]
  ) -> CookRequiredApproval {
    switch proposal.kind {
    case .mealLog:
      return .explicit
    case .timerStart, .timerAdjust:
      // device-auto only via a phone-recorded, unconsumed event at the bound revision naming
      // the same tool. One event initiates one action, then it is consumed.
      let tool = proposal.kind == .timerStart ? "proposeTimerStart" : "proposeTimerAdjust"
      let initiated = deviceEvents.contains { event in
        event.command == tool && event.revision == proposal.boundRevision
          && event.source == "touch"
      }
      return initiated ? .deviceAuto : .explicit
    default:
      return .explicit
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
    let required = Self.requiredApproval(for: proposal, deviceEvents: deviceEvents)
    if decision == .dismiss {
      let receipt = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: recomputed,
        snapshotRevision: target.snapshotRevision, state: .cancelled, recordedAt: now)
      record(receipt)
      return receipt
    }
    // `.approve` proceeds for both policies: explicit passed the user's tap; device-auto
    // passed the phone's own rule.

    return execute(proposal, payloadHash: recomputed, now: now)
  }

  // MARK: Execution — one case per proposal kind, receipt per outcome

  private func execute(_ proposal: CookActionProposal, payloadHash: String, now: Date) -> CookActionReceipt {
    func receipt(_ state: CookReceiptState, reason: String? = nil, recheck: String? = nil) -> CookActionReceipt {
      let r = CookActionReceipt(
        proposalID: proposal.proposalID, payloadHash: payloadHash,
        snapshotRevision: target.snapshotRevision, state: state, recordedAt: now,
        reason: reason, allergenRecheckJSON: recheck)
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
      guard let outcome = target.executeSwap(
        originalIngredientId: originalIngredientId,
        substituteIngredientId: substituteIngredientId)
      else { return receipt(.rejected, reason: "substitution unavailable") }
      if outcome.executed {
        return receipt(.executed, recheck: outcome.recheckJSON)
      }
      return receipt(.rejected, reason: "blocked by allergen re-check", recheck: outcome.recheckJSON)

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
  /// The revision the proposal is bound to, where the pinned wire carries one: the recipe
  /// ref's revision for recipe-bound kinds. Payloads without a revision cannot be
  /// revision-checked from the wire and return nil (the gate passes).
  var boundRevision: Int? {
    switch payload {
    case .mealLog(let recipe):
      return recipe?.revision
    default:
      return nil
    }
  }
}
