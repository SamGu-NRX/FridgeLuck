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
enum RecipeQuarantine {
  struct Entry: Decodable, Equatable {
    struct QuarantinedRecipe: Decodable, Equatable {
      let title: String
    }

    let id: String
    let recipe: QuarantinedRecipe

    /// The data.json recipe id this entry names, for `fl-seed-NNNN` entries.
    var legacyRecipeID: Int64? {
      guard id.hasPrefix("fl-seed-") else { return nil }
      return Int64(id.dropFirst("fl-seed-".count))
    }
  }

  enum LoadError: Error, CustomStringConvertible {
    case missingResource
    case malformedLine(number: Int, underlying: Error)

    var description: String {
      switch self {
      case .missingResource:
        "quarantine.jsonl is not in the app bundle; check project.yml's resources"
      case .malformedLine(let number, let underlying):
        "quarantine.jsonl line \(number) does not decode: \(underlying)"
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
    guard let url = bundle.url(forResource: "quarantine", withExtension: "jsonl") else {
      throw LoadError.missingResource
    }
    return try parse(try Data(contentsOf: url))
  }

  static func parse(_ data: Data) throws -> [Entry] {
    let decoder = JSONDecoder()
    var entries: [Entry] = []
    for (index, line) in String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      do {
        entries.append(try decoder.decode(Entry.self, from: Data(trimmed.utf8)))
      } catch {
        throw LoadError.malformedLine(number: index + 1, underlying: error)
      }
    }
    return entries
  }

  /// Normalized titles of quarantined legacy recipes, keyed the way the bundled loader keys
  /// rows (trimmed, lowercased).
  static func legacyTitleKeys(_ entries: [Entry] = shipped) -> Set<String> {
    Set(
      entries.filter { $0.legacyRecipeID != nil }.map {
        $0.recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      })
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
