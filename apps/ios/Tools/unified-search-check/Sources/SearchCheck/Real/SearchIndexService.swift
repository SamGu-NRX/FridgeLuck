import Foundation
import GRDB

/// Coordinates the search index lifecycle on top of the source repositories:
/// bootstrap, epoch-driven revalidation, full rebuilds, and query entry.
///
/// Rebuild triggers:
/// - Index missing, empty, schema-version mismatch, or a different source
///   epoch (covers a restored/replaced source database file and a reopened
///   database) — revalidated lazily before each search and at bootstrap.
/// - `FridgeLuckUserDataDidRestore`: posted by the local-backup module after
///   user data is restored. The constant is declared here by its raw name so
///   this module observes it without importing or editing any backup code.
final class SearchIndexService: @unchecked Sendable {
  /// Raw-name notification posted after a user-data restore replaces source
  /// records. Observed (never posted) by this module; tests post it
  /// synthetically.
  static let userDataDidRestoreNotificationName = Notification.Name(
    "FridgeLuckUserDataDidRestore")

  /// A cheap epoch stamp for the source database file: its size and
  /// modification time. Any write to the source database changes the stamp,
  /// which triggers a lazy index rebuild at the next bootstrap or search.
  static func sourceEpoch(forDatabaseAtPath path: String) -> String? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    guard let attributes else { return nil }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "db-\(size)-\(Int64(modifiedAt * 1000))"
  }

  private let store: SearchIndexStore
  private let sources: SearchSources
  private let engine: SearchEngine
  private let sourceEpochProvider: @Sendable () -> String?
  private let lock = NSLock()

  /// Creates the service over an index database at `indexPath` (created when
  /// missing). A corrupt index file is deleted and re-created on first use.
  convenience init(
    indexPath: String,
    sources: SearchSources,
    sourceEpochProvider: @Sendable @escaping () -> String?
  ) {
    let store: SearchIndexStore
    do {
      store = try SearchIndexStore(path: indexPath)
    } catch {
      // Recover from a corrupt/foreign index file: it is rebuildable state.
      try? FileManager.default.removeItem(atPath: indexPath)
      store = (try? SearchIndexStore(path: indexPath)) ?? (try! SearchIndexStore())
    }
    self.init(store: store, sources: sources, sourceEpochProvider: sourceEpochProvider)
  }

  init(
    store: SearchIndexStore,
    sources: SearchSources,
    sourceEpochProvider: @Sendable @escaping () -> String?
  ) {
    self.store = store
    self.sources = sources
    self.sourceEpochProvider = sourceEpochProvider
    self.engine = SearchEngine(
      store: store,
      resolver: CompositeSearchHitResolver(
        db: sources.kitchen.databaseQueue,
        ingredientRepository: sources.kitchen.ingredientRepository,
        inventoryRepository: sources.kitchen.inventoryRepository,
        recipeRepository: sources.recipes.recipeRepository
      ))
  }

  /// Builds the index if it is missing, stale, or from a different source
  /// epoch. Idempotent and cheap when the index is current.
  func bootstrap() throws {
    try revalidateIfNeeded()
  }

  /// Revalidates the source epoch and rebuilds the index when it changed.
  func revalidateIfNeeded() throws {
    try lock.withLock {
      let expectedEpoch = sourceEpochProvider()
      let storedEpoch = try store.storedSourceEpoch()
      let storedVersion = try store.storedSchemaVersion()

      if storedVersion == SearchIndexStore.indexSchemaVersion,
        storedEpoch != nil,
        storedEpoch == expectedEpoch,
        try store.count() > 0
      {
        return
      }

      let documents = try sources.documents()
      try store.rebuild(with: documents, sourceEpoch: expectedEpoch)
    }
  }

  /// Forces a full rebuild from the source repositories (restore path).
  func forceFullRebuild() throws {
    try lock.withLock {
      let documents = try sources.documents()
      try store.rebuild(with: documents, sourceEpoch: sourceEpochProvider())
    }
  }

  /// Runs a query against a current index. Existence revalidation happens
  /// inside the engine before any hit is returned.
  func search(
    _ query: String,
    kinds: Set<SearchRecordKind>? = nil,
    limit: Int = SearchEngine.defaultLimit
  ) throws -> [SearchHit] {
    try revalidateIfNeeded()
    return try engine.search(query, kinds: kinds, limit: limit)
  }

  // MARK: - Diagnostics (tests, eval, debug UI)

  func documentCount() throws -> Int {
    try store.count()
  }

  func documentCount(kind: SearchRecordKind) throws -> Int {
    try store.count(kind: kind)
  }

  func indexFileSizeBytes() -> Int {
    store.fileSizeBytes()
  }

  /// Registers an observer for the restore notification; returns a token the
  /// caller keeps alive. The posted notification triggers a full rebuild.
  func observeRestoreNotifications(_ center: NotificationCenter = .default) -> Any {
    center.addObserver(
      forName: Self.userDataDidRestoreNotificationName,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      // A restore replaces source records; rebuild immediately off-thread.
      Task.detached(priority: .userInitiated) {
        try? self.forceFullRebuild()
      }
    }
  }
}
