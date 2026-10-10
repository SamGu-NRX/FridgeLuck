import Foundation

/// Shared deterministic scoring shape for catalog binding: token overlap over the
/// smaller of the two token sets, thresholded. The app's ingredient-catalog resolver and
/// the offline evaluation resolver both use it, so "ambiguous" means the same thing on
/// the device and in the evaluation. Order ties by caller (score desc, id asc).
public enum CatalogScoring {
  public static let suggestionThreshold = 0.3

  /// Lowercased alphanumeric tokens longer than one character (drops "x", "2", "%").
  public static func tokens(in text: String) -> Set<String> {
    let lowered = text.lowercased()
    return Set(
      lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    ).filter { $0.count > 1 }
  }

  /// Overlap over the smaller set — a long product name against a short catalog name
  /// still needs to match most of the catalog name's tokens. `nil` is "no suggestion".
  public static func score(query: Set<String>, target: Set<String>) -> Double? {
    guard !query.isEmpty, !target.isEmpty else { return nil }
    let overlap = Double(query.intersection(target).count)
    let smaller = Double(min(query.count, target.count))
    let score = overlap / smaller
    return score >= suggestionThreshold ? score : nil
  }
}
