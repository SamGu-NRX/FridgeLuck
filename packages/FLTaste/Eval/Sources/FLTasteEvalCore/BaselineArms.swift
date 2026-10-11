import Foundation
import FLTaste
import FLTasteSim

/// Wraps the simulator's own popularity reference ranker as an arm.
/// Rationale: the fixed appeal proxy (quick/short/brief recipes first) —
/// what a surface without taste or learning would ship.
final class PopularityArmState: ArmState, @unchecked Sendable {
    private let inner = PopularityProxyRanker()
    private var scores: [RecipeID: Double] = [:]

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(
            uniqueKeysWithValues: candidates.map {
                ($0.recipe.id, PopularityProxyRanker.popularityScore($0.recipe))
            })
        return inner.rank(candidates, context: context)
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct PopularityArm: ArmFactory {
    public let id = "popularity"
    public let rationale =
        "Sim's fixed appeal proxy (quick, short, brief) — a no-taste, no-learning surface."
    public let family = "baseline"
    public let isStateless = true

    public init() {}

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        PopularityArmState()
    }
}

/// Wraps the simulator's seeded random reference ranker as an arm.
/// Rationale: the floor — any arm below random is broken by definition.
final class RandomArmState: ArmState, @unchecked Sendable {
    private let inner: RandomRanker
    private var scores: [RecipeID: Double] = [:]

    init(seed: UInt64) {
        inner = RandomRanker(seed: seed)
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        let ids = inner.rank(candidates, context: context)
        // Position-derived pseudo-scores keep the calibration path uniform:
        // rank position 0 → highest score.
        scores = [:]
        for (position, id) in ids.enumerated() {
            scores[id] = -Double(position)
        }
        return ids
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct RandomArm: ArmFactory {
    public let id = "random"
    public let rationale =
        "Sim's seeded uniform random reference — the sanity floor for every other arm."
    public let family = "baseline"
    public let isStateless = true

    public init() {}

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        // Rank draws must not collide across arms or households.
        RandomArmState(seed: SeedDeriver.child(armSeed, "random-rank", Int(householdSeed % 1_000_003)))
    }
}

/// Explicit-profile-only: the engine folded over explicit profile edits
/// ONLY (restrictions, never-suggest, stated preferences) — behavioral
/// events are dropped, so nothing is ever learned from cooking.
/// Rationale: the app with taste profiles but no learning — the second bar
/// the activation gate names. Ranking is the engine's cold-start blend:
/// the rule baseline plus popularity and pantry fit, greedy (no draws).
final class ProfileOnlyArmState: ArmState, @unchecked Sendable {
    private var engine: TasteEngine
    private let armSeed: UInt64
    private var scores: [RecipeID: Double] = [:]

    init(catalog: RecipeCatalog, events: [TasteEvent], armSeed: UInt64) {
        self.armSeed = armSeed
        self.engine = TasteEngine(catalog: catalog)
        // Only explicit edits reach the profile layer; every behavioral
        // event class is filtered out so no learning signal survives.
        // Corrections are kept: they amend explicit edits, not behavior.
        let explicit = events.filter { event in
            switch event.kind {
            case .profileEdit, .correction: return true
            default: return false
            }
        }
        if !explicit.isEmpty {
            engine.ingest(explicit)
        }
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        var rng = SeededRNG(
            seed: SeedDeriver.child(
                armSeed, "profile-rank", context.week * 1_000_003 + context.sessionIndex))
        let input = RankInput(
            candidates: candidates.map { $0.recipe.id },
            pantryFit: Dictionary(
                uniqueKeysWithValues: candidates.map { candidate in
                    // Candidate.availability is a stock factor in [1, 2]
                    // (min required-grams coverage, capped); fit maps the
                    // surplus half into [0, 1].
                    (candidate.recipe.id, min(1.0, max(0.0, candidate.availability - 1.0)))
                }),
            context: RankContext(explore: false))
        let ranked = engine.rank(input, rng: &rng)
        scores = Dictionary(uniqueKeysWithValues: ranked.map { ($0.recipe, $0.score) })
        return ranked.map { $0.recipe }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

public struct ProfileOnlyArm: ArmFactory {
    public let id = "profile-only"
    public let rationale =
        "Explicit profile edits only (restrictions, never-suggest, stated prefs), no behavioral learning — the second activation bar."
    public let family = "baseline"
    private let catalog: RecipeCatalog

    init(catalog: RecipeCatalog) {
        self.catalog = catalog
    }

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        ProfileOnlyArmState(catalog: catalog, events: events, armSeed: armSeed)
    }
}
