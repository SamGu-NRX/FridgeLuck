import Foundation

/// Resolves the identity a screen passes in — a Home recommendation card, a demo
/// scenario, a replay — to the exact scored result to auto-present. Catalog entries
/// carry no legacy row, so matching runs on the scored identity
/// (`ScoredRecipeID`), never on list order or the integer column alone.
enum PreferredRecipeResolver {
  /// The first result whose scored identity matches, keeping list order for ties.
  static func resolve(
    preferredID: ScoredRecipeID?,
    in recommendations: [ScoredRecipe]
  ) -> ScoredRecipe? {
    guard let preferredID else { return nil }
    return recommendations.first { $0.id == preferredID }
  }
}
