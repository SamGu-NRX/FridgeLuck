import Foundation
import FLTaste
import FLTasteSim

// The suite-B campaign: households × regimes × seeds × arms, scored against
// the simulator's hidden ground truth. Deterministic end to end: given the
// same config, the same bytes come out. Long runs checkpoint per (seed, arm)
// and resume by skipping complete checkpoints.

public struct CampaignConfig: Codable, Sendable {
    public var householdsPerSeed: Int
    public var seeds: [UInt64]
    /// Nil selects all registered arms.
    public var armIDs: [String]?
    public var bootstrapResamples: Int
    /// Worker threads for household-level parallelism (sandbox has 2 cores).
    public var workers: Int
    public var weeks: Int

    /// The smoke campaign the test suite runs end to end.
    public static func smoke() -> CampaignConfig {
        CampaignConfig(
            householdsPerSeed: 50, seeds: [101, 102], armIDs: nil,
            bootstrapResamples: 200, workers: 2, weeks: 8)
    }

    /// The full preregistered campaign.
    public static func full() -> CampaignConfig {
        CampaignConfig(
            householdsPerSeed: 5_000,
            seeds: (0..<20).map { SeedDeriver.child(2026, "campaign-seed", $0) },
            armIDs: nil, bootstrapResamples: 10_000, workers: 2, weeks: 13)
    }

    public init(
        householdsPerSeed: Int, seeds: [UInt64], armIDs: [String]?,
        bootstrapResamples: Int, workers: Int, weeks: Int
    ) {
        self.householdsPerSeed = householdsPerSeed
        self.seeds = seeds
        self.armIDs = armIDs
        self.bootstrapResamples = bootstrapResamples
        self.workers = workers
        self.weeks = weeks
    }
}

// MARK: - Regimes

/// The six regimes of suite B, assigned round-robin by household index so
/// every arm sees the same mix. Knobs follow SIM-ASSUMPTIONS.md's sweep
/// guidance: the defaults are [F8]/[F5]-anchored, and regimes move exactly
/// one knob family at a time.
public enum Regimes {
    public static let names = [
        "baseline", "sparse-feedback", "slow-drift", "two-eater", "abrupt-shift",
        "exposure-bias",
    ]

    /// Vegetarian shift landing late enough that arms have history to unlearn.
    static let shiftWeek = 8

    public static func config(seed: UInt64, householdIndex: Int, weeks: Int) -> (SimConfig, String) {
        var config = SimConfig()
        config.seed = SeedDeriver.child(seed, "household", householdIndex)
        config.weeks = weeks
        let regime = householdIndex % names.count
        let name = names[regime]
        // One- and two-eater households alternate per regime cycle outside
        // the two-eater regime (which is always two).
        let size = householdSize(name: name, householdIndex: householdIndex)
        config.householdSize = size
        switch name {
        case "baseline":
            config.shifts = [.diet(eaterIndex: 0, diet: .vegetarian, week: shiftWeek)]
        case "sparse-feedback":
            config.cooksPerWeek = 1.2
            config.ratingProbability = 0.2
            config.attentionProbability = 0.6
            config.saveProbability = 0.06
            config.shifts = [.diet(eaterIndex: 0, diet: .vegetarian, week: shiftWeek)]
        case "slow-drift":
            config.driftPerWeek = 0.06  // 3x default rotation; no shifts
        case "two-eater":
            config.shifts = [.diet(eaterIndex: 0, diet: .vegetarian, week: shiftWeek)]
        case "abrupt-shift":
            // Earlier, so it lands with less history and hits harder.
            config.shifts = [.diet(eaterIndex: 0, diet: .vegetarian, week: 5)]
        case "exposure-bias":
            // Only 5 of ~20+ feasible shown: strong partial exposure.
            config.slateSize = 5
            config.positionBias = 0.4
            config.shifts = [.diet(eaterIndex: 0, diet: .vegetarian, week: shiftWeek)]
        default:
            break
        }
        return (config, name)
    }

    private static func householdSize(name: String, householdIndex: Int) -> Int {
        if name == "two-eater" { return 2 }
        return 1 + ((householdIndex / names.count) % 2)
    }
}

// MARK: - Run capture

/// Collects the arm's full ordering per rank call. The simulator is
/// single-threaded within one run, so plain mutation is safe.
final class RankLog: @unchecked Sendable {
    var entries: [(week: Int, ordered: [RecipeID])] = []
}

/// The versioned ranker with capture, for the campaign harness.
struct CapturingRanker: Ranker {
    let armID: String
    let states: [any ArmState]
    let log: RankLog

    var id: String { armID }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        let index = min(context.week, states.count - 1)
        let ordered = states[index].rank(candidates, context: context)
        log.entries.append((context.week, ordered))
        return ordered
    }
}

public enum Campaign {
    /// Runs one arm over one household: staged weekly replay for learning
    /// arms, single run for stateless arms. Returns metrics plus the regime.
    ///
    /// Staging induction: stage k ranks weeks 0...k with states[0...k], where
    /// states[w] is folded from the accumulated weeks 0..<w events. Weeks
    /// below k rank with the same state objects stage k-1 used and draw from
    /// the same seeded streams, so every stage reproduces its predecessors
    /// exactly; the final stage's run IS the weekly-continual trajectory.
    public static func runHousehold(
        arm: any ArmFactory, config: SimConfig, regime: String, catalog: RecipeCatalog,
        householdSeed: UInt64, armSeed: UInt64
    ) -> (HouseholdMetrics, String) {
        let weeks = config.weeks
        var accumulated: [TasteEvent] = []
        var finalRun: HouseholdSimulator.Run?
        var finalLog = RankLog()
        let weekMillis: Int64 = 7 * 24 * 3_600 * 1_000

        if arm.isStateless {
            // One run with one frozen state.
            let state = arm.make(events: [], householdSeed: householdSeed, armSeed: armSeed)
            let log = RankLog()
            finalRun = HouseholdSimulator(
                config: config, catalog: catalog,
                ranker: CapturingRanker(armID: arm.id, states: [state], log: log)
            ).run()
            finalLog = log
        } else {
            var states: [any ArmState] = []
            for week in 0..<weeks {
                states.append(
                    arm.make(events: accumulated, householdSeed: householdSeed, armSeed: armSeed))
                var stageConfig = config
                stageConfig.weeks = week + 1
                let stageLog = RankLog()
                let stageRun = HouseholdSimulator(
                    config: stageConfig, catalog: catalog,
                    ranker: CapturingRanker(armID: arm.id, states: states, log: stageLog)
                ).run()
                if week == weeks - 1 {
                    finalRun = stageRun
                    finalLog = stageLog
                    break
                }
                let weekEvents = stageRun.events.filter {
                    ($0.at.millisecondsSinceEpoch - stageConfig.startMillis) / weekMillis
                        == Int64(week)
                }
                accumulated.append(contentsOf: weekEvents)
            }
        }

        guard let run = finalRun else {
            fatalError("campaign staging produced no final run")
        }
        let metrics = scoreHousehold(groundTruth: run.groundTruth, rankLog: finalLog.entries)
        return (metrics, regime)
    }
}
