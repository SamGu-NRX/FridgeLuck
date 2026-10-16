import Foundation
import Observation

/// State machine for the Tables surface (community SPEC 5, §9.6, §9.7). States are the mock
/// screens, not a generic list: no table, asking to join, owner alone, active, offline with
/// the cached feed, or failed. Writes ride the outbox (`OutboxService`); reads are direct
/// with the `community_table_cache` fallback (SPEC 8.4).
// @Observable (Observation), not Combine: this type also compiles into the Linux
// community-check mirror (SPEC 8.5).
@MainActor
@Observable
public final class TablesViewModel {
  public enum State: Equatable {
    case idle
    case loading
    /// "Tables are small on purpose: 2 to 8 people who cook." (§9.6)
    case noTable
    /// "Asking Flat 4B…" — the 202 pending state until the owner approves (§9.6)
    case askingToJoin(tableName: String)
    /// "Invite someone. Tables work from 2." (§5.1)
    case alone(tableName: String)
    case active(CommunityTable, [CommunityTableCard])
    /// "As of 18:40" — cached feed when the network is down (§9.7)
    case offline(tableName: String, cards: [CommunityTableCard], asOf: Date)
    case failed(message: String)
  }

  public enum Failure: Equatable {
    /// "Tables are 2–8 people. Someone has to leave first." (§9.6)
    case tableFull
    /// "Sharing is 18+." (SPEC 6.2)
    case notAdult
    /// The note ran the personal-data screen (SPEC 6.5).
    case personalData
    case message(String)
  }

  public private(set) var state: State = .idle
  public var failure: Failure?
  /// "There is a conflict in your table" — a blocked member shares the table (§5.1).
  public private(set) var conflictHint: Bool = false
  /// The minted invite; its joinCode is shown exactly once and never again (§5.1).
  public private(set) var mintedInvite: CommunityTableInvite?
  /// Rows still queued (share writes ride the outbox; "Will send when you're online").
  public private(set) var queuedWrites: Int = 0

  /// Account ids this account has blocked (§6.3) — the surface shows Unblock for these.
  public private(set) var blockedAccountIds: Set<String> = []

  private let client: CommunityAPIClient
  private let store: CommunityStore
  private let outbox: OutboxService
  private let session: SessionViewModel
  private var tableId: String?

  public init(
    client: CommunityAPIClient, store: CommunityStore, session: SessionViewModel
  ) {
    self.client = client
    self.store = store
    self.session = session
    self.outbox = OutboxService(store: store, client: client)
  }

  // MARK: - Loading

  public func load() async {
    state = .loading
    guard let tableId = activeTableId() else {
      self.tableId = nil
      state = .noTable
      return
    }
    self.tableId = tableId
    do {
      let table = try await client.getTable(tableId)
      let cards = try await client.tableCards(tableId: tableId)
      try? store.cacheTable(table: table, cards: cards, tableId: tableId)
      await refreshBlocks(table: table)
      state = table.isOwnerAlone ? .alone(tableName: table.name) : .active(table, cards)
    } catch {
      // Offline: the cached feed renders (SPEC 8.4). No cache → the failure state.
      if let cache = try? store.cachedTable(tableId: tableId) {
        state = .offline(
          tableName: cache.table?.name ?? "your table",
          cards: cache.cards,
          asOf: cache.fetchedAt)
      } else {
        state = .failed(message: Self.failureCopy(error))
      }
    }
  }

  private func activeTableId() -> String? {
    if let explicit = try? store.activeTableId(), explicit != nil {
      return explicit
    }
    return try? store.latestCachedTableId()
  }

  // MARK: - Create and join (§9.6)

  /// Owner path: create the table. 409 `table_full` surfaces "Someone has to leave first."
  public func createTable(named name: String) async {
    failure = nil
    do {
      let table = try await client.createTable(CommunityCreateTableRequest(name: name))
      try? store.setActiveTable(tableId: table.tableId)
      try? store.cacheTable(table: table, cards: [], tableId: table.tableId)
      tableId = table.tableId
      state = .alone(tableName: table.name)
    } catch {
      mapFailure(error)
    }
  }

  /// Joiner path: present a join code. The 202 response is pending owner approval; the ask
  /// survives as an outbox row when offline (SPEC 5.1, 8.3).
  public func join(withCode code: String) async {
    failure = nil
    do {
      let join = try await client.joinTable(code: code)
      try? store.setActiveTable(tableId: join.tableId)
      tableId = join.tableId
      state = .askingToJoin(tableName: join.tableName)
    } catch {
      // A 404 covers revoked codes, wrong codes, and blocked pairs alike — the joiner is
      // not told which (§5.1, §6.3); the mock copy is one line for all three.
      mapFailure(error)
    }
  }

  /// Mints an invite. The joinCode arrives once; nothing server-side can show it again.
  public func mintInvite() async {
    guard let tableId else { return }
    do {
      mintedInvite = try await client.createInvite(tableId: tableId)
    } catch {
      mapFailure(error)
    }
  }

  /// Owner approves a pending ask (rides the outbox, §5.1).
  public func approve(inviteId: String) async {
    guard let tableId else { return }
    await enqueueTableEvent(.init(event: .approveInvite, tableId: tableId, inviteId: inviteId))
    await load()
  }

  /// Owner declines a pending ask — the contract's decline is a revoke (§5.1).
  public func decline(inviteId: String) async {
    guard let tableId else { return }
    await enqueueTableEvent(.init(event: .revokeInvite, tableId: tableId, inviteId: inviteId))
    await load()
  }

  // MARK: - Cards (§9.7)

  /// Shares a cook (SPEC 5.2). The 18+ gate is enforced here and server-side; the write
  /// rides the outbox with a stable operationId so replays dedupe (SPEC 8.3).
  public func share(_ cook: CommunitySharedCook) async {
    failure = nil
    guard session.isAdult else {
      failure = .notAdult
      return
    }
    guard let tableId else { return }
    let request = CommunityShareCookRequest(
      operationId: UUID().uuidString.lowercased(), cook: cook)
    let payload = OutboxService.ShareCookOutboxPayload(tableId: tableId, request: request)
    do {
      _ = try store.enqueue(
        .shareCook,
        payload: JSONEncoder().encode(payload),
        recipeId: nil,
        operationId: request.operationId)
      let result = await outbox.drain()
      queuedWrites = (try? store.queuedOutboxCount()) ?? 0
      _ = result
      await load()
    } catch {
      failure = .message("Your card isn't shared yet. It will send when you're online.")
    }
  }

  /// Owner removes someone (§5.4). The former member loses access; their cards stay in
  /// history, redacted in every view.
  public func removeMember(_ accountId: String) async {
    guard let tableId else { return }
    do {
      try await client.removeMember(tableId: tableId, accountId: accountId)
      await load()
    } catch {
      mapFailure(error)
    }
  }

  /// "Leave Flat 4B? Your cooks stay in your Cookbook." — the confirm is UI; then the local
  /// feed and link go (§5.1, §9.7).
  public func leave() async {
    guard let tableId else { return }
    await enqueueTableEvent(.init(event: .leaveTable, tableId: tableId))
    try? store.clearTableCache(tableId: tableId)
    try? store.clearActiveTable()
    self.tableId = nil
    state = .noTable
  }

  public func deleteCard(_ cardId: String) async {
    guard let tableId else { return }
    do {
      try await client.deleteCard(tableId: tableId, cardId: cardId)
      await load()
    } catch {
      mapFailure(error)
    }
  }

  // MARK: - Blocks (§6.3, §9.8)

  /// Blocks an account. Quiet and one-sided: the other person is never told (§6.3).
  public func block(_ accountId: String) async {
    await enqueueTableEvent(.init(event: .blockAccount, accountId: accountId))
    await reloadBlocks()
    await load()
  }

  public func unblock(_ accountId: String) async {
    await enqueueTableEvent(.init(event: .unblockAccount, accountId: accountId))
    await reloadBlocks()
    await load()
  }

  public func isBlocked(_ accountId: String) -> Bool {
    blockedAccountIds.contains(accountId)
  }

  private func refreshBlocks(table: CommunityTable?) async {
    if let blocks = try? await client.listBlocks() {
      blockedAccountIds = Set(blocks.map(\.accountId))
    }
    let memberIds = Set(table?.members.map(\.accountId) ?? [])
    conflictHint = !blockedAccountIds.isDisjoint(with: memberIds)
  }

  private func reloadBlocks() async {
    if let blocks = try? await client.listBlocks() {
      blockedAccountIds = Set(blocks.map(\.accountId))
    }
  }

  // MARK: - Plumbing

  private func enqueueTableEvent(_ payload: OutboxService.TableEventOutboxPayload) async {
    _ = try? store.enqueue(
      .tableEvent,
      payload: (try? JSONEncoder().encode(payload)) ?? Data(),
      recipeId: nil,
      operationId: UUID().uuidString.lowercased())
    _ = await outbox.drain()
    queuedWrites = (try? store.queuedOutboxCount()) ?? 0
  }

  private func mapFailure(_ error: Error) {
    if let apiError = error as? CommunityAPIError {
      switch apiError.serverErrorCode {
      case .tableFull:
        failure = .tableFull
      case .notAdult:
        failure = .notAdult
      case .personalData:
        failure = .personalData
      default:
        failure = .message(Self.failureCopy(error))
      }
    } else {
      failure = .message(Self.failureCopy(error))
    }
  }

  static func failureCopy(_ error: Error) -> String {
    if let apiError = error as? CommunityAPIError, let server = apiError.serverError {
      return server.message
    }
    return "Couldn't reach your table. Your cards are safe on this phone."
  }
}
