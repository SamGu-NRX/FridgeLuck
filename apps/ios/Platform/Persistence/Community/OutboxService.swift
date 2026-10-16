import FLFeatureLogic
import Foundation
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
    case .shareCook:
      await processShareCook(item, now: now, into: &result)
    case .tableEvent:
      await processTableEvent(item, now: now, into: &result)
    case .report:
      await processReport(item, now: now, into: &result)
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

  // MARK: - Table and safety sends (community SPEC 5, 6.3, 6.4, 8.3)

  /// Payload of a `shareCook` outbox row.
  public struct ShareCookOutboxPayload: Codable, Sendable, Equatable {
    public var tableId: String
    public var request: CommunityShareCookRequest

    public init(tableId: String, request: CommunityShareCookRequest) {
      self.tableId = tableId
      self.request = request
    }
  }

  /// The table lifecycle writes that ride the outbox with a stable order and retry
  /// semantics (SPEC 8.3). Responses the VM needs (createTable, joinTable) are also read
  /// synchronously elsewhere; these rows exist so nothing is lost when offline.
  public enum CommunityTableEventKind: String, Codable, Sendable, CaseIterable {
    case createTable
    case joinByCode = "join_by_code"
    case approveInvite
    case revokeInvite
    case leaveTable
    case blockAccount
    case unblockAccount
  }

  /// Payload of a `tableEvent` outbox row; only the fields the event needs are set.
  public struct TableEventOutboxPayload: Codable, Sendable, Equatable {
    public var event: CommunityTableEventKind
    public var tableId: String?
    public var inviteId: String?
    public var accountId: String?
    public var code: String?
    public var name: String?

    public init(
      event: CommunityTableEventKind, tableId: String? = nil, inviteId: String? = nil,
      accountId: String? = nil, code: String? = nil, name: String? = nil
    ) {
      self.event = event
      self.tableId = tableId
      self.inviteId = inviteId
      self.accountId = accountId
      self.code = code
      self.name = name
    }

    enum CodingKeys: String, CodingKey {
      case event, tableId, inviteId, accountId, code, name
    }
  }

  /// Payload of a `report` outbox row.
  public struct ReportOutboxPayload: Codable, Sendable, Equatable {
    public var request: CommunityCreateReportRequest

    public init(request: CommunityCreateReportRequest) {
      self.request = request
    }
  }

  /// Sends a shared cook to its Table and merges the server-rendered card into the local
  /// feed cache (the author's own card appears with `isMine` set, SPEC 5.2).
  private func processShareCook(
    _ item: OutboxItem, now: Date, into result: inout OutboxDrainResult
  ) async {
    do {
      let payload = try item.decodedPayload(as: ShareCookOutboxPayload.self)
      let card = try await client.shareCookToTable(tableId: payload.tableId, payload.request)
      // Merge into the cached feed when one exists; a fresh fetch replaces it wholesale.
      if let cache = try? store.cachedTable(tableId: payload.tableId),
        !cache.cards.contains(where: { $0.cardId == card.cardId })
      {
        try? store.cacheTable(
          table: cache.table, cards: cache.cards + [card], tableId: payload.tableId, now: now)
      }
      try store.removeOutboxItem(id: item.id)
      result.sent += 1
    } catch {
      apply(error: error, to: item, now: now, into: &result)
    }
  }

  /// Sends one table lifecycle event (approve, revoke, leave, block, unblock, join).
  private func processTableEvent(
    _ item: OutboxItem, now: Date, into result: inout OutboxDrainResult
  ) async {
    do {
      let payload = try item.decodedPayload(as: TableEventOutboxPayload.self)
      switch payload.event {
      case .createTable:
        guard let name = payload.name else {
          try? store.markOutboxFailed(id: item.id, error: "createTable row has no name")
          result.failed += 1
          return
        }
        let table = try await client.createTable(CommunityCreateTableRequest(name: name))
        try? store.setActiveTable(tableId: table.tableId, now: now)
      case .joinByCode:
        guard let code = payload.code else {
          try? store.markOutboxFailed(id: item.id, error: "join row has no code")
          result.failed += 1
          return
        }
        let join = try await client.joinTable(code: code)
        try? store.setActiveTable(tableId: join.tableId, now: now)
      case .approveInvite:
        guard let tableId = payload.tableId, let inviteId = payload.inviteId else {
          try? store.markOutboxFailed(id: item.id, error: "approve row has no table or invite")
          result.failed += 1
          return
        }
        _ = try await client.approveInvite(tableId: tableId, inviteId: inviteId)
      case .revokeInvite:
        guard let tableId = payload.tableId, let inviteId = payload.inviteId else {
          try? store.markOutboxFailed(id: item.id, error: "revoke row has no table or invite")
          result.failed += 1
          return
        }
        try await client.revokeInvite(tableId: tableId, inviteId: inviteId)
      case .leaveTable:
        guard let tableId = payload.tableId else {
          try? store.markOutboxFailed(id: item.id, error: "leave row has no table")
          result.failed += 1
          return
        }
        try await client.leaveTable(tableId: tableId)
        // Past cards stay server-side, redacted for others; locally the feed goes (§5.1).
        try? store.clearTableCache(tableId: tableId)
        try? store.clearActiveTable()
      case .blockAccount:
        guard let accountId = payload.accountId else {
          try? store.markOutboxFailed(id: item.id, error: "block row has no account")
          result.failed += 1
          return
        }
        try await client.addBlock(accountId: accountId)
      case .unblockAccount:
        guard let accountId = payload.accountId else {
          try? store.markOutboxFailed(id: item.id, error: "unblock row has no account")
          result.failed += 1
          return
        }
        try await client.removeBlock(accountId: accountId)
      }
      try store.removeOutboxItem(id: item.id)
      result.sent += 1
    } catch {
      apply(error: error, to: item, now: now, into: &result)
    }
  }

  /// Sends a report (202 accepted — the case queues server-side, SPEC 6.4).
  private func processReport(
    _ item: OutboxItem, now: Date, into result: inout OutboxDrainResult
  ) async {
    do {
      let payload = try item.decodedPayload(as: ReportOutboxPayload.self)
      try await client.createReport(payload.request)
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
