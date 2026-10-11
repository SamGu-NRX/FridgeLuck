import Foundation
import GRDB

/// Owns the dedicated search index database: a separate SQLite file with FTS5
/// tables, completely outside the shared app schema. Nothing here registers
/// with `DatabaseMigrations` — the search index is rebuildable state whose
/// schema is created (and re-created) directly in its own file, so the shared
/// migration list gains no entries.
///
/// All methods are synchronous and thread-safe; the engine and the service
/// call them from a serialized path.
final class SearchIndexStore: @unchecked Sendable {
  /// Bump when the index schema changes; a mismatch forces a full rebuild.
  static let indexSchemaVersion = 1

  private static let metaKeySchemaVersion = "schema_version"
  private static let metaKeySourceEpoch = "source_epoch"

  private let dbQueue: DatabaseQueue
  private let lock = NSLock()

  /// Opens (creating if needed) the index database at `path` and ensures its
  /// schema exists. A corrupt or foreign file is recovered by the service
  /// deleting and re-creating the file before retrying.
  init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path)
    try ensureSchema()
  }

  /// In-memory store for tests.
  init() throws {
    dbQueue = try DatabaseQueue()
    try ensureSchema()
  }

  private func ensureSchema() throws {
    try dbQueue.write { db in
      try db.execute(
        sql: """
          CREATE TABLE IF NOT EXISTS search_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
          """)
      try db.execute(
        sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS search_documents USING fts5(
            title,
            subtitle,
            keywords,
            date_tokens,
            kind UNINDEXED,
            canonical_id UNINDEXED,
            revision UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 1'
          )
          """)
    }
  }

  // MARK: - Meta

  private func metaValue(_ key: String) throws -> String? {
    try dbQueue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT value FROM search_meta WHERE key = ?",
        arguments: [key])
    }
  }

  private func setMetaValue(_ value: String, forKey key: String, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO search_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value])
  }

  func storedSchemaVersion() throws -> Int? {
    guard let raw = try metaValue(Self.metaKeySchemaVersion) else { return nil }
    return Int(raw)
  }

  /// The source epoch recorded when the index was last fully rebuilt, or nil
  /// when the index has never been built.
  func storedSourceEpoch() throws -> String? {
    try metaValue(Self.metaKeySourceEpoch)
  }

  // MARK: - Rebuild

  /// Replaces the entire index with `documents` in one transaction and records
  /// the source epoch the documents were read at. Rebuilds are total: a record
  /// dropped from the source is dropped from the index here.
  func rebuild(with documents: [SearchDocument], sourceEpoch: String?) throws {
    try dbQueue.write { db in
      try db.execute(sql: "DELETE FROM search_documents")
      for document in documents {
        try Self.insert(document, in: db)
      }
      try setMetaValue(String(Self.indexSchemaVersion), forKey: Self.metaKeySchemaVersion, in: db)
      if let sourceEpoch {
        try setMetaValue(sourceEpoch, forKey: Self.metaKeySourceEpoch, in: db)
      } else {
        try db.execute(
          sql: "DELETE FROM search_meta WHERE key = ?",
          arguments: [Self.metaKeySourceEpoch])
      }
    }
  }

  /// Inserts a single document (creating or replacing its row). Used by
  /// incremental repair; a full `rebuild` is preferred after restore.
  func upsert(_ document: SearchDocument) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM search_documents WHERE canonical_id = ?",
        arguments: [document.canonicalID.description])
      try Self.insert(document, in: db)
    }
  }

  /// Removes a document, e.g. after resolution proved the record was deleted.
  func remove(canonicalID: SearchCanonicalID) throws {
    try dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM search_documents WHERE canonical_id = ?",
        arguments: [canonicalID.description])
    }
  }

  private static func insert(_ document: SearchDocument, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO search_documents
            (title, subtitle, keywords, date_tokens, kind, canonical_id, revision)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        document.title,
        document.subtitle ?? "",
        document.keywords,
        document.dateTokens,
        document.canonicalID.kind.rawValue,
        document.canonicalID.description,
        document.revision,
      ])
  }

  // MARK: - Introspection

  func count() throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents") ?? 0
    }
  }

  func count(kind: SearchRecordKind) throws -> Int {
    try dbQueue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM search_documents WHERE kind = ?",
        arguments: [kind.rawValue]) ?? 0
    }
  }

  /// Approximate on-disk size of the index database in bytes (0 for
  /// in-memory stores).
  func fileSizeBytes() -> Int {
    let path = dbQueue.path
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return 0 }
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.size] as? Int ?? 0
  }

  // MARK: - Query

  /// Runs an FTS5 match over the index. `matchExpression` must already be a
  /// valid FTS5 MATCH expression (the engine builds one).
  func fetchHits(
    match matchExpression: String,
    kinds: Set<SearchRecordKind>?,
    limit: Int
  ) throws -> [SearchHit] {
    try lock.withLock {
      try dbQueue.read { db in
        var sql = """
          SELECT canonical_id, kind, title, subtitle, revision,
                 bm25(search_documents) AS score
          FROM search_documents
          WHERE search_documents MATCH ?
          """
        var arguments: [any DatabaseValueConvertible] = [matchExpression]
        if let kinds, !kinds.isEmpty {
          let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
          sql += " AND kind IN (\(placeholders))"
          arguments.append(contentsOf: kinds.map { $0.rawValue as String })
        }
        sql += " ORDER BY rank ASC, canonical_id ASC LIMIT ?"
        arguments.append(limit)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        return rows.compactMap { row in
          guard let rawKind: String = row["kind"],
            let kind = SearchRecordKind(rawValue: rawKind),
            let canonicalDescription: String = row["canonical_id"],
            let canonicalID = SearchCanonicalID(parsing: canonicalDescription)
          else { return nil }
          let revision: Int64 = row["revision"] ?? 0
          let score: Double = row["score"] ?? 0
          let title: String = row["title"] ?? ""
          let subtitle: String? = row["subtitle"]
          return SearchHit(
            canonicalID: canonicalID,
            title: title,
            subtitle: subtitle,
            revision: revision,
            rankScore: score
          )
        }
      }
    }
  }
}

// MARK: - Canonical ID parsing

extension SearchCanonicalID {
  /// Parses the persisted "kind:rawID" description. Returns nil for malformed
  /// or unknown-kind entries so a corrupt index row can never surface as a hit.
  init?(parsing description: String) {
    guard let separator = description.firstIndex(of: ":") else { return nil }
    let rawKind = description[description.startIndex..<separator]
    let rawID = description[description.index(after: separator)...]
    guard let kind = SearchRecordKind(rawValue: String(rawKind)), !rawID.isEmpty else {
      return nil
    }
    self.init(kind: kind, rawID: String(rawID))
  }
}

// MARK: - Lock helpers

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
