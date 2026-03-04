import Foundation
import GRDB

/// Resolves ingredient names against the runtime catalog tables.
/// Returns nil for ambiguous matches so curated fallbacks can take over.
protocol IngredientCatalogResolving: Sendable {
  func resolve(_ rawValue: String) -> Int64?
  func resolveFromText(_ rawText: String) -> Int64?
  func displayName(for ingredientId: Int64) -> String?
}

final class IngredientCatalogResolver: IngredientCatalogResolving, @unchecked Sendable {
  private let db: DatabaseQueue

  init(db: DatabaseQueue) {
    self.db = db
  }

  func resolve(_ rawValue: String) -> Int64? {
    let candidates = Self.normalizedCandidates(for: rawValue)
    guard !candidates.isEmpty else { return nil }

    return try? db.read { db in
      for candidate in candidates {
        if let id = try uniqueNameMatch(in: db, candidate: candidate) {
          return id
        }
      }
      for candidate in candidates {
        if let id = try uniqueAliasMatch(in: db, candidate: candidate) {
          return id
        }
      }
      for candidate in candidates where candidate.count >= 5 {
        if let id = try uniquePrefixNameMatch(in: db, candidate: candidate) {
          return id
        }
      }
      for candidate in candidates where candidate.count >= 5 {
        if let id = try uniquePrefixAliasMatch(in: db, candidate: candidate) {
          return id
        }
      }
      return nil
    }
  }

  func resolveFromText(_ rawText: String) -> Int64? {
    let normalized = Self.normalize(rawText)
    guard !normalized.isEmpty else { return nil }
    let tokens = normalized.split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return nil }

    let maxWindow = min(3, tokens.count)
    for window in stride(from: maxWindow, through: 1, by: -1) {
      for start in 0...(tokens.count - window) {
        let phrase = tokens[start..<(start + window)].joined(separator: " ")
        if let id = resolve(phrase) {
          return id
        }
      }
    }

    return nil
  }

  func displayName(for ingredientId: Int64) -> String? {
    try? db.read { db in
      guard
        let name = try String.fetchOne(
          db,
          sql: "SELECT name FROM ingredients WHERE id = ?",
          arguments: [ingredientId]
        )
      else {
        return nil
      }
      return Self.makeDisplayName(from: name)
    }
  }

  private func uniqueNameMatch(in db: Database, candidate: String) throws -> Int64? {
    let ids = try Int64.fetchAll(
      db,
      sql: """
        SELECT id
        FROM ingredients
        WHERE lower(name) = ?
        LIMIT 2
        """,
      arguments: [candidate]
    )
    return Self.uniqueMatch(from: ids)
  }

  private func uniqueAliasMatch(in db: Database, candidate: String) throws -> Int64? {
    let ids = try Int64.fetchAll(
      db,
      sql: """
        SELECT DISTINCT i.id
        FROM ingredients i
        JOIN ingredient_aliases a ON a.ingredient_id = i.id
        WHERE lower(a.alias) = ?
        LIMIT 2
        """,
      arguments: [candidate]
    )
    return Self.uniqueMatch(from: ids)
  }

  private func uniquePrefixNameMatch(in db: Database, candidate: String) throws -> Int64? {
    let ids = try Int64.fetchAll(
      db,
      sql: """
        SELECT id
        FROM ingredients
        WHERE lower(name) LIKE ?
        LIMIT 2
        """,
      arguments: ["\(candidate)%"]
    )
    return Self.uniqueMatch(from: ids)
  }

  private func uniquePrefixAliasMatch(in db: Database, candidate: String) throws -> Int64? {
    let ids = try Int64.fetchAll(
      db,
      sql: """
        SELECT DISTINCT i.id
        FROM ingredients i
        JOIN ingredient_aliases a ON a.ingredient_id = i.id
        WHERE lower(a.alias) LIKE ?
        LIMIT 2
        """,
      arguments: ["\(candidate)%"]
    )
    return Self.uniqueMatch(from: ids)
  }

  private static func uniqueMatch(from ids: [Int64]) -> Int64? {
    guard ids.count == 1 else { return nil }
    return ids[0]
  }

  private static func normalize(_ raw: String) -> String {
    let lower = raw.lowercased().replacingOccurrences(of: "_", with: " ")
    let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalizedCandidates(for raw: String) -> [String] {
    let base = normalize(raw)
    guard !base.isEmpty else { return [] }

    var candidates: [String] = [base]

    if base.hasSuffix("ies"), base.count > 4 {
      candidates.append(String(base.dropLast(3)) + "y")
    } else if base.hasSuffix("es"), base.count > 3 {
      candidates.append(String(base.dropLast(2)))
    } else if base.hasSuffix("s"), base.count > 2 {
      candidates.append(String(base.dropLast(1)))
    }

    let trimmedLeadingStopWords =
      base
      .replacingOccurrences(
        of: #"^(fresh|raw|cooked|frozen|dried)\s+"#, with: "", options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLeadingStopWords.isEmpty, trimmedLeadingStopWords != base {
      candidates.append(trimmedLeadingStopWords)
    }

    var deduped: [String] = []
    var seen = Set<String>()
    for candidate in candidates {
      if seen.insert(candidate).inserted {
        deduped.append(candidate)
      }
    }
    return deduped
  }

  private static func makeDisplayName(from rawName: String) -> String {
    let normalized = rawName.replacingOccurrences(of: "_", with: " ")
    if normalized == normalized.lowercased() {
      return normalized.localizedCapitalized
    }
    return normalized
  }
}
