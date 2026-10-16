import Foundation

/// What a community outbox row carries: one pending server write (SPEC 8.3). Every operation
/// has a client-generated `operationId` (UUID) so the server deduplicates replays of the
/// same write — a retried publish never becomes a duplicate publication.
public enum OutboxOperationKind: String, Codable, Sendable, CaseIterable {
  case publish
  case withdraw
  case shareCook = "share_cook"
  case tableEvent = "table_event"
  case report
}

/// Lifecycle of an outbox row. `queued` → `sending` → removed-on-success; failures land in
/// `queued` again (with `next_retry_at`), `conflict`, `failed` or `cancelled`.
public enum OutboxItemState: String, Codable, Sendable, CaseIterable {
  case queued
  case sending
  case succeeded
  case cancelled
  case conflict
  case failed
}

/// Retry/backoff parameters: exponential 1 min → 2 → 4 → … capped at 1 h (SPEC 8.3).
public struct OutboxRetryPolicy: Sendable, Equatable {
  /// Delay before the first retry, in seconds.
  public var initialDelay: TimeInterval
  /// Upper bound on any single retry delay, in seconds.
  public var maxDelay: TimeInterval

  public init(initialDelay: TimeInterval = 60, maxDelay: TimeInterval = 3600) {
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
  }

  /// Delay before the next attempt, given how many attempts have already failed
  /// (`failedAttempts >= 1`). 1 failed attempt → 1 min, 2 → 2 min, 3 → 4 min … capped.
  public func delay(afterFailedAttempts failedAttempts: Int) -> TimeInterval {
    let exponent = max(0, failedAttempts - 1)
    let base = initialDelay * pow(2, Double(exponent))
    return min(base, maxDelay)
  }
}

/// The verdict on one send attempt: what the drain loop should do with the row.
public enum OutboxSendOutcome: Sendable, Equatable {
  /// Confirmed success — the row is removed (rows are removed only on confirmed success).
  case succeeded
  /// Server or transport failure — schedule the next retry with backoff.
  case retryWithBackoff
  /// `409`: the server refused because reality moved on (e.g. `recipe_revised_offline`).
  /// Surfaces to the user; never auto-resolves and never retries.
  case conflict
  /// A permanent `4xx` (validation, rights refused): retrying cannot help; the row stops
  /// and the failure surfaces.
  case abandoned
}

/// Pure rules for the outbox drain loop, so the retry behaviour is table-testable without
/// any database or transport.
public enum OutboxStateMachine {
  /// Classifies one send attempt by its HTTP status. `nil` means a transport-level failure
  /// (offline, DNS, timeout) — always retryable.
  public static func outcome(statusCode: Int?) -> OutboxSendOutcome {
    guard let statusCode else { return .retryWithBackoff }
    switch statusCode {
    case 200...299:
      return .succeeded
    case 409:
      return .conflict
    case 500...599, 429:
      return .retryWithBackoff
    default:
      // Other 4xx: the request itself is wrong (422 rights refused, 400 malformed…).
      // Retrying cannot help and would spam resubmissions (SPEC 6.5).
      return .abandoned
    }
  }

  /// `next_retry_at` for a row whose send just failed. `failedAttempts` counts attempts
  /// already made, including the one that just failed (>= 1).
  public static func nextRetry(
    now: Date,
    failedAttempts: Int,
    policy: OutboxRetryPolicy
  ) -> Date {
    now.addingTimeInterval(policy.delay(afterFailedAttempts: failedAttempts))
  }
}
