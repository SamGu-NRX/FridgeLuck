import FLFeatureLogic
import Foundation

/// The executor's receipt log over the persistent `cook_receipt` table — the dedupe authority
/// across restarts (SPEC §8). The row has no payload-hash column, so the hash and reason ride
/// in `appliedJSON` as canonical JSON; the state is the row's status.
///
/// Receipt rows foreign-key to `cook_session`, so the log reads the live session's id and
/// revision from the provider at record time. A receipt that cannot persist is never silent:
/// a dropped dedupe record would let a replayed proposal execute twice (SPEC §8).
final class CookReceiptLog: CookReceiptReading {
  enum RecordError: Error {
    /// No live session to reference — the receipt would violate the FK, so it is refused
    /// loudly instead of written against an empty id.
    case noActiveSession
  }

  private let store: CookSessionPersisting
  /// The cooking session this proposal executes against — read by the caller while the
  /// proposal executes, so the FK references the session that owns the action.
  private let sessionID: String
  private let sessionRevision: Int
  /// The last write failure, for callers and tests; cleared on a successful write.
  private(set) var lastRecordError: (any Error)?

  init(store: CookSessionPersisting, sessionID: String, sessionRevision: Int) {
    self.store = store
    self.sessionID = sessionID
    self.sessionRevision = sessionRevision
  }

  func receipt(proposalID: String) -> CookReceiptRecord? {
    guard let stored = try? store.receipt(proposalID: proposalID) else { return nil }
    var payloadHash = ""
    var reason: String?
    if let data = stored.appliedJSON?.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      payloadHash = object["payloadHash"] as? String ?? ""
      reason = object["reason"] as? String
    }
    return CookReceiptRecord(
      proposalID: stored.proposalID,
      payloadHash: payloadHash,
      state: CookReceiptState(rawValue: stored.status.rawValue) ?? .rejected,
      recordedAt: stored.decidedAt,
      reason: reason)
  }

  func record(_ receipt: CookReceiptRecord) {
    var audit: [String: Any] = ["payloadHash": receipt.payloadHash]
    if let reason = receipt.reason { audit["reason"] = reason }
    let appliedJSON = (try? JSONSerialization.data(withJSONObject: audit))
      .flatMap { String(data: $0, encoding: .utf8) }

    guard !sessionID.isEmpty else {
      lastRecordError = RecordError.noActiveSession
      assertionFailure(
        "cook receipt dropped — no active session to reference; dedupe would be inert")
      return
    }
    do {
      try store.record(
        receipt: CookStoredReceipt(
          proposalID: receipt.proposalID,
          sessionID: sessionID,
          status: CookStoredReceipt.Status(rawValue: receipt.state.rawValue) ?? .rejected,
          decidedAt: receipt.recordedAt,
          decidedBy: "phone",
          appliedJSON: appliedJSON,
          failure: receipt.reason,
          sessionRevision: sessionRevision))
      lastRecordError = nil
    } catch {
      lastRecordError = error
      assertionFailure("cook receipt write failed: \(error)")
    }
  }
}

/// The fallback receipt log when no persistence store is wired — session lifetime only. Dedupe
/// works within the process; across restarts there is nothing to dedupe against.
final class InMemoryCookReceiptFallback: CookReceiptReading, @unchecked Sendable {
  static let shared = InMemoryCookReceiptFallback()

  private let lock = NSLock()
  private var records: [String: CookReceiptRecord] = [:]

  func receipt(proposalID: String) -> CookReceiptRecord? {
    lock.lock()
    defer { lock.unlock() }
    return records[proposalID]
  }

  func record(_ receipt: CookReceiptRecord) {
    lock.lock()
    defer { lock.unlock() }
    records[receipt.proposalID] = receipt
  }
}
