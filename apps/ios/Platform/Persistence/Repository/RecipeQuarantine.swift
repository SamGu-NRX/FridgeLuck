import Foundation

/// Recipes FridgeLuck may not offer, read from `data/recipes/quarantine.jsonl`, which the app
/// bundles unchanged (project.yml) so the recipe audit's list is the only source.
///
/// The catalog pool needs nothing from this: the bundle compiler leaves quarantined recipes
/// out of recipes-v2.json, and the catalog search admits only `rights_status = 'original'`.
/// The legacy pool (data.json) predates the audit. Its rows carry no rights status, so the
/// Home hero kept offering "Classic Egg Fried Rice" (legacy id 1, quarantined as
/// `fl-seed-0001` on 2026-10-11). Entry `fl-seed-NNNN` is the legacy recipe with id NNNN
/// (data/recipes/tools/convert_bundled.py names them that way).
///
/// Legacy rows are matched by bundled source and title, not id: an install hydrated by
/// `BundledDataLoader.ensureBundledRecipesHydrated` gets auto-assigned ids and keys rows by
/// normalized title.
///
/// Other hide lists join through `hideListResources`: bundle the file in project.yml and add
/// its name. A line that decodes as neither list's shape stops the app at launch.
enum RecipeQuarantine {
  /// Bundled `.jsonl` hide lists, by resource name. Every legacy recipe they name is hidden.
  /// `legacy-audit` is data/recipes/legacy-audit.jsonl: one line per legacy recipe, hidden
  /// when its verdict is "hide" (missing or wrong ingredient lines, rights quarantine).
  static let hideListResources = ["quarantine", "legacy-audit"]

  struct Entry: Equatable {
    let id: String
    let title: String
    /// The data.json recipe id this entry names, when it names one.
    let legacyRecipeID: Int64?
  }

  /// A quarantine.jsonl line.
  private struct QuarantineLine: Decodable {
    struct Recipe: Decodable { let title: String }
    let id: String
    let recipe: Recipe
  }

  /// A legacy-audit.jsonl line.
  private struct AuditLine: Decodable {
    let legacyId: Int64
    let title: String
    let verdict: String

    enum CodingKeys: String, CodingKey {
      case legacyId = "legacy_id"
      case title, verdict
    }
  }

  enum LoadError: Error, CustomStringConvertible {
    case missingResource(String)
    case malformedLine(resource: String, number: Int, underlying: Error)

    var description: String {
      switch self {
      case .missingResource(let name):
        "\(name).jsonl is not in the app bundle; check project.yml's resources"
      case .malformedLine(let name, let number, let underlying):
        "\(name).jsonl line \(number) does not decode: \(underlying)"
      }
    }
  }

  /// The shipped list. A missing or malformed file stops the app: offering recipes without the
  /// list would offer quarantined ones.
  static let shipped: [Entry] = {
    do {
      return try load(from: .main)
    } catch {
      preconditionFailure("RecipeQuarantine: \(error)")
    }
  }()

  static func load(from bundle: Bundle) throws -> [Entry] {
    try hideListResources.flatMap { name in
      guard let url = bundle.url(forResource: name, withExtension: "jsonl") else {
        throw LoadError.missingResource(name)
      }
      return try parse(try Data(contentsOf: url), resource: name)
    }
  }

  static func parse(_ data: Data, resource: String) throws -> [Entry] {
    let decoder = JSONDecoder()
    var entries: [Entry] = []
    for (index, line) in String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      let lineData = Data(trimmed.utf8)
      if let quarantined = try? decoder.decode(QuarantineLine.self, from: lineData) {
        // Entry `fl-seed-NNNN` is the legacy recipe with id NNNN.
        let legacyID =
          quarantined.id.hasPrefix("fl-seed-")
          ? Int64(quarantined.id.dropFirst("fl-seed-".count)) : nil
        entries.append(
          Entry(id: quarantined.id, title: quarantined.recipe.title, legacyRecipeID: legacyID))
        continue
      }
      do {
        let audited = try decoder.decode(AuditLine.self, from: lineData)
        guard audited.verdict == "hide" else { continue }
        entries.append(
          Entry(
            id: "legacy-\(audited.legacyId)", title: audited.title,
            legacyRecipeID: audited.legacyId))
      } catch {
        throw LoadError.malformedLine(resource: resource, number: index + 1, underlying: error)
      }
    }
    return entries
  }

  /// Normalized titles of every listed recipe, keyed the way the bundled loader keys rows
  /// (trimmed, lowercased). Entries that aren't legacy seeds are included too: the exclusion
  /// only touches bundled legacy rows, and a test checks none of those carries such a title.
  static func legacyTitleKeys(_ entries: [Entry] = shipped) -> Set<String> {
    Set(entries.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
  }

  /// SQL predicate, true for every `recipes` row that may be offered. `alias` names the
  /// recipes table in the surrounding query, or nil when unaliased.
  static func legacyExclusionSQL(alias: String?) -> String {
    let keys = legacyTitleKeys()
    guard !keys.isEmpty else { return "1" }
    let prefix = alias.map { "\($0)." } ?? ""
    let list = keys.sorted()
      .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
      .joined(separator: ", ")
    return "NOT (\(prefix)source = 'bundled' AND LOWER(TRIM(\(prefix)title)) IN (\(list)))"
  }
}
