import Foundation
import FLTaste

/// One candidate as the ranker under test sees it: a feasible recipe
/// reduced to its **observable projection**, plus the two exposure terms
/// the app itself produces.
///
/// The projection deliberately excludes every channel latent taste can
/// hide in: no recipe title, no ingredient identities, no instructions
/// (the source of `technique.*` features), no nutrition. A rule ranker
/// sees coarse structure — tags, time, servings, list sizes — exactly
/// what a production rule port consumes. Latent utilities are NEVER on
/// this type: truth lives in the choice/scoring layer (`ChoiceCandidate`)
/// and in the ground-truth export (PR #105 review blocker 1). The
/// guarantee is proven by `testRankerSeesNoLatentDataEvenUnderReflection`
/// and `testRankerCandidateProjectionExcludesRecipeInternals`.
public struct RankerCandidate: Sendable, Equatable {
    public let id: RecipeID
    /// All set tags in `CatalogTag.featureValue` form, sorted.
    public let tagNames: [String]
    public let timeMinutes: Int
    public let servings: Int
    public let requiredIngredientCount: Int
    public let optionalIngredientCount: Int
    /// Pantry stock factor: min over required uses of stock/required
    /// (capped at 2, >= 1 on the feasible set).
    public let availability: Double
    /// How many previous slates showed this recipe.
    public let exposureCount: Int

    init(recipe: CatalogRecipe, availability: Double, exposureCount: Int) {
        self.id = recipe.id
        self.tagNames =
            CatalogTag.allCases.filter { recipe.hasTag($0) }.map(\.featureValue).sorted()
        self.timeMinutes = recipe.timeMinutes
        self.servings = recipe.servings
        self.requiredIngredientCount = recipe.requiredIngredients.count
        self.optionalIngredientCount = recipe.optionalIngredients.count
        self.availability = availability
        self.exposureCount = exposureCount
    }
}

/// Context for one slate proposal: when, how big, and the **observable
/// history** — the exact event stream the app has recorded so far (a
/// value copy; later sessions never mutate what an earlier ranker saw),
/// plus the household's declared restrictions (profile data the app
/// holds). Learning arms ingest `history` with Part 1's `TasteEngine`.
/// Like `RankerCandidate`, this type carries no latent data — its
/// initializer takes nothing a ranker could read truth from.
public struct RankingContext: Sendable {
    public let week: Int
    public let slateSize: Int
    /// Global cook-session counter; lets seeded rankers give every session
    /// its own random stream instead of repeating within a week.
    public let sessionIndex: Int
    public let history: [TasteEvent]
    public let restrictions: [Restriction]

    public init(
        week: Int, slateSize: Int, sessionIndex: Int, history: [TasteEvent],
        restrictions: [Restriction]
    ) {
        self.week = week
        self.slateSize = slateSize
        self.sessionIndex = sessionIndex
        self.history = history
        self.restrictions = restrictions
    }
}

/// The single funnel from simulator state to ranker-visible input.
///
/// Every ranker call goes through `candidates(for:)`; its signature takes
/// only observable state — there is no parameter that could carry latent
/// utilities, latent vectors, rater biases, or rating noise. The
/// household's true utilities are computed by the simulator for the
/// choice model and ground truth, and never cross this seam.
public enum RankerInput {
    public static func candidates(
        for feasible: [CatalogRecipe], availability: [String: Double],
        exposureCounts: [RecipeID: Int]
    ) -> [RankerCandidate] {
        feasible.map {
            RankerCandidate(
                recipe: $0, availability: availability[$0.id.rawValue] ?? 1,
                exposureCount: exposureCounts[$0.id] ?? 0)
        }
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
/// simulator defensively filters violations (`HouseholdSimulator.slate`)
/// — out-of-set and infeasible ids are dropped, never trusted — but a
/// ranker that breaks the contract is a bug in the ranker, and reference
/// tests hold reference rankers to it.
public protocol Ranker: Sendable {
    /// Stable arm identifier, echoed into the ground truth.
    var id: String { get }
    /// Orders the candidates best-first. The first `slateSize` entries form
    /// the shown slate; the rest is unseen.
    func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID]
}

/// Reference ranker 1: uniform random order, drawn from an explicitly
/// seeded stream so the whole simulation stays seed-reproducible.
public struct RandomRanker: Ranker {
    public let id = "random"
    private let seed: UInt64

    public init(seed: UInt64) {
        self.seed = seed
    }

    public func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
        var rng = SeededRNG(
            seed: SeedDeriver.child(seed, "ranker", context.week * 1_000_003 + context.sessionIndex)
        )
        // Deterministic Fisher-Yates over ids.
        var ids = candidates.map { $0.id }
        for i in stride(from: ids.count - 1, to: 0, by: -1) {
            let j = Int(rng.nextUniform() * Double(i + 1))
            ids.swapAt(i, min(j, i))
        }
        return ids
    }
}

/// Reference ranker 2: a rule-based popularity proxy with no learning —
/// quick, short, short-ingredient-list recipes first, ties by id. It
/// consumes ONLY the seam's visible projection. Popularity here is a
/// fixed heuristic, NOT a model of this household: that is the baseline
/// the learning arms have to beat.
public struct PopularityProxyRanker: Ranker {
    public let id = "popularity-proxy"

    public init() {}

    public func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
        candidates
            .sorted { a, b in
                let scoreA = Self.popularityScore(a)
                let scoreB = Self.popularityScore(b)
                if scoreA != scoreB { return scoreA > scoreB }
                return a.id.rawValue < b.id.rawValue
            }
            .map { $0.id }
    }

    /// Static appeal proxy in [0, 3]: quick bonus + time bonus + brevity
    /// bonus. Documented in SIM-ASSUMPTIONS.md; sweepable weights are a
    /// Part 3 concern, not the simulator's.
    public static func popularityScore(_ candidate: RankerCandidate) -> Double {
        var score = 0.0
        if candidate.tagNames.contains(CatalogTag.quick.featureValue) { score += 1.0 }
        score += max(0, 1.0 - Double(candidate.timeMinutes) / 60.0)
        score += max(0, 1.0 - Double(candidate.requiredIngredientCount) / 6.0)
        return score
    }
}
