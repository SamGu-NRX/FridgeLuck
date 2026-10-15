import FLFeatureLogic
import Foundation

/// The executor's receipt log over the persistent `cook_receipt` table — the dedupe authority
/// across restarts (SPEC §8). The row has no payload-hash column, so the hash and reason ride
/// in `appliedJSON` as canonical JSON; the state is the row's status.
final class CookReceiptLog: CookReceiptReading {
  private let store: CookSessionPersisting

  init(store: CookSessionPersisting) {
    self.store = store
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

    try? store.record(
      receipt: CookStoredReceipt(
        proposalID: receipt.proposalID,
        sessionID: "",
        status: CookStoredReceipt.Status(rawValue: receipt.state.rawValue) ?? .rejected,
        decidedAt: receipt.recordedAt,
        decidedBy: "phone",
        appliedJSON: appliedJSON,
        failure: receipt.reason,
        sessionRevision: 0))
  }
}

/// The fallback receipt log when no persistence store is wired — session lifetime only. Dedupe
/// works within the process; across restarts there is nothing to dedupe against.
final class InMemoryCookReceiptFallback: CookReceiptReading {
  static let shared = InMemoryCookReceiptFallback()

  private var records: [String: CookReceiptRecord] = [:]

  func receipt(proposalID: String) -> CookReceiptRecord? {
    records[proposalID]
  }

  func record(_ receipt: CookReceiptRecord) {
    records[receipt.proposalID] = receipt
  }
}
