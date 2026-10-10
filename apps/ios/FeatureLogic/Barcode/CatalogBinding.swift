import Foundation

/// A food the product could resolve to, scored by the injected resolver. Scores are the
/// resolver's own confidence (0...1); the binder only classifies, it never rescores.
public struct CatalogCandidate: Sendable, Equatable, Hashable {
  public let id: Int64
  public let name: String
  public let score: Double

  public init(id: Int64, name: String, score: Double) {
    self.id = id
    self.name = name
    self.score = score
  }
}

/// What a barcode product resolved to in the ingredient catalog. Ambiguity is a
/// first-class outcome — two near-tied candidates are shown to the user, never guessed.
public enum CatalogBinding: Sendable, Equatable {
  /// A clear winner: the top candidate clears `minScore` by `minSeparation`.
  case bound(id: Int64, name: String, score: Double)
  /// Two or more plausible foods — the review asks which one this is.
  case ambiguous(candidates: [CatalogCandidate])
  /// Nothing in the catalog matched well enough to offer.
  case unbound
}

/// Supplies catalog candidates for a barcode product's name/brand text. The app glues
/// its lexicon and catalog search here; the offline evaluation uses a deterministic
/// token matcher over a frozen catalog slice.
public protocol BarcodeCatalogResolver: Sendable {
  func candidates(for productName: String?, brands: String?) -> [CatalogCandidate]
}

/// Classifies resolver output into bound / ambiguous / unbound.
///
/// A candidate binds only when it is clearly best: at least `minScore`, and ahead of the
/// runner-up by at least `minSeparation`. Weak candidates are not a guess — they stay
/// `unbound` so the user picks identity explicitly.
public enum CatalogBinder {
  public static let minScore = 0.8
  public static let minSeparation = 0.08

  /// Candidates are sorted best-first internally (ties broken by id, so the same input
  /// always binds the same way); the incoming order never changes the outcome.
  public static func bind(
    _ candidates: [CatalogCandidate],
    minScore: Double = CatalogBinder.minScore,
    minSeparation: Double = CatalogBinder.minSeparation
  ) -> CatalogBinding {
    let ranked = candidates.sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.id < $1.id
    }

    guard let best = ranked.first, best.score >= minScore else { return .unbound }

    if ranked.count > 1, best.score - ranked[1].score < minSeparation {
      return .ambiguous(candidates: ranked)
    }
    return .bound(id: best.id, name: best.name, score: best.score)
  }
}
