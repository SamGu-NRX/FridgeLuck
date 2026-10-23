import Foundation
import FLDomain

// MARK: - Explore ranking: cookability first, taste as a household lens
// SPEC suite E: Explore's catalog is cookability-ranked. Hard allergen and
// dietary restrictions filter candidates BEFORE ranking and cannot be
// weakened by learned preferences — so this ranker receives already-filtered
// candidates and never sees restriction state at all. Taste is injected per
// candidate (the on-device taste engine owns it; taste data never leaves the
// phone). There is no popularity signal here by design: a young community
// must not become a self-reinforcing leaderboard, and none of the inputs
// encode who else cooked what.

/// One Explore candidate with its injected signals.
///
/// `fit` is the cookability score the host computed for this household's
/// pantry and constraints (0...1, required — cookability is the catalog's
/// core sort). `taste` is the on-device taste signal (0...1); nil is the
/// cold start and scores at the neutral prior.
public struct ExploreCandidate: Hashable, Sendable {
    /// The candidate revision. Carried as-is into the rank entry.
    public let revision: RecipeRevision
    /// Cookability for this household, 0...1.
    public let fit: Double
    /// On-device taste signal, 0...1, or nil before the household has
    /// enough history.
    public let taste: Double?

    public init(revision: RecipeRevision, fit: Double, taste: Double? = nil) throws {
        guard (0.0...1.0).contains(fit) else {
            throw FLDomainError.validation(
                target: "ExploreCandidate.fit",
                reason: "must be in 0...1 (got \(fit))"
            )
        }
        if let taste, !(0.0...1.0).contains(taste) {
            throw FLDomainError.validation(
                target: "ExploreCandidate.taste",
                reason: "must be in 0...1 or nil (got \(taste))"
            )
        }
        self.revision = revision
        self.fit = fit
        self.taste = taste
    }
}

/// How fit and taste combine. Each weight is 0...1 and their sum must be
/// positive; the default leans fit-first per the spec's cookability ranking.
public struct ExploreRankWeights: Hashable, Sendable {
    public static let `default` = ExploreRankWeights(fit: 0.6, taste: 0.4)!

    public let fit: Double
    public let taste: Double

    public init?(fit: Double, taste: Double) {
        guard (0.0...1.0).contains(fit), (0.0...1.0).contains(taste) else { return nil }
        guard fit + taste > 0 else { return nil }
        self.fit = fit
        self.taste = taste
    }

    /// Throwing construction for callers that want the reason, not just nil.
    public static func validated(fit: Double, taste: Double) throws -> ExploreRankWeights {
        guard let weights = ExploreRankWeights(fit: fit, taste: taste) else {
            throw FLDomainError.validation(
                target: "ExploreRankWeights",
                reason: "weights must each be in 0...1 with a positive sum (got fit \(fit), taste \(taste))"
            )
        }
        return weights
    }
}

/// One candidate's ranked result: the combined score, its components, and a
/// deterministic, human-readable explanation of where the score came from.
public struct ExploreRankEntry: Hashable, Sendable {
    public let candidate: ExploreCandidate
    /// The fit contribution to the score.
    public let fitComponent: Double
    /// The taste contribution — the neutral prior stands in for a missing
    /// household signal.
    public let tasteComponent: Double
    /// The combined score, rounded to six decimals for cross-platform
    /// reproduction.
    public let score: Double
    /// Ordered explanation lines, one per component plus the combination.
    public let explanation: [String]
}

/// The pure, deterministic Explore ranker.
public enum ExploreRanking {
    /// The taste score a cold-start household gets: no signal, no penalty,
    /// no boost.
    public static let neutralTastePrior: Double = 0.5

    /// Ranks candidates: combined score descending, with stable, explained
    /// tie-breakers (fit, then taste component, then title, then key) so the
    /// same catalog always ranks identically.
    ///
    /// Duplicate keys in the catalog are a caller error and throw — a catalog
    /// that lists one revision twice does not have a defined rank for it.
    public static func rank(
        candidates: [ExploreCandidate],
        weights: ExploreRankWeights = .default
    ) throws -> [ExploreRankEntry] {
        var seenKeys = Set<RecipeKey>()
        for candidate in candidates {
            guard seenKeys.insert(candidate.revision.key).inserted else {
                throw FLDomainError.validation(
                    target: "ExploreRanking.candidates",
                    reason: "duplicate candidate key \(candidate.revision.key)"
                )
            }
        }

        func score(_ candidate: ExploreCandidate) -> (fit: Double, taste: Double, total: Double) {
            let tasteComponent = weights.taste * (candidate.taste ?? neutralTastePrior)
            let fitComponent = weights.fit * candidate.fit
            // Rounded so the same inputs produce the same rank on every host.
            return (fitComponent, tasteComponent, (fitComponent + tasteComponent * 1.0).rounded(toPlaces: 6))
        }

        func explanation(_ candidate: ExploreCandidate, _ s: (fit: Double, taste: Double, total: Double)) -> [String] {
            [
                String(format: "cookability %.3f × %.3f", candidate.fit, weights.fit),
                candidate.taste.map {
                    String(format: "taste %.3f × %.3f (household signal)", $0, weights.taste)
                } ?? String(format: "taste %.3f × %.3f (neutral prior)", neutralTastePrior, weights.taste),
                String(format: "combined %.6f", s.total),
            ]
        }

        let entries = candidates.map { candidate -> ExploreRankEntry in
            let s = score(candidate)
            return ExploreRankEntry(
                candidate: candidate,
                fitComponent: s.fit,
                tasteComponent: s.taste,
                score: s.total,
                explanation: explanation(candidate, s)
            )
        }

        return entries.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.fitComponent != b.fitComponent { return a.fitComponent > b.fitComponent }
            if a.tasteComponent != b.tasteComponent { return a.tasteComponent > b.tasteComponent }
            let aTitle = a.candidate.revision.title
            let bTitle = b.candidate.revision.title
            if aTitle != bTitle { return aTitle < bTitle }
            return a.candidate.revision.key.description < b.candidate.revision.key.description
        }
    }
}

extension Double {
    /// Rounds to `places` decimal places (for score reproduction).
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
