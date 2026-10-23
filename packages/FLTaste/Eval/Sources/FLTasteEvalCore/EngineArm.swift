import Foundation
import FLTaste
import FLTasteSim

/// Family 2: Part 1's `TasteEngine` as built — the Bayesian linear-Gaussian
/// model with Thompson sampling, folded from the full behavioral event
/// stream. This is the arm the activation gate is about.
///
/// Variants (the three ablations) tune `TasteConfig`:
/// - `no-exposure-weighting`: `exposureFloor = 1.0` — every observation
///   keeps full weight regardless of shown/feasible (DESIGN.md §2).
/// - `no-recency`: every evidence half-life set to 10^9 days — posterior
///   forgetting and per-class liveness effectively off (DESIGN.md §3).
/// - `no-exploration`: `RankContext.explore = false` at rank time — greedy
///   posterior-mean ranking (DESIGN.md §4).
public struct EngineArmConfig: Sendable {
    var explore = true
    var exposureFloor: Double?
    var disableRecency = false

    public init() {}

    func tasteConfig() -> TasteConfig {
        var config = TasteConfig.standard
        if let floor = exposureFloor { config.exposureFloor = floor }
        if disableRecency {
            config.posteriorHalfLifeDays = 1e9
            config.cookedEvidenceHalfLifeDays = 1e9
            config.savedEvidenceHalfLifeDays = 1e9
            config.openedEvidenceHalfLifeDays = 1e9
            config.viewedEvidenceHalfLifeDays = 1e9
            config.skippedEvidenceHalfLifeDays = 1e9
            config.substitutionEvidenceHalfLifeDays = 1e9
            config.feedbackEvidenceHalfLifeDays = 1e9
            config.repeatAffinityHalfLifeDays = 1e9
        }
        return config
    }
}

final class EngineArmState: ArmState, @unchecked Sendable {
    private var engine: TasteEngine
    private let armConfig: EngineArmConfig
    private let armSeed: UInt64
    private var scores: [RecipeID: Double] = [:]

    init(
        catalog: RecipeCatalog, events: [TasteEvent], armConfig: EngineArmConfig,
        armSeed: UInt64
    ) {
        self.armConfig = armConfig
        self.armSeed = armSeed
        self.engine = TasteEngine(catalog: catalog, config: armConfig.tasteConfig())
        if !events.isEmpty {
            engine.ingest(events)
        }
    }

    func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
        var rng = SeededRNG(
            seed: SeedDeriver.child(
                armSeed, "engine-rank", context.week * 1_000_003 + context.sessionIndex))
        let input = RankInput(
            candidates: candidates.map { $0.id },
            pantryFit: Dictionary(
                uniqueKeysWithValues: candidates.map { candidate in
                    // Stock factor [1, 2] → surplus fraction [0, 1].
                    (candidate.id, min(1.0, max(0.0, candidate.availability - 1.0)))
                }),
            context: RankContext(explore: armConfig.explore))
        let ranked = engine.rank(input, rng: &rng)
        scores = Dictionary(uniqueKeysWithValues: ranked.map { ($0.recipe, $0.score) })
        return ranked.map { $0.recipe }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

/// Shared factory for family 2 and its ablations.
struct EngineArm: ArmFactory {
    let id: String
    let rationale: String
    let family: String
    private let catalog: RecipeCatalog
    private let armConfig: EngineArmConfig

    private init(
        id: String, rationale: String, family: String, catalog: RecipeCatalog,
        armConfig: EngineArmConfig
    ) {
        self.id = id
        self.rationale = rationale
        self.family = family
        self.catalog = catalog
        self.armConfig = armConfig
    }

    /// The as-built engine (family 2 proper).
    static func engine(catalog: RecipeCatalog) -> EngineArm {
        EngineArm(
            id: "engine",
            rationale:
                "Part 1's TasteEngine as built: Bayesian linear-Gaussian posterior, Thompson sampling, exposure weighting, recency half-lives, cold-start blend — the activation-gate subject.",
            family: "family-2", catalog: catalog, armConfig: EngineArmConfig())
    }

    /// Ablation: exposure weighting off.
    static func noExposureWeighting(catalog: RecipeCatalog) -> EngineArm {
        var config = EngineArmConfig()
        config.exposureFloor = 1.0
        return EngineArm(
            id: "engine-no-exposure",
            rationale:
                "Family-2 with exposureFloor = 1.0: behavioral evidence keeps full weight no matter how forced the choice was — isolates the exposure-weighting contribution.",
            family: "ablation", catalog: catalog, armConfig: config)
    }

    /// Ablation: recency/half-life decay off.
    static func noRecency(catalog: RecipeCatalog) -> EngineArm {
        var config = EngineArmConfig()
        config.disableRecency = true
        return EngineArm(
            id: "engine-no-recency",
            rationale:
                "Family-2 with all evidence half-lives at 10^9 days: no posterior forgetting — isolates the recency/drift-handling contribution.",
            family: "ablation", catalog: catalog, armConfig: config)
    }

    /// Ablation: Thompson exploration off.
    static func noExploration(catalog: RecipeCatalog) -> EngineArm {
        var config = EngineArmConfig()
        config.explore = false
        return EngineArm(
            id: "engine-no-exploration",
            rationale:
                "Family-2 ranked greedily (explore: false): no Thompson draws — isolates what deliberate variety buys.",
            family: "ablation", catalog: catalog, armConfig: config)
    }

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        EngineArmState(catalog: catalog, events: events, armConfig: armConfig, armSeed: armSeed)
    }
}
