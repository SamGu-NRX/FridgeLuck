import Foundation
import FLTaste

/// Internal truth carrier for the choice model: the recipe, the
/// household's TRUE mean utility, and the contamination terms. This type
/// never reaches a ranker — it exists only between the simulator's
/// truth computation and `ChoiceModel`, and its contents are exported to
/// the ground-truth layer (PR #105 review blocker 1: keep truth inside
/// the choice/scoring code).
struct ChoiceCandidate: Sendable {
    let recipe: CatalogRecipe
    /// Household-mean latent utility (mean over eaters of `x·theta`).
    let utility: Double
    let availability: Double
    let exposureCount: Int
}

/// The household's choice process: softmax over a contaminated score.
///
/// The score is true utility plus three contamination terms (position,
/// mere exposure, pantry availability). All three are things a scorer can
/// subtract later because the ground truth records them per session; they
/// are also why "picked what was shown" is weaker evidence of taste than a
/// pick from real variety (SPEC 3.3).
public enum ChoiceModel {

    /// The contaminated score of one slate candidate.
    ///
    /// `score = utility/T + availabilityWeight*log(availability)
    ///          + exposureWeight*log(1 + exposureCount)
    ///          + positionBias * (slateCount - position)`
    ///
    /// (The 1/T scaling lives on utility only; the contamination terms are
    /// additive bonuses in the same units, so `choiceTemperature` tunes how
    /// taste-driven versus contaminated the pick is — lower T, more taste.)
    public static func score(
        utility: Double, availability: Double, exposureCount: Int, position: Int,
        slateCount: Int, config: SimConfig
    ) -> Double {
        let taste = utility / config.choiceTemperature
        let availabilityTerm = config.availabilityWeight * log(max(1.0, availability))
        let exposureTerm = config.exposureWeight * log(Double(1 + exposureCount))
        let positionTerm = config.positionBias * Double(max(0, slateCount - position))
        return taste + availabilityTerm + exposureTerm + positionTerm
    }

    /// Choice probabilities over an ordered slate, in slate order.
    /// Normalized; every entry strictly positive. Internal: the choice
    /// layer is the simulator's truth side, not part of the public seam.
    static func probabilities(
        slate: [ChoiceCandidate], config: SimConfig
    ) -> [Double] {
        guard !slate.isEmpty else { return [] }
        let scores = slate.enumerated().map { index, candidate in
            score(
                utility: candidate.utility, availability: candidate.availability,
                exposureCount: candidate.exposureCount, position: index,
                slateCount: slate.count, config: config)
        }
        let ceiling = scores.max()!
        let weights = scores.map { exp($0 - ceiling) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    /// Samples a slate index from choice probabilities. The draw order is
    /// one uniform per call.
    public static func sample(_ probabilities: [Double], _ rng: inout SeededRNG) -> Int {
        let draw = rng.nextUniform()
        var cumulative = 0.0
        for (index, p) in probabilities.enumerated() {
            cumulative += p
            if draw < cumulative { return index }
        }
        return probabilities.count - 1  // float safety; draw was within [0, 1)
    }
}
