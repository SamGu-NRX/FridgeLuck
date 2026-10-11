import Foundation

// MARK: - Record kinds

/// The record families the unified search index covers. Each kind maps to
/// exactly one base repository family, and results keep their kind so the
/// Search screen can group and route them.
public enum SearchRecordKind: String, Sendable, CaseIterable, Codable, Comparable {
  /// A catalog ingredient (the Kitchen ingredient picker universe).
  case kitchenIngredient = "kitchen_ingredient"
  /// A live kitchen inventory item (ingredient + storage location).
  case kitchenInventory = "kitchen_inventory"
  /// A persisted recipe row.
  case recipe = "recipe"
  /// A logged meal in the cooking journal (cooking_history row).
  case journal = "journal"

  public var displayName: String {
    switch self {
    case .kitchenIngredient: return "Ingredient"
    case .kitchenInventory: return "Kitchen"
    case .recipe: return "Recipe"
    case .journal: return "Journal"
    }
  }

  /// Deterministic group order for result lists.
  public var sortPriority: Int {
    switch self {
    case .kitchenInventory: return 0
    case .kitchenIngredient: return 1
    case .recipe: return 2
    case .journal: return 3
    }
  }

  public static func < (lhs: SearchRecordKind, rhs: SearchRecordKind) -> Bool {
    lhs.sortPriority < rhs.sortPriority
  }
}

// MARK: - Canonical IDs

/// A canonical, stable identifier for a searchable record.
///
/// Canonical IDs are never stored in the source database and never derived from
/// row indexes: they are the record kind plus the record's own primary key (or
/// the natural key InventoryRepository uses for active items). Anything that
/// opens or mutates a search result must go back through the base repository
/// with this ID and re-validate existence first.
public struct SearchCanonicalID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let kind: SearchRecordKind
  public let rawID: String

  public init(kind: SearchRecordKind, rawID: String) {
    self.kind = kind
    self.rawID = rawID
  }

  public var description: String { "\(kind.rawValue):\(rawID)" }
}

// MARK: - Documents

/// One unit of searchable content, produced by a typed adapter that reads the
/// base repositories. Documents are rebuild-only state: the search index can
/// always be dropped and rebuilt from the source records alone.
public struct SearchDocument: Sendable, Equatable {
  public let canonicalID: SearchCanonicalID
  public let title: String
  public let subtitle: String?
  /// Extra searchable terms: aliases, ingredient names, category labels,
  /// tags. Free text, tokenized like everything else.
  public let keywords: String
  /// Date-shaped searchable terms, e.g. "2026-06-14 2026-06 june 2026 jun".
  public let dateTokens: String
  /// Monotonic-ish content stamp used for stale-revision detection. The exact
  /// meaning is per kind (mtime, cooked-at epoch, content hash); it only
  /// needs to change when the underlying record changes.
  public let revision: Int64

  public init(
    canonicalID: SearchCanonicalID,
    title: String,
    subtitle: String?,
    keywords: String,
    dateTokens: String,
    revision: Int64
  ) {
    self.canonicalID = canonicalID
    self.title = title
    self.subtitle = subtitle
    self.keywords = keywords
    self.dateTokens = dateTokens
    self.revision = revision
  }
}

/// A search result returned by the engine. Carries the canonical ID and the
/// revision the index saw — never a live record. Opening or mutating a hit
/// requires resolving it against the source repositories first.
public struct SearchHit: Sendable, Equatable, Identifiable {
  public var id: String { canonicalID.description }

  public let canonicalID: SearchCanonicalID
  public let title: String
  public let subtitle: String?
  public let revision: Int64
  /// Lower is better (FTS5 bm25 rank); used only for debugging/stable sorts.
  public let rankScore: Double

  public init(
    canonicalID: SearchCanonicalID,
    title: String,
    subtitle: String?,
    revision: Int64,
    rankScore: Double
  ) {
    self.canonicalID = canonicalID
    self.title = title
    self.subtitle = subtitle
    self.revision = revision
    self.rankScore = rankScore
  }
}

// MARK: - Text normalization

public enum SearchText {
  /// Maximum query length accepted by the engine. Longer input is truncated
  /// instead of being fed to FTS5 verbatim.
  public static let maxQueryLength = 200

  /// Case- and diacritic-folds text so queries like "cafe" match "Café"
  /// regardless of tokenizer configuration. Applied to both indexed content
  /// and queries.
  public static func folded(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// Splits folded text into alphanumeric tokens for FTS5 MATCH building.
  public static func tokens(in text: String, limit: Int = 12) -> [String] {
    let folded = folded(text)
    var raw = folded.split(omittingEmptySubsequences: true) { character in
      !(character.isLetter || character.isNumber) && character != "_"
    }
    if raw.count > limit {
      raw = Array(raw.prefix(limit))
    }
    return raw.map { String($0).lowercased() }
  }

  /// FNV-1a 64-bit over UTF-8 bytes: a stable cross-platform content hash for
  /// revision stamps (no seeded hashing randomness).
  public static func stableHash(_ text: String) -> Int64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100000001b3
    }
    return Int64(bitPattern: hash)
  }
}
