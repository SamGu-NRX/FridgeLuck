import Foundation
import FLTaste

/// One candidate the simulator can act on in a session: a feasible recipe,
/// the household's true utility for it, and the contamination terms.
///
/// The simulator computes all three; a ranker sees only what a real ranker
/// could know. `householdUtility` is the latent-truth dot product — Part 3's
/// learning arms will substitute their own score here, which is exactly the
/// point of the protocol: the same interface takes a popularity heuristic or
/// a trained FLTaste engine.
public struct Candidate: Sendable {
    public let recipe: CatalogRecipe
    /// Household-mean latent utility (mean over eaters of `x·theta`).
    public let householdUtility: Double
    /// Pantry stock factor: min over required uses of grams-available /
    /// grams-required (>= 1 for feasible recipes, capped at 2).
    public let availability: Double
    /// How many previous slates showed this recipe (exposure count).
    public let exposureCount: Int

    public init(
        recipe: CatalogRecipe, householdUtility: Double, availability: Double,
        exposureCount: Int
    ) {
        self.recipe = recipe
        self.householdUtility = householdUtility
        self.availability = availability
        self.exposureCount = exposureCount
    }
}

/// Context for one slate proposal. Deliberately thin: a ranker must not see
/// the household's latent vector or the choice model's internals.
public struct RankingContext: Sendable {
    public let week: Int
    public let slateSize: Int
    /// Global cook-session counter; lets seeded rankers give every session
    /// its own random stream instead of repeating within a week.
    public let sessionIndex: Int

    public init(week: Int, slateSize: Int, sessionIndex: Int) {
        self.week = week
        self.slateSize = slateSize
        self.sessionIndex = sessionIndex
    }
}

/// The seam between the simulator and the ranker under test.
///
/// The simulator NEVER implements a learning model: Part 3 injects arms
/// (popularity baseline, rule ranker, FLTaste engine, …) through this
/// protocol and the simulator measures their interaction with the same
/// household world.
///
/// Contract: the returned slate is an ordered subset of the candidates'
/// recipe ids, deduplicated, at most `context.slateSize` entries. The
/// simulator defensively filters violations, but a ranker that breaks the
/// contract is a bug in the ranker, and reference tests hold reference
/// rankers to it.
public protocol Ranker: Sendable {
    /// Stable arm identifier, echoed into the ground truth.
    var id: String { get }
    /// Orders the candidates best-first. The first `slateSize` entries form
    /// the shown slate; the rest is unseen.
    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID]
}

/// Reference ranker 1: uniform random order, drawn from an explicitly
/// seeded stream so the whole simulation stays seed-reproducible.
public struct RandomRanker: Ranker {
    public let id = "random"
    private let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    public func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        var rng = SeededRNG(
            seed: SeedDeriver.child(seed, "ranker", context.week * 1_000_003 + context.sessionIndex)
        )
        // Deterministic Fisher-Yates over ids.
        var ids = candidates.map { $0.recipe.id }
        for i in stride(from: ids.count - 1, to: 0, by: -1) {
            let j = Int(rng.nextUniform() * Double(i + 1))
            ids.swapAt(i, min(j, i))
        }
        return ids
    }
}

/// Reference ranker 2: a rule-based popularity proxy with no learning —
/// quick, short, short-ingredient-list recipes first, ties by id. Popularity
/// here is a fixed heuristic, NOT a model of this household: that is the
/// baseline the learning arms have to beat.
public struct PopularityProxyRanker: Ranker {
    public let id = "popularity-proxy"

    public init() {}

    public func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        candidates
            .sorted { a, b in
                let scoreA = Self.popularityScore(a.recipe)
                let scoreB = Self.popularityScore(b.recipe)
                if scoreA != scoreB { return scoreA > scoreB }
                return a.recipe.id.rawValue < b.recipe.id.rawValue
            }
            .map { $0.recipe.id }
    }

    /// Static appeal proxy in [0, 3]: quick bonus + time bonus + brevity
    /// bonus. Documented in SIM-ASSUMPTIONS.md; sweepable weights are a
    /// Part 3 concern, not the simulator's.
    public static func popularityScore(_ recipe: CatalogRecipe) -> Double {
        var score = 0.0
        if recipe.hasTag(.quick) { score += 1.0 }
        score += max(0, 1.0 - Double(recipe.timeMinutes) / 60.0)
        score += max(0, 1.0 - Double(recipe.requiredIngredients.count) / 6.0)
        return score
    }
}
