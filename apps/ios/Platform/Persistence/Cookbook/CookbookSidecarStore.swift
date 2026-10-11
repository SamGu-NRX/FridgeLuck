import Foundation

/// What `load` had to do to return a document. Recorded so the UI (and tests)
/// can surface recovery instead of silently pretending nothing happened.
enum CookbookSidecarRecovery: Sendable, Equatable {
  /// The main file was unreadable; the pre-write backup parsed instead.
  case restoredFromBackup
  /// Neither main nor backup parsed; a fresh document was installed.
  case resetAfterCorruption
}

/// File-backed store for `CookbookSidecarDocument`.
///
/// Durability contract:
/// - Every write is atomic (temp file + rename) and first rotates the previous
///   good main file to `<file>.bak`, so a crash mid-write or a corrupt write
///   leaves a recoverable predecessor.
/// - `load` prefers the main file, falls back to the backup, and only then
///   resets to a fresh document — and reports which path it took.
/// - A document claiming a version this build does not understand is an error,
///   never a silent reset: a newer app's data must not be clobbered.
///
/// Access is lock-guarded; the class is `@unchecked Sendable` because the lock
/// is the synchronization point for all file access.
final class CookbookSidecarStore: @unchecked Sendable {
  private let fileURL: URL
  private var backupURL: URL { fileURL.appendingPathExtension("bak") }
  private let lock = NSLock()

  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// - Parameter fileURL: location of the sidecar document. Tests inject a
  ///   temporary directory; production defaults into Application Support.
  init(fileURL: URL) {
    self.fileURL = fileURL
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  struct LoadResult: Sendable, Equatable {
    var document: CookbookSidecarDocument
    var recovery: CookbookSidecarRecovery?
  }

  func load() throws -> LoadResult {
    lock.lock()
    defer { lock.unlock() }
    if let main = try? Self.readDocument(at: fileURL, decoder: decoder) {
      try Self.assertSupported(main)
      return LoadResult(document: Self.migrated(main), recovery: nil)
    }
    if let backup = try? Self.readDocument(at: backupURL, decoder: decoder) {
      try Self.assertSupported(backup)
      return LoadResult(document: Self.migrated(backup), recovery: .restoredFromBackup)
    }
    // First launch (no files at all) is not a recovery: distinguish it so a
    // genuinely corrupt store is never indistinguishable from a fresh one.
    if FileManager.default.fileExists(atPath: fileURL.path)
      || FileManager.default.fileExists(atPath: backupURL.path) {
      return LoadResult(document: CookbookSidecarDocument(), recovery: .resetAfterCorruption)
    }
    return LoadResult(document: CookbookSidecarDocument(), recovery: nil)
  }

  func save(_ document: CookbookSidecarDocument) throws {
    lock.lock()
    defer { lock.unlock() }
    var stamped = document
    stamped.version = CookbookSidecarDocument.currentVersion
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Rotate the current main file to the backup before replacing it, so the
    // backup always holds the last known-good document.
    if FileManager.default.fileExists(atPath: fileURL.path) {
      if FileManager.default.fileExists(atPath: backupURL.path) {
        try FileManager.default.removeItem(at: backupURL)
      }
      try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    let data = try encoder.encode(stamped)
    // `.atomic` writes a sibling temp file and POSIX-renames it over the
    // destination, replacing any existing main file without an EEXIST race.
    try data.write(to: fileURL, options: .atomic)
  }

  // MARK: - Versioning

  private static func assertSupported(_ document: CookbookSidecarDocument) throws {
    guard document.version <= CookbookSidecarDocument.currentVersion else {
      throw CookbookSidecarError.unsupportedVersion(document.version)
    }
  }

  /// Applies the forward migration chain. Version 1 is the initial shape, so
  /// nothing to do yet; later versions chain `step v2→v1`-style helpers here.
  private static func migrated(_ document: CookbookSidecarDocument) -> CookbookSidecarDocument {
    var migrated = document
    migrated.version = CookbookSidecarDocument.currentVersion
    return migrated
  }

  private static func readDocument(
    at url: URL, decoder: JSONDecoder
  ) throws -> CookbookSidecarDocument {
    let data = try Data(contentsOf: url)
    return try decoder.decode(CookbookSidecarDocument.self, from: data)
  }
}
