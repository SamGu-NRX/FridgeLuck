import Foundation
import GRDB

/// One pending server write read back from `community_outbox`.
public struct OutboxItem: Sendable, Equatable {
  public let id: Int64
  public let operation: OutboxOperationKind
  /// Client-generated UUID sent as the idempotency key; stable across retries.
  public let operationId: String
  public let recipeId: Int64?
  public let payload: Data
  public let attempts: Int
  public let createdAt: Date

  public func decodedPayload<T: Decodable>(as type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: payload)
  }
}

/// GRDB-backed store for the community layer (community SPEC 8.1, 2.1–2.4, 8.3):
/// user recipes with frozen revisions (private by default), create/edit/duplicate,
/// publication-state linkage, and the outbox of pending server writes.
///
/// The cookbook (PR #71) is the intended write authority for recipe content; until that store
/// lands on this branch, the community store owns the content it creates, kept canonically as
/// the frozen `RecipeRevisionContent` payload of the latest revision. Editing forks a new
/// revision; duplicating copies the latest payload into a new recipe at revision 1.
public final class CommunityStore: Sendable {
  private let db: DatabaseQueue

  public init(db: DatabaseQueue) {
    self.db = db
  }

  // MARK: - User recipes

  /// A user recipe as the community layer sees it: identity, provenance, and publication
  /// state. Content lives in the frozen revision payloads.
  public struct UserRecipe: Sendable, Equatable {
    public let recipeId: Int64
    public let communityRecipeId: String
    public let serverRecipeId: String?
    public let publicationId: String?
    public let provenance: String
    public let duplicatedFrom: String?
    public let flaggedTag: AllergenTag?
    public let latestRevision: Int
    /// The revision the server currently publishes, once one is confirmed (SPEC 2.3).
    public let publishedRevision: Int?
    public let authorModerationState: AuthorModerationState
    public let updatedAt: Date
  }

  /// Creates a user recipe, private by default, and freezes revision 1. There is no path
  /// that makes a recipe public here — publishing goes through the outbox (SPEC 2.1).
  @discardableResult
  public func createUserRecipe(
    _ content: RecipeRevisionContent,
    duplicatedFrom: String? = nil,
    now: Date = Date()
  ) throws -> Int64 {
    let payload = try Self.encodeContent(content)
    let recipeId = try db.write { db -> Int64 in
      let communityId = try Self.mintCommunityRecipeId(db: db)
      try db.execute(
        sql: """
          INSERT INTO community_user_recipes
            (community_recipe_id, publication_state, provenance, duplicated_from, updated_at)
          VALUES (?, 'private', 'user-created', ?, ?)
          """,
        arguments: [communityId, duplicatedFrom, CommunityContract.iso8601(now)])
      let newRecipeId = try Int64.fetchOne(
        db,
        sql: "SELECT recipe_id FROM community_user_recipes WHERE community_recipe_id = ?",
        arguments: [communityId])!
      try db.execute(
        sql: """
          INSERT INTO community_user_recipe_revisions
            (recipe_id, revision, payload_json, frozen_at)
          VALUES (?, 1, ?, ?)
          """,
        arguments: [newRecipeId, payload, CommunityContract.iso8601(now)])
      return newRecipeId
    }
    return recipeId
  }

  /// Records an edit as a new revision of the same recipe (SPEC 2.2): numbering continues
  /// monotonically, older revisions stay frozen. Returns the new revision number.
  @discardableResult
  public func editUserRecipe(
    _ recipeId: Int64,
    to content: RecipeRevisionContent,
    now: Date = Date()
  ) throws -> Int {
    try db.write { db in
      let currentRevision =
        try Int.fetchOne(
          db,
          sql: "SELECT MAX(revision) FROM community_user_recipe_revisions WHERE recipe_id = ?",
          arguments: [recipeId]) ?? 0
      let newRevision = currentRevision + 1
      // A published revision is frozen: edits fork to a new revision, never rewrite it.
      try db.execute(
        sql: """
          INSERT INTO community_user_recipe_revisions
            (recipe_id, revision, payload_json, frozen_at)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [
          recipeId,
          newRevision,
          try Self.encodeContent(content),
          CommunityContract.iso8601(now),
        ])
      try db.execute(
        sql: "UPDATE community_user_recipes SET updated_at = ? WHERE recipe_id = ?",
        arguments: [CommunityContract.iso8601(now), recipeId])
      return newRevision
    }
  }

  /// Duplicates a recipe into a new recipe id at revision 1 (SPEC 2.1), carrying
  /// `duplicatedFrom` display-name attribution when the source was someone else's published
  /// recipe. The duplicate is private, like everything else.
  @discardableResult
  public func duplicateUserRecipe(
    _ recipeId: Int64,
    attributedTo sourceAuthor: String? = nil,
    now: Date = Date()
  ) throws -> Int64 {
    guard let payload = try latestRevisionPayload(recipeId: recipeId) else {
      throw CommunityStoreError.recipeNotFound(recipeId)
    }
    let content = try JSONDecoder().decode(RecipeRevisionContent.self, from: payload)
    return try createUserRecipe(
      content,
      duplicatedFrom: sourceAuthor,
      now: now)
  }

  /// The latest frozen revision payload for a recipe, or nil when the recipe does not exist.
  public func latestRevisionPayload(recipeId: Int64) throws -> Data? {
    try db.read { db in
      try Data.fetchOne(
        db,
        sql: """
          SELECT payload_json FROM community_user_recipe_revisions
          WHERE recipe_id = ? ORDER BY revision DESC LIMIT 1
          """,
        arguments: [recipeId])
    }
  }

  /// The latest revision number, or nil when the recipe does not exist.
  public func latestRevision(recipeId: Int64) throws -> Int? {
    try db.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT MAX(revision) FROM community_user_recipe_revisions WHERE recipe_id = ?",
        arguments: [recipeId])
    }
  }

  /// A frozen revision payload by number, for rendering history and "what was published".
  public func revisionPayload(recipeId: Int64, revision: Int) throws -> Data? {
    try db.read { db in
      try Data.fetchOne(
        db,
        sql: """
          SELECT payload_json FROM community_user_recipe_revisions
          WHERE recipe_id = ? AND revision = ?
          """,
        arguments: [recipeId, revision])
    }
  }

  public func userRecipe(recipeId: Int64) throws -> UserRecipe? {
    try db.read { db in
      try Self.readUserRecipe(recipeId: recipeId, db: db)
    }
  }

  /// The author-visible moderation state (SPEC 9.9) derived from stored state.
  public func authorModerationState(recipeId: Int64) throws -> AuthorModerationState? {
    try db.read { db in
      guard let row = try Self.readUserRecipe(recipeId: recipeId, db: db) else { return nil }
      return row.authorModerationState
    }
  }

  /// The publish gate: only user-created provenance may publish in burst5 (SPEC 2.1).
  public func isPublishable(recipeId: Int64) throws -> Bool {
    try db.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT provenance FROM community_user_recipes WHERE recipe_id = ?",
        arguments: [recipeId]) == "user-created"
    }
  }

  // MARK: - Publication linkage

  /// Stamps the rights declaration from the publish flow onto the recipe, so the outbox
  /// drain can rebuild the exact payload (SPEC 2.3 step 2).
  public func recordDeclaration(
    recipeId: Int64,
    declaration: RecipeRightsDeclaration,
    now: Date = Date()
  ) throws {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_user_recipes
          SET own_rights = ?, no_personal_data = ?, updated_at = ?
          WHERE recipe_id = ?
          """,
        arguments: [
          declaration.ownRights,
          declaration.noPersonalData,
          CommunityContract.iso8601(now),
          recipeId,
        ])
    }
  }

  /// Marks the recipe as having a publish (or withdraw) queued: state moves to `in_review`
  /// only when the server confirms, not when the write is queued.
  public func markPublicationEnqueued(recipeId: Int64, revision: Int, now: Date = Date())
    throws
  {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_user_recipes
          SET publication_state = 'private', published_revision = NULL, updated_at = ?
          WHERE recipe_id = ?
          """,
        arguments: [CommunityContract.iso8601(now), recipeId])
    }
  }

  /// Applies a confirmed server publication (the decoded response) to the local linkage.
  public func applyPublication(_ publication: Publication, recipeId: Int64, now: Date = Date())
    throws
  {
    let storageState: String
    switch publication.state {
    case .published: storageState = "published"
    case .queued: storageState = "in_review"
    case .rejected: storageState = "rejected"
    case .withdrawn: storageState = "withdrawn"
    }
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_user_recipes
          SET server_recipe_id = ?, publication_id = ?, publication_state = ?,
              published_revision = ?, flagged_tag = ?, last_synced_at = ?, updated_at = ?
          WHERE recipe_id = ?
          """,
        arguments: [
          publication.recipeRef.id,
          publication.publicationId,
          storageState,
          publication.recipeRef.revision,
          publication.flaggedTag?.rawValue,
          CommunityContract.iso8601(now),
          CommunityContract.iso8601(now),
          recipeId,
        ])
    }
  }

  /// Withdrawal (SPEC 2.3 step 5): the recipe stays local and owned; the Explore copy is gone.
  public func markWithdrawn(recipeId: Int64, now: Date = Date()) throws {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_user_recipes
          SET publication_state = 'withdrawn', flagged_tag = NULL, last_synced_at = ?, updated_at = ?
          WHERE recipe_id = ?
          """,
        arguments: [CommunityContract.iso8601(now), CommunityContract.iso8601(now), recipeId])
    }
  }

  // MARK: - Outbox

  /// Records one pending server write. The write is local-first: nothing has been sent yet.
  @discardableResult
  public func enqueue(
    _ operation: OutboxOperationKind,
    payload: Data,
    recipeId: Int64?,
    operationId: String = UUID().uuidString,
    now: Date = Date()
  ) throws -> Int64 {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT INTO community_outbox
            (operation, operation_id, recipe_id, payload_json, state, created_at, attempts)
          VALUES (?, ?, ?, ?, 'queued', ?, 0)
          """,
        arguments: [
          operation.rawValue, operationId, recipeId, String(decoding: payload, as: UTF8.self),
          CommunityContract.iso8601(now),
        ])
      return db.lastInsertedRowID
    }
  }

  /// Rows due to send: `queued` (or stuck `sending` after a crash) with no retry wait, oldest
  /// first so per-recipe ordering follows `created_at` + attempt (SPEC 8.3).
  public func dueOutboxItems(now: Date, limit: Int = 20) throws -> [OutboxItem] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, operation, operation_id, recipe_id, payload_json, attempts, created_at
          FROM community_outbox
          WHERE state IN ('queued', 'sending')
            AND (next_retry_at IS NULL OR next_retry_at <= ?)
          ORDER BY created_at ASC, id ASC
          LIMIT ?
          """,
        arguments: [CommunityContract.iso8601(now), limit])
      return rows.compactMap { row in
        guard
          let operation = OutboxOperationKind(rawValue: row["operation"] ?? ""),
          let createdAt = CommunityContract.date(fromISO8601: row["created_at"] ?? "")
        else { return nil }
        return OutboxItem(
          id: row["id"],
          operation: operation,
          operationId: row["operation_id"] ?? "",
          recipeId: row["recipe_id"],
          payload: Data((row["payload_json"] as String).utf8),
          attempts: row["attempts"] ?? 0,
          createdAt: createdAt)
      }
    }
  }

  /// Confirmed success: the row is removed (SPEC 8.3 — removed only on confirmed success).
  public func removeOutboxItem(id: Int64) throws {
    try db.write { db in
      try db.execute(sql: "DELETE FROM community_outbox WHERE id = ?", arguments: [id])
    }
  }

  /// Failure with retry: increments attempts, records the error, schedules backoff.
  public func scheduleOutboxRetry(id: Int64, attempts: Int, nextRetryAt: Date, error: String)
    throws
  {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_outbox
          SET state = 'queued', attempts = ?, next_retry_at = ?, last_error = ?
          WHERE id = ?
          """,
        arguments: [
          attempts, CommunityContract.iso8601(nextRetryAt), error, id,
        ])
    }
  }

  /// `409` conflict: surfaces to the user, never auto-resolves (SPEC 8.3).
  public func markOutboxConflict(id: Int64, error: String) throws {
    try db.write { db in
      try db.execute(
        sql: "UPDATE community_outbox SET state = 'conflict', last_error = ? WHERE id = ?",
        arguments: [error, id])
    }
  }

  /// Permanent `4xx`: the row stops and the failure surfaces.
  public func markOutboxFailed(id: Int64, error: String) throws {
    try db.write { db in
      try db.execute(
        sql: "UPDATE community_outbox SET state = 'failed', last_error = ? WHERE id = ?",
        arguments: [error, id])
    }
  }

  /// A withdrawn recipe stops sending: every still-queued publish for this recipe is
  /// cancelled before it can leave the phone. Returns the number of cancelled rows.
  @discardableResult
  public func cancelQueuedPublishes(recipeId: Int64, reason: String) throws -> Int {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_outbox
          SET state = 'cancelled', last_error = ?
          WHERE recipe_id = ? AND operation = 'publish' AND state = 'queued'
          """,
        arguments: [reason, recipeId])
      return db.changesCount
    }
  }

  public func outboxState(id: Int64) throws -> OutboxItemState? {
    try db.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT state FROM community_outbox WHERE id = ?",
        arguments: [id]
      ).flatMap(OutboxItemState.init(rawValue:))
    }
  }

  /// Rows still queued (any retry schedule), for the "Will send when you're online" count.
  public func queuedOutboxCount() throws -> Int {
    try db.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM community_outbox WHERE state = 'queued'") ?? 0
    }
  }

  // MARK: - Table feed cache (community SPEC 5, 8.4)

  /// The cached table record plus the card feed as the server last rendered it for this
  /// viewer, keyed by table id in `community_table_cache` (offline rendering, §2.1).
  private struct TableCacheEnvelope: Codable, Equatable {
    var table: CommunityTable?
    var cards: [CommunityTableCard]?
  }

  public struct TableCache: Sendable, Equatable {
    public let tableId: String
    public let table: CommunityTable?
    public let cards: [CommunityTableCard]
    public let fetchedAt: Date
  }

  public func cacheTable(
    table: CommunityTable?, cards: [CommunityTableCard], tableId: String, now: Date = Date()
  ) throws {
    let envelope = TableCacheEnvelope(table: table, cards: cards)
    let payload = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    try db.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO community_table_cache (table_id, fetched_at, payload_json)
          VALUES (?, ?, ?)
          """,
        arguments: [tableId, CommunityContract.iso8601(now), payload])
    }
  }

  public func cachedTable(tableId: String) throws -> TableCache? {
    try db.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT fetched_at, payload_json FROM community_table_cache WHERE table_id = ?",
          arguments: [tableId]),
        let payloadJSON: String = row["payload_json"]
      else { return nil }
      let envelope = try JSONDecoder().decode(
        TableCacheEnvelope.self, from: Data(payloadJSON.utf8))
      return TableCache(
        tableId: tableId,
        table: envelope.table,
        cards: envelope.cards ?? [],
        fetchedAt: CommunityContract.date(fromISO8601: row["fetched_at"])
          ?? Date(timeIntervalSince1970: 0))
    }
  }

  /// The most recently fetched table id, so a relaunch can find its table before the
  /// explicit link row is consulted.
  public func latestCachedTableId() throws -> String? {
    try db.read { db in
      try String.fetchOne(
        db, sql: "SELECT table_id FROM community_table_cache ORDER BY fetched_at DESC LIMIT 1")
    }
  }

  public func clearTableCache(tableId: String) throws {
    try db.write { db in
      try db.execute(
        sql: "DELETE FROM community_table_cache WHERE table_id = ?", arguments: [tableId])
    }
  }

  /// Sets the table this device belongs to (single row, id = 1).
  public func setActiveTable(tableId: String, now: Date = Date()) throws {
    try db.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO community_table_link (id, table_id, updated_at)
          VALUES (1, ?, ?)
          """,
        arguments: [tableId, CommunityContract.iso8601(now)])
    }
  }

  public func activeTableId() throws -> String? {
    try db.read { db in
      try String.fetchOne(db, sql: "SELECT table_id FROM community_table_link WHERE id = 1")
    }
  }

  /// Clears the link after leaving (the table's cache goes too — §5.1/§9.7).
  public func clearActiveTable() throws {
    try db.write { db in
      try db.execute(sql: "DELETE FROM community_table_link WHERE id = 1")
    }
  }

  // MARK: - Pending join (§9.6)

  /// A 202 join: linked but not owner-approved yet. The server 404s GET /tables/{id} for
  /// pending joiners, so the remembered table name lets load() map that 404 back to the
  /// asking state after a relaunch.
  public struct CommunityPendingJoin: Equatable, Sendable {
    public var tableId: String
    public var tableName: String

    public init(tableId: String, tableName: String) {
      self.tableId = tableId
      self.tableName = tableName
    }
  }

  /// Marks the linked table as a pending ask. The link row must already exist (`setActiveTable`).
  public func setPendingJoin(tableId: String, tableName: String) throws {
    try db.write { db in
      try db.execute(
        sql: """
          UPDATE community_table_link SET pending_table_name = ?
          WHERE id = 1 AND table_id = ?
          """,
        arguments: [tableName, tableId])
    }
  }

  /// The pending ask, when the single link row carries one.
  public func pendingJoin() throws -> CommunityPendingJoin? {
    try db.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT table_id, pending_table_name FROM community_table_link
            WHERE id = 1 AND pending_table_name IS NOT NULL
            """)
      else { return nil }
      return CommunityPendingJoin(tableId: row["table_id"], tableName: row["pending_table_name"])
    }
  }

  /// Clears the marker once the owner approved and a table read succeeds.
  public func clearPendingJoin() throws {
    try db.write { db in
      try db.execute(
        sql: "UPDATE community_table_link SET pending_table_name = NULL WHERE id = 1")
    }
  }

  // MARK: - Helpers

  private static func readUserRecipe(recipeId: Int64, db: Database) throws -> UserRecipe? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT recipe_id, community_recipe_id, server_recipe_id, publication_id, provenance,
                 duplicated_from, flagged_tag, publication_state, published_revision, updated_at
          FROM community_user_recipes WHERE recipe_id = ?
          """,
        arguments: [recipeId])
    else { return nil }
    let latestRevision =
      try Int.fetchOne(
        db,
        sql: "SELECT MAX(revision) FROM community_user_recipe_revisions WHERE recipe_id = ?",
        arguments: [recipeId]) ?? 0
    return UserRecipe(
      recipeId: row["recipe_id"],
      communityRecipeId: row["community_recipe_id"],
      serverRecipeId: row["server_recipe_id"],
      publicationId: row["publication_id"],
      provenance: row["provenance"],
      duplicatedFrom: row["duplicated_from"],
      flaggedTag: (row["flagged_tag"] as String?).flatMap(AllergenTag.init(rawValue:)),
      latestRevision: latestRevision,
      publishedRevision: row["published_revision"],
      authorModerationState: AuthorModerationState.derive(
        publicationState: row["publication_state"],
        flaggedTag: row["flagged_tag"]),
      updatedAt: CommunityContract.date(fromISO8601: row["updated_at"] ?? "")
        ?? Date(timeIntervalSince1970: 0))
  }

  private static func encodeContent(_ content: RecipeRevisionContent) throws -> String {
    String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
  }

  /// Mints a unique `ur_…` community recipe id (the RecipeRef id the contract requires).
  private static func mintCommunityRecipeId(db: Database) throws -> String {
    for _ in 0..<8 {
      let candidate = "ur_" + String(UUID().uuidString.prefix(10)).lowercased()
      let count =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM community_user_recipes WHERE community_recipe_id = ?",
          arguments: [candidate]) ?? 0
      if count == 0 { return candidate }
    }
    throw CommunityStoreError.couldNotMintRecipeId
  }

  private func recipeId(for communityId: String) throws -> Int64 {
    try db.read { db in
      guard
        let id = try Int64.fetchOne(
          db,
          sql: "SELECT recipe_id FROM community_user_recipes WHERE community_recipe_id = ?",
          arguments: [communityId])
      else { throw CommunityStoreError.recipeNotFoundForCommunityId(communityId) }
      return id
    }
  }
}

public enum CommunityStoreError: Error, Equatable {
  case recipeNotFound(Int64)
  case recipeNotFoundForCommunityId(String)
  case couldNotMintRecipeId
}
