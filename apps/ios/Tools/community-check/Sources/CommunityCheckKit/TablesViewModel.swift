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
    /// "Owners delete the table instead of leaving." (§9.7 — the server refuses an owner's
    /// leave with 409, backend tables/index.ts:402.)
    case ownerCannotLeave
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
      try? store.clearPendingJoin()  // the owner approved: linked, not pending (§9.6)
      await refreshBlocks(table: table)
      state = table.isOwnerAlone ? .alone(tableName: table.name) : .active(table, cards)
    } catch {
      // Pending joiner: the server refuses GET /tables/{id} with 404 until the owner
      // approves (requireActiveMembership, backend tables/index.ts) — the persisted
      // pending marker maps a relaunch back to the asking state instead of .failed (§9.6).
      if let apiError = error as? CommunityAPIError, apiError.statusCode == 404,
        let pending = try? store.pendingJoin(), pending.tableId == tableId
      {
        state = .askingToJoin(tableName: pending.tableName)
      } else if let cache = try? store.cachedTable(tableId: tableId) {
        // Offline: the cached feed renders (SPEC 8.4). No cache → the failure state.
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
  /// A transport-level failure enqueues the create as an outbox row (SPEC 8.3): the intent
  /// survives offline and the outbox's own handler links the table once the server creates it.
  public func createTable(named name: String) async {
    failure = nil
    do {
      let table = try await client.createTable(CommunityCreateTableRequest(name: name))
      try? store.setActiveTable(tableId: table.tableId)
      try? store.cacheTable(table: table, cards: [], tableId: table.tableId)
      tableId = table.tableId
      state = .alone(tableName: table.name)
    } catch let error as CommunityAPIError {
      // The server answered and refused — nothing to retry.
      mapFailure(error)
    } catch {
      await enqueueTableEvent(.init(event: .createTable, name: name))
      state = .alone(tableName: name)
    }
  }

  /// Joiner path: present a join code. The 202 response is pending owner approval — the ask
  /// is persisted so a relaunch maps the server's 404 back to the asking state — and the ask
  /// survives as an outbox row when offline (SPEC 5.1, 8.3).
  public func join(withCode code: String) async {
    failure = nil
    do {
      let join = try await client.joinTable(code: code)
      try? store.setActiveTable(tableId: join.tableId)
      try? store.setPendingJoin(tableId: join.tableId, tableName: join.tableName)
      tableId = join.tableId
      state = .askingToJoin(tableName: join.tableName)
    } catch let error as CommunityAPIError {
      // A 404 covers revoked codes, wrong codes, and blocked pairs alike — the joiner is
      // not told which (§5.1, §6.3); the mock copy is one line for all three.
      mapFailure(error)
    } catch {
      // Offline: enqueue the ask; the outbox's joinByCode handler links the table when the
      // ask lands (SPEC 8.3). The code stands in for the table name until approval.
      await enqueueTableEvent(.init(event: .joinByCode, code: code))
      state = .askingToJoin(tableName: code)
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
  /// feed and link go (§5.1, §9.7). Only the server's acceptance clears local state: an
  /// owner's leave is refused with 409 and must route to the delete flow instead, and an
  /// offline leave keeps the table until the row actually leaves the queue as sent.
  public func leave() async {
    guard let tableId else { return }
    if viewerIsOwner {
      failure = .ownerCannotLeave
      return
    }
    let leaving = tableId
    let result = await enqueueTableEvent(.init(event: .leaveTable, tableId: leaving))
    if result.sent > 0 {
      // The outbox row's own handler cleared the cache and link after the server accepted.
      self.tableId = nil
      state = .noTable
    } else if result.conflicts > 0 {
      // 409 mid-drain (a role changed server-side since the cache): the table is still ours.
      failure = .ownerCannotLeave
    }
    // Otherwise the row is queued or retrying: state stays until the send lands.
  }

  /// Whether the signed-in account is the table's owner, per the cached table view. When no
  /// cache exists there is nothing to strand, so the check is allowed to read false.
  private var viewerIsOwner: Bool {
    guard let tableId, let accountId = session.account?.accountId,
      let cache = try? store.cachedTable(tableId: tableId), let table = cache.table
    else { return false }
    return table.members.first(where: { $0.accountId == accountId })?.role == .owner
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

  @discardableResult
  private func enqueueTableEvent(_ payload: OutboxService.TableEventOutboxPayload) async
    -> OutboxDrainResult
  {
    _ = try? store.enqueue(
      .tableEvent,
      payload: (try? JSONEncoder().encode(payload)) ?? Data(),
      recipeId: nil,
      operationId: UUID().uuidString.lowercased())
    let result = await outbox.drain()
    queuedWrites = (try? store.queuedOutboxCount()) ?? 0
    return result
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
