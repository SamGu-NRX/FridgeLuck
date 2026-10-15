import Foundation
import FLFeatureLogic
import GRDB

/// What one drain pass did, for status lines and tests.
public struct OutboxDrainResult: Sendable, Equatable {
  public var sent = 0
  public var retried = 0
  public var conflicts = 0
  public var failed = 0

  public init() {}
}

/// Drains the community outbox: reads due rows from `community_outbox`, sends each through
/// `CommunityAPIClient`, and applies the outcome with the pure rules of
/// `OutboxStateMachine` (SPEC 8.3).
///
/// Local-first: every community write is recorded by `CommunityStore.enqueue` before any
/// network use, and an outbox row is removed only on confirmed success. Retries back off
/// exponentially (1 min → … → 1 h cap). `409` conflicts and permanent `4xx` failures stop
/// the row and surface to the user — nothing auto-resolves.
///
/// The app schedules drains (on launch, foreground, network availability); each call to
/// `drain` is one pass over what is due, so backoff timing stays under the store's control
/// and tests never sleep.
public final class OutboxService: Sendable {
  private let store: CommunityStore
  private let client: CommunityAPIClient
  private let retryPolicy: OutboxRetryPolicy

  public init(
    store: CommunityStore,
    client: CommunityAPIClient,
    retryPolicy: OutboxRetryPolicy = OutboxRetryPolicy()
  ) {
    self.store = store
    self.client = client
    self.retryPolicy = retryPolicy
  }

  /// Sends every due outbox row once. Rows that fail with a retryable outcome are rescheduled
  /// with backoff and stay queued.
  @discardableResult
  public func drain(now: Date = Date()) async -> OutboxDrainResult {
    var result = OutboxDrainResult()
    let items: [OutboxItem]
    do {
      items = try store.dueOutboxItems(now: now)
    } catch {
      return result
    }

    for item in items {
      await self.process(item, now: now, into: &result)
    }
    return result
  }

  private func process(_ item: OutboxItem, now: Date, into result: inout OutboxDrainResult)
    async
  {
    switch item.operation {
    case .publish:
      await processPublish(item, now: now, into: &result)
    case .withdraw:
      await processWithdraw(item, now: now, into: &result)
    case .shareCook, .tableEvent, .report:
      // No server modules for these exist on the wire yet (community-groups slice); leave
      // them queued untouched rather than sending a payload no contract pins.
      break
    }
  }

  private func processPublish(
    _ item: OutboxItem, now: Date, into result: inout OutboxDrainResult
  ) async {
    guard let recipeId = item.recipeId else {
      try? store.markOutboxFailed(id: item.id, error: "publish row has no recipe linkage")
      result.failed += 1
      return
    }
    do {
      let body = try item.decodedPayload(as: CreatePublicationRequest.self)
      let publication = try await client.createPublication(body)
      try store.applyPublication(publication, recipeId: recipeId, now: now)
      try store.removeOutboxItem(id: item.id)
      result.sent += 1
    } catch {
      apply(error: error, to: item, now: now, into: &result)
    }
  }

  private func processWithdraw(
    _ item: OutboxItem, now: Date, into result: inout OutboxDrainResult
  ) async {
    guard let recipeId = item.recipeId else {
      try? store.markOutboxFailed(id: item.id, error: "withdraw row has no recipe linkage")
      result.failed += 1
      return
    }
    do {
      let body = try item.decodedPayload(as: WithdrawPublicationRequest.self)
      _ = try await client.withdrawPublication(body.publicationId)
      try store.markWithdrawn(recipeId: recipeId, now: now)
      try store.removeOutboxItem(id: item.id)
      result.sent += 1
    } catch {
      apply(error: error, to: item, now: now, into: &result)
    }
  }

  private func apply(
    error: Error, to item: OutboxItem, now: Date, into result: inout OutboxDrainResult
  ) {
    let statusCode: Int?
    if let apiError = error as? CommunityAPIError {
      statusCode = apiError.statusCode
    } else {
      // Transport-level failure (offline, timeout): always retryable.
      statusCode = nil
    }
    switch OutboxStateMachine.outcome(statusCode: statusCode) {
    case .succeeded:
      // Unreachable through the catch path; treat as no-op.
      break
    case .conflict:
      try? store.markOutboxConflict(id: item.id, error: String(describing: error))
      result.conflicts += 1
    case .abandoned:
      try? store.markOutboxFailed(id: item.id, error: String(describing: error))
      result.failed += 1
    case .retryWithBackoff:
      let attempts = item.attempts + 1
      let nextRetry = OutboxStateMachine.nextRetry(
        now: now, failedAttempts: attempts, policy: retryPolicy)
      try? store.scheduleOutboxRetry(
        id: item.id, attempts: attempts, nextRetryAt: nextRetry, error: String(describing: error))
      result.retried += 1
    }
  }
}
