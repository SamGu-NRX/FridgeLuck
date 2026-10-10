import Foundation
import GRDB

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

// MARK: - Notification

extension Notification.Name {
  /// Posted exactly once, only after a staged user-data restore has fully
  /// committed to the live database. Consumers (dashboard, kitchen, and any
  /// future unified search) must re-read user data when they receive it.
  public static let fridgeLuckUserDataDidRestore = Notification.Name(
    "samgu.FridgeLuck.userDataDidRestore")
}

// MARK: - Values

/// One SQLite cell as carried inside a backup archive.
///
/// The archive encodes every value as a tagged string (`"i:42"`, `"d:1.5"`,
/// `"s:text"`) so integer/double/text are unambiguous after a JSON round
/// trip and the canonical hash can be recomputed byte-for-byte on both
/// sides. `nil` encodes as JSON `null`.
enum BackupValue: Equatable, Sendable {
  case int(Int64)
  case double(Double)
  case text(String)

  /// Deterministic, type-explicit string used for hashing.
  /// Doubles are hashed by IEEE 754 bit pattern so the hash is stable
  /// across platforms and formatter changes.
  var canonical: String {
    switch self {
    case .int(let v): return "i:\(v)"
    case .double(let v): return "d:\(v.bitPattern)"
    case .text(let s): return "s:\(s)"
    }
  }

  var databaseValue: DatabaseValue {
    switch self {
    case .int(let v): return v.databaseValue
    case .double(let v): return v.databaseValue
    case .text(let s): return s.databaseValue
    }
  }

  /// Encoded JSON representation: a tagged string, or absence (JSON null).
  var archiveString: String? {
    switch self {
    case .int(let v): return "i:\(v)"
    case .double(let v): return "d:\(v)"
    case .text(let s): return "s:\(s)"
    }
  }

  /// Parses one tagged archive cell. Throws on unparseable tags or
  /// out-of-range integers; non-finite doubles are rejected by the codec.
  static func parse(_ raw: String?) throws -> BackupValue? {
    guard let tagged = raw else { return nil }
    guard tagged.count >= 2, tagged[tagged.startIndex] != ":",
      let colon = tagged.firstIndex(of: ":")
    else {
      throw BackupArchiveError.malformedArchive(
        "unparseable cell value: \(tagged.count > 40 ? String(tagged.prefix(40)) + "…" : tagged)")
    }
    let tag = tagged[tagged.startIndex]
    let body = String(tagged[tagged.index(after: colon)...])
    switch tag {
    case "i":
      guard let v = Int64(body) else {
        throw BackupArchiveError.malformedArchive("integer out of range")
      }
      return .int(v)
    case "d":
      guard let v = Double(body), v.isFinite else {
        throw BackupArchiveError.malformedArchive("non-finite or unparseable number")
      }
      return .double(v)
    case "s":
      return .text(body)
    default:
      throw BackupArchiveError.malformedArchive("unknown cell tag \(tag)")
    }
  }
}

// MARK: - Schema catalog

enum BackupTableClass: String, Codable, Sendable {
  /// Data the user created or that reflects their behavior.
  case userRecords
  /// Seeded or refreshed from the app bundle and rebuildable from it,
  /// carried for exact-state fidelity but reported separately in previews.
  case bundledResources
}

/// One table that exists at the pinned schema version, with the metadata
/// the backup codec needs to read, hash, and replace it.
struct BackupTableSpec: Sendable {
  let name: String
  /// Schema migration that introduced the table (its "table version").
  let tableVersion: Int
  let `class`: BackupTableClass
  /// Primary key columns; the canonical row order used for hashing.
  let primaryKey: [String]
}

/// The tables actually present at schema v20 of this snapshot — the
/// historical-nutrition schema — with their topological order (parents
/// before children for insertion, reverse for deletion).
enum BackupSchemaCatalog {
  /// The migration target this codec is pinned to.
  static let currentSchemaVersion = 20
  static let formatName = "FridgeLuckBackup"
  static let formatVersion = 1

  static let tables: [BackupTableSpec] = [
    // Parents first.
    .init(name: "ingredients", tableVersion: 1, class: .userRecords, primaryKey: ["id"]),
    .init(name: "recipes", tableVersion: 1, class: .userRecords, primaryKey: ["id"]),
    .init(name: "health_profile", tableVersion: 1, class: .userRecords, primaryKey: ["id"]),
    .init(name: "badges", tableVersion: 1, class: .userRecords, primaryKey: ["id"]),
    .init(name: "streaks", tableVersion: 1, class: .userRecords, primaryKey: ["date"]),
    .init(
      name: "dish_templates", tableVersion: 3, class: .bundledResources, primaryKey: ["id"]),
    .init(
      name: "ingredient_aliases", tableVersion: 4, class: .userRecords, primaryKey: ["id"]),
    .init(
      name: "usda_catalog_state", tableVersion: 7, class: .bundledResources, primaryKey: ["key"]),
    .init(
      name: "bundled_recipe_state", tableVersion: 8, class: .bundledResources,
      primaryKey: ["key"]),
    .init(
      name: "ingredient_shelf_life_profiles", tableVersion: 9, class: .userRecords,
      primaryKey: ["ingredient_id"]),
    .init(name: "inventory_lots", tableVersion: 9, class: .userRecords, primaryKey: ["id"]),
    .init(
      name: "inventory_items", tableVersion: 9, class: .userRecords, primaryKey: ["ingredient_id"]),
    .init(
      name: "confidence_signal_events", tableVersion: 10, class: .userRecords, primaryKey: ["id"]),
    .init(
      name: "trust_vector_state", tableVersion: 10, class: .userRecords,
      primaryKey: ["signal_key"]),
    .init(
      name: "ingredient_favorites", tableVersion: 13, class: .userRecords,
      primaryKey: ["ingredient_id"]),
    .init(
      name: "pantry_assumptions", tableVersion: 14, class: .userRecords,
      primaryKey: ["ingredient_id"]),
    .init(name: "notification_rules", tableVersion: 15, class: .userRecords, primaryKey: ["id"]),
    .init(
      name: "notification_opportunities", tableVersion: 15, class: .userRecords,
      primaryKey: ["id"]),
    .init(name: "cooking_history", tableVersion: 1, class: .userRecords, primaryKey: ["id"]),
    .init(name: "recipe_ingredients", tableVersion: 1, class: .userRecords,
      primaryKey: ["recipe_id", "ingredient_id"]),
    .init(name: "user_corrections", tableVersion: 1, class: .userRecords, primaryKey: ["id"]),
    .init(name: "inventory_events", tableVersion: 9, class: .userRecords, primaryKey: ["id"]),
    .init(
      name: "cooking_history_swaps", tableVersion: 18, class: .userRecords,
      primaryKey: ["history_id", "original_ingredient_id"]),
    .init(
      name: "cooking_history_nutrition_snapshots", tableVersion: 20, class: .userRecords,
      primaryKey: ["history_id"]),
    .init(
      name: "cooking_history_nutrition_lines", tableVersion: 20, class: .userRecords,
      primaryKey: ["history_id", "line_index"]),
  ]

  /// Insertion order is the declaration order above (topological).
  static var insertOrder: [BackupTableSpec] { tables }

  /// Deletion wipes in reverse topological order.
  static var deleteOrder: [BackupTableSpec] { tables.reversed() }

  static func spec(named name: String) -> BackupTableSpec? {
    tables.first { $0.name == name }
  }
}

// MARK: - Archive model

/// Manifest entry for one table inside an archive.
struct BackupTableManifest: Codable, Equatable, Sendable {
  var name: String
  var tableVersion: Int
  var tableClass: String
  /// Column order as exported (must match the live schema at schemaVersion).
  var columns: [String]
  var rowCount: Int
  /// SHA-256 over the canonical serialization of all rows (PK-sorted).
  var rowsSHA256: String
}

/// Optional photo payload. Off by default.
struct BackupPhotoEntry: Codable, Equatable, Sendable {
  /// Documents-relative path as stored in cooking_history.image_path,
  /// e.g. "MealPhotos/UUID.jpg". Validated against traversal abuse.
  var relativePath: String
  var sha256: String
  var base64Data: String
}

/// A versioned, self-describing FridgeLuck backup archive.
struct BackupArchive: Codable, Equatable, Sendable {
  var format: String
  var formatVersion: Int
  /// ISO 8601 UTC.
  var createdAt: String
  /// Schema version the rows were exported from.
  var schemaVersion: Int
  var includesPhotos: Bool
  var appVersion: String?
  var tables: [BackupTableManifest]
  /// Rows keyed by table name, as arrays of tagged cells (JSON null = NULL).
  var rows: [String: [[String?]]]
  var photos: [BackupPhotoEntry]?
}


/// Size caps for archive decode/encode. Injectable so tests can exercise
/// abuse cases without building oversized payloads.
struct BackupLimits: Sendable {
  var maxArchiveBytes: Int
  var maxRowsPerTable: Int
  var maxPhotoCount: Int
  var maxPhotoBytes: Int

  static let standard = BackupLimits(
    maxArchiveBytes: 256 * 1024 * 1024,
    maxRowsPerTable: 1_000_000,
    maxPhotoCount: 5_000,
    maxPhotoBytes: 20 * 1024 * 1024)
}

// MARK: - Codec

enum BackupArchiveError: Error, Equatable {
  case malformedArchive(String)
  case unsupportedFormat
  case unsupportedFormatVersion(Int)
  case unsupportedSchemaVersion(Int)
  case unknownTable(String)
  case unsupportedTableVersion(table: String, version: Int)
  case sizeLimitExceeded(String)
  case hashMismatch(table: String)
  case photoPathRejected(String)
  case photoHashMismatch(String)
}

/// Encodes a live database to archive JSON and decodes archive JSON back to
/// rows. Purely structural: relationship, amount, and completeness checks
/// live in `BackupValidator`.
enum BackupArchiveCodec {
  /// Documents-relative prefixes allowed to carry photo payloads.
  static let allowedPhotoPrefixes = ["MealPhotos/"]

  // MARK: Encode

  static func encode(_ archive: BackupArchive, limits: BackupLimits = .standard) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(archive)
    guard data.count <= limits.maxArchiveBytes else {
      throw BackupArchiveError.sizeLimitExceeded(
        "encoded archive is \(data.count) bytes, over the \(limits.maxArchiveBytes) limit")
    }
    return data
  }

  /// Structural decode. Enforces caps, format identity, version refusal
  /// (later format/table/schema versions refuse loudly — never silently
  /// skip), manifest/table shape agreement, and per-table hashes.
  static func decode(_ data: Data, limits: BackupLimits = .standard) throws -> BackupArchive {
    guard data.count <= limits.maxArchiveBytes else {
      throw BackupArchiveError.sizeLimitExceeded(
        "archive is \(data.count) bytes, over the \(limits.maxArchiveBytes) limit")
    }

    // Cheap pre-scan so a hostile payload fails before JSON decoding.
    // (JSONDecoder would also fail, but with a less actionable error.)
    guard data.count > 2 else {
      throw BackupArchiveError.malformedArchive("empty archive")
    }

    let decoder = JSONDecoder()
    let archive: BackupArchive
    do {
      archive = try decoder.decode(BackupArchive.self, from: data)
    } catch {
      throw BackupArchiveError.malformedArchive("invalid JSON: \(error.localizedDescription)")
    }

    guard archive.format == BackupSchemaCatalog.formatName else {
      throw BackupArchiveError.unsupportedFormat
    }
    guard archive.formatVersion <= BackupSchemaCatalog.formatVersion else {
      throw BackupArchiveError.unsupportedFormatVersion(archive.formatVersion)
    }
    guard archive.schemaVersion == BackupSchemaCatalog.currentSchemaVersion else {
      // A later schema version means a NEWER app wrote this archive:
      // refuse with an explicit message rather than dropping tables.
      throw BackupArchiveError.unsupportedSchemaVersion(archive.schemaVersion)
    }

    try validateStructure(archive, limits: limits)
    try verifyHashes(archive)
    try validatePhotos(archive, limits: limits)
    return archive
  }

  private static func validateStructure(_ archive: BackupArchive, limits: BackupLimits) throws {
    let manifests = archive.tables
    guard !manifests.isEmpty else {
      throw BackupArchiveError.malformedArchive("archive declares no tables")
    }

    var seen = Set<String>()
    for manifest in manifests {
      guard !seen.contains(manifest.name) else {
        throw BackupArchiveError.malformedArchive("duplicate table \(manifest.name)")
      }
      seen.insert(manifest.name)

      guard let spec = BackupSchemaCatalog.spec(named: manifest.name) else {
        // Unknown table: refuse, do not vanish it.
        throw BackupArchiveError.unknownTable(manifest.name)
      }
      guard manifest.tableVersion <= spec.tableVersion else {
        throw BackupArchiveError.unsupportedTableVersion(
          table: manifest.name, version: manifest.tableVersion)
      }
      guard manifest.tableClass == spec.class.rawValue else {
        throw BackupArchiveError.malformedArchive(
          "table \(manifest.name) class mismatch: \(manifest.tableClass)")
      }
      guard manifest.rowCount <= limits.maxRowsPerTable else {
        throw BackupArchiveError.sizeLimitExceeded(
          "table \(manifest.name) declares \(manifest.rowCount) rows")
      }

      guard let tableRows = archive.rows[manifest.name] else {
        throw BackupArchiveError.malformedArchive("table \(manifest.name) has no rows payload")
      }
      guard tableRows.count == manifest.rowCount else {
        throw BackupArchiveError.malformedArchive(
          "table \(manifest.name) manifest says \(manifest.rowCount) rows, found \(tableRows.count)")
      }
      for (index, row) in tableRows.enumerated() {
        guard row.count == manifest.columns.count else {
          throw BackupArchiveError.malformedArchive(
            "table \(manifest.name) row \(index) has \(row.count) cells, expected "
              + "\(manifest.columns.count)")
        }
      }
    }

    for (name, _) in archive.rows where !seen.contains(name) {
      throw BackupArchiveError.unknownTable(name)
    }
  }

  /// Recomputes every table's canonical hash from its decoded rows and
  /// compares it to the manifest. Any drift refuses the archive.
  private static func verifyHashes(_ archive: BackupArchive) throws {
    for manifest in archive.tables {
      let rows = try Self.parseRows(
        rawRows: archive.rows[manifest.name] ?? [], columns: manifest.columns)
      let spec = BackupSchemaCatalog.spec(named: manifest.name)
      let hash = Self.canonicalHash(
        table: manifest.name, columns: manifest.columns,
        primaryKey: spec?.primaryKey ?? [], rows: rows)
      guard hash == manifest.rowsSHA256 else {
        throw BackupArchiveError.hashMismatch(table: manifest.name)
      }
    }
  }

  private static func validatePhotos(_ archive: BackupArchive, limits: BackupLimits) throws {
    let photos = archive.photos ?? []
    guard photos.count <= limits.maxPhotoCount else {
      throw BackupArchiveError.sizeLimitExceeded("archive carries \(photos.count) photos")
    }
    guard archive.includesPhotos || photos.isEmpty else {
      throw BackupArchiveError.malformedArchive(
        "photos payload present but includesPhotos is false")
    }
    for photo in photos {
      guard Self.isAcceptablePhotoPath(photo.relativePath) else {
        throw BackupArchiveError.photoPathRejected(photo.relativePath)
      }
      guard let data = Data(base64Encoded: photo.base64Data) else {
        throw BackupArchiveError.malformedArchive(
          "photo \(photo.relativePath) is not valid base64")
      }
      guard data.count <= limits.maxPhotoBytes else {
        throw BackupArchiveError.sizeLimitExceeded(
          "photo \(photo.relativePath) is \(data.count) bytes")
      }
      let digest = SHA256.hash(data: data)
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      guard hex == photo.sha256 else {
        throw BackupArchiveError.photoHashMismatch(photo.relativePath)
      }
    }
  }

  /// Photo paths must stay inside an allowed documents-relative directory:
  /// no absolute paths, no `..` components, no separators beyond the
  /// directory prefix.
  static func isAcceptablePhotoPath(_ path: String) -> Bool {
    guard !path.hasPrefix("/"), !path.contains("\0") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.contains(where: { $0 == "MealPhotos" }) else { return false }
    for component in components {
      if component == ".." || component == "." || component.isEmpty { return false }
    }
    return allowedPhotoPrefixes.contains { path.hasPrefix($0) }
  }

  // MARK: Row conversion and canonical hashing

  static func parseRows(rawRows: [[String?]], columns: [String]) throws -> [[BackupValue?]] {
    try rawRows.map { row in
      try row.map { try BackupValue.parse($0) }
    }
  }

  static func cellString(_ value: BackupValue?) -> String? {
    value?.archiveString
  }

  /// SHA-256 over a length-prefixed, PK-sorted canonical serialization of
  /// a table's rows. Deterministic across exporter/importer and platforms.
  static func canonicalHash(
    table: String, columns: [String], primaryKey: [String], rows: [[BackupValue?]]
  ) -> String {
    var sorted = rows
    if !primaryKey.isEmpty {
      let pkIndexes = primaryKey.compactMap { columns.firstIndex(of: $0) }
      sorted.sort { lhs, rhs in
        for i in pkIndexes {
          let a = lhs[i]?.canonical ?? "n"
          let b = rhs[i]?.canonical ?? "n"
          if a != b { return a < b }
        }
        return false
      }
    }

    var canonical = "\(table.count):\(table)"
    canonical += " columns=\(columns.count)"
    for column in columns {
      canonical += " \(column.count):\(column)"
    }
    for row in sorted {
      canonical += "\nrow \(row.count)"
      for (index, value) in row.enumerated() {
        let cell = value?.canonical ?? "n"
        canonical += " \(index):\(cell.count):\(cell)"
      }
    }

    let digest = SHA256.hash(data: Data(canonical.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
