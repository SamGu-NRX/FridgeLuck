import Foundation

/// The cook's device state the executor acts on — a walk kitchen, not the real
/// CookModeViewModel (whose screens and stores are other waves' paths). It
/// implements the same `CookProposalExecuting` seam production wires to, with
/// the semantics the cook-mode executor relies on mirrored here:
/// timers only while cooking, step advance ends the session after the last
/// step, and the allergen re-check fails closed.
@MainActor
final class WalkKitchen: CookProposalExecuting {
  private(set) var snapshotRevision = 7
  private(set) var phase: String = "cooking" // "cooking" | "done"
  private(set) var currentStepIndex = 2
  let stepCount = 5
  private(set) var timers: [(id: String, seconds: Int, label: String)] = []
  private(set) var substitutionsApplied: [(original: Int64, substitute: Int64)] = []
  private(set) var substitutionsBlocked: [(original: Int64, substitute: Int64)] = []

  /// The walk's substitution table: butter (2) → soy sauce (9001).
  let substitutionTable: [Int64: Set<Int64>] = [2: [9001, 9002]]

  /// The cook finished the recipe on the device between turns; the phone
  /// re-sends its bounded snapshot so the gateway's reads answer from the
  /// phone's own state.
  func finishRecipeOnDevice(snapshotRevision revision: Int) {
    while phase == "cooking" {
      if currentStepIndex + 1 < stepCount {
        currentStepIndex += 1
      } else {
        phase = "done"
      }
    }
    snapshotRevision = revision
  }

  func executeTimerStart(seconds: Int, label: String) -> Bool {
    guard phase == "cooking", seconds > 0 else { return false }
    timers.append(("walk-timer-\(timers.count + 1)", seconds, label))
    return true
  }

  func executeTimerAdjust(timerId: String, newDurationSeconds: Int) -> Bool { false }

  func executeStepAdvance() -> Bool {
    guard phase == "cooking" else { return false }
    if currentStepIndex + 1 < stepCount {
      currentStepIndex += 1
    } else {
      phase = "done"
    }
    return true
  }

  /// The allergen re-check, injected at the seam this wave owns (LeChef §7).
  /// The reviewed facts — soy sauce contains wheat, olive oil does not — give
  /// Ana one refused swap and one allowed one: the refused receipt carries the
  /// contract's unsupported recheck naming the blocked path, the allowed one
  /// the verified recheck with a null blocked path. The recheck object uses
  /// the wire contract's shape (receipt.schema.json's allergenRecheck:
  /// verdict | eaters | blockedPath), the phone's canonical JSON form.
  func executeSwap(originalIngredientId: Int64, substituteIngredientId: Int64) -> (
    recheckJSON: String, executed: Bool
  )? {
    guard let substitutes = substitutionTable[originalIngredientId],
      substitutes.contains(substituteIngredientId)
    else {
      return nil // unknown substitution — the executor refuses it
    }
    if substituteIngredientId == 9001 {
      // The reviewed fact: soy sauce carries wheat — hard-blocks for Ana.
      let recheck =
        "{\"verdict\":\"unsupported\",\"eaters\":[\"Ana\"],\"blockedPath\":\"Contains wheat via soy sauce\"}"
      substitutionsBlocked.append((originalIngredientId, substituteIngredientId))
      return (recheck, false)
    }
    let recheck = "{\"verdict\":\"verified\",\"eaters\":[\"Ana\"],\"blockedPath\":null}"
    substitutionsApplied.append((originalIngredientId, substituteIngredientId))
    return (recheck, true)
  }

  func executeAdaptation(change: String, servings: Int?) -> Bool { false }
  func executeMealLog() -> Bool { false }
  func executeInventoryCorrection(ingredientId: Int64, correction: String) -> Bool { false }
}

/// The executor's receipt log, in memory — same seam production backs with GRDB.
/// Not actor-isolated: the executor runs on the main actor, and the lock keeps
/// the non-isolated `CookReceiptReading` conformance honest.
final class WalkReceiptLog: CookReceiptReading {
  private let lock = NSLock()
  private var receipts: [String: CookReceiptRecord] = [:]

  func receipt(proposalID: String) -> CookReceiptRecord? {
    lock.lock()
    defer { lock.unlock() }
    return receipts[proposalID]
  }

  func record(_ receipt: CookReceiptRecord) {
    lock.lock()
    receipts[receipt.proposalID] = receipt
    lock.unlock()
  }
}

/// The bounded snapshots and the camera frame the walk sends. Field shapes
/// mirror backend/gemini-agent/src/lechef/e2e/script.ts.
enum WalkSnapshots {
  static let turnTimer = "start a three minute timer for the noodles"
  static let turnSwap = "I am out of butter — what can I use instead?"
  static let turnSwapOK = "olive oil instead of butter then"
  static let turnStaleStep = "move to the next step"

  static func boundedSnapshot(state: String, stepIndex: Int, revision: Int) -> [String: Any] {
    [
      "revision": revision,
      "pantrySnapshot": [
        "revision": revision,
        "items": [
          [
            "ingredientId": "chicken-breast",
            "name": "chicken breast",
            "state": "sufficient",
            "source": "scan",
            "quantity": ["kind": "known", "value": 600, "unit": "g"],
          ],
          [
            "ingredientId": "butter",
            "name": "butter",
            "state": "short",
            "source": "scan",
            "quantity": ["kind": "known", "value": 20, "unit": "g"],
            "shortBy": 30,
          ],
        ],
      ],
      "cookSession": [
        "state": state,
        "currentStepIndex": stepIndex,
        "eaters": [["name": "Ana", "restrictions": ["wheat"]]],
        "activeTimers": [Any](),
        "cameraMode": "push-to-look",
      ],
      "recipes": [Any](),
    ]
  }

  /// A 1×1 JPEG — the walk's shutter tap. The gateway stores bytes only in the
  /// in-process cache and only metadata in the session store.
  static let oneByOneJPEG: Data = Data(
    base64Encoded:
      "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwcJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="
  )!
}
