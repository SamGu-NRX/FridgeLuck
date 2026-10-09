import Foundation

/// Builds the avoid-ingredient name list handed to recipe generation and
/// screening. Callers work with allergen IDs; this type resolves them to
/// stable, deterministic names.
public enum AllergenAvoidList {
  /// Maps allergen ingredient IDs to ingredient names. Unknown IDs and blank names are
  /// dropped; the result is unique case-insensitively (first spelling kept) and sorted
  /// alphabetically for deterministic prompts.
  ///
  /// Names are trimmed, and sorting ignores case.
  public static func names(forIDs ids: [Int64], idToName: [Int64: String]) -> [String] {
    var seen = Set<String>()
    var resolved: [String] = []
    for id in ids {
      guard let raw = idToName[id] else { continue }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      guard seen.insert(trimmed.lowercased()).inserted else { continue }
      resolved.append(trimmed)
    }
    return resolved.sorted { $0.lowercased() < $1.lowercased() }
  }
}
