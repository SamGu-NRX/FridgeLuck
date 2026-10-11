import Foundation
import FLTaste
import FLTasteSim

// Aggregation and inference. Per (arm, seed) we pool household metrics;
// per (arm) we pool across seeds with paired bootstrap intervals over
// seeds — the same households face every arm, so seed-level pairing is
// the paired design the task calls for (report seed count and B).

/// Pooled accumulator for one arm over one seed's households.
public struct ArmSeedAccumulator {
    public var rankedSessions = 0
    public var cookedSessions = 0
    public var sessions = 0
    public var ndcgSum = 0.0
    public var bestInSlateSum = 0
    public var bestInSlateCount = 0
    public var choiceRankSum = 0.0
    public var choiceRankCount = 0
    public var regretSum = 0.0
    public var exposureRegretSum = 0.0
    public var restrictionViolations = 0
    public var coverageFailures = 0
    public var recoveryCooks: [Int] = []
    public var recoveryCensored = 0
    public var tauSum = 0.0
    public var tauCount = 0
    public var repeats = 0
    public var fairnessGaps: [Double] = []
    public var perRegime: [String: (ndcgSum: Double, ndcgCount: Int, regretSum: Double, cooked: Int, violations: Int)] = [:]

    public init() {}

    public mutating func add(_ household: HouseholdMetrics, regime: String) {
        sessions += household.sessions
        rankedSessions += household.rankedSessions
        cookedSessions += household.cookedSessions
        ndcgSum += household.ndcgSum
        bestInSlateSum += household.bestInSlateSum
        bestInSlateCount += household.bestInSlateCount
        choiceRankSum += household.choiceRankSum
        choiceRankCount += household.choiceRankCount
        regretSum += household.regretSum
        exposureRegretSum += household.exposureRegretSum
        restrictionViolations += household.restrictionViolations
        coverageFailures += household.coverageFailures
        recoveryCooks.append(contentsOf: household.recoveryCooks)
        recoveryCensored += household.recoveryCensored
        tauSum += household.tauSum
        tauCount += household.tauCount
        repeats += household.repeats
        if let gap = household.fairnessGap { fairnessGaps.append(gap) }
        let regimeEntry = perRegime[regime] ?? (0, 0, 0, 0, 0)
        perRegime[regime] = (
            regimeEntry.ndcgSum + household.ndcgSum,
            regimeEntry.ndcgCount + household.rankedSessions,
            regimeEntry.regretSum + household.regretSum,
            regimeEntry.cooked + household.cookedSessions,
            regimeEntry.violations + household.restrictionViolations
        )
    }
}

/// Serialized per-(arm, seed) checkpoint.
public struct ArmSeedResult: Codable {
    public var arm: String
    public var family: String
    public var seed: UInt64
    public var households: Int
    public var sessions: Int
    public var rankedSessions: Int
    public var cookedSessions: Int
    public var meanNDCG: Double?
    public var bestInSlateRate: Double?
    public var meanChoiceRank: Double?
    public var meanRegret: Double?
    public var meanExposureRegret: Double?
    public var restrictionViolations: Int
    public var coverageFailures: Int
    public var medianRecoveryCooks: Double?
    public var recoveryDistribution: [String: Int]
    public var recoveryCensored: Int
    public var meanKendallTau: Double?
    public var repeatRate: Double?
    public var meanFairnessGap: Double?
    public var perRegime: [String: RegimeSummary]
}

public struct RegimeSummary: Codable {
    public var meanNDCG: Double?
    public var meanRegret: Double?
    public var rankedSessions: Int
    public var cookedSessions: Int
    public var restrictionViolations: Int
}

public func summarize(
    arm: String, family: String, seed: UInt64, households: Int, accumulator: ArmSeedAccumulator
) -> ArmSeedResult {
    func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1
            ? Double(sorted[mid])
            : (Double(sorted[mid - 1]) + Double(sorted[mid])) / 2.0
    }
    var distribution: [String: Int] = [:]
    for cook in accumulator.recoveryCooks {
        let key = "\(cook)"
        distribution[key, default: 0] += 1
    }
    return ArmSeedResult(
        arm: arm, family: family, seed: seed, households: households,
        sessions: accumulator.sessions, rankedSessions: accumulator.rankedSessions,
        cookedSessions: accumulator.cookedSessions,
        meanNDCG: accumulator.rankedSessions == 0 ? nil : accumulator.ndcgSum / Double(accumulator.rankedSessions),
        bestInSlateRate: accumulator.bestInSlateCount == 0 ? nil : Double(accumulator.bestInSlateSum) / Double(accumulator.bestInSlateCount),
        meanChoiceRank: accumulator.choiceRankCount == 0 ? nil : accumulator.choiceRankSum / Double(accumulator.choiceRankCount),
        meanRegret: accumulator.cookedSessions == 0 ? nil : accumulator.regretSum / Double(accumulator.cookedSessions),
        meanExposureRegret: accumulator.cookedSessions == 0 ? nil : accumulator.exposureRegretSum / Double(accumulator.cookedSessions),
        restrictionViolations: accumulator.restrictionViolations,
        coverageFailures: accumulator.coverageFailures,
        medianRecoveryCooks: median(accumulator.recoveryCooks),
        recoveryDistribution: distribution,
        recoveryCensored: accumulator.recoveryCensored,
        meanKendallTau: accumulator.tauCount == 0 ? nil : accumulator.tauSum / Double(accumulator.tauCount),
        repeatRate: accumulator.cookedSessions == 0 ? nil : Double(accumulator.repeats) / Double(accumulator.cookedSessions),
        meanFairnessGap: accumulator.fairnessGaps.mean,
        perRegime: accumulator.perRegime.mapValues {
            RegimeSummary(
                meanNDCG: $0.ndcgCount == 0 ? nil : $0.ndcgSum / Double($0.ndcgCount),
                meanRegret: $0.cooked == 0 ? nil : $0.regretSum / Double($0.cooked),
                rankedSessions: $0.ndcgCount, cookedSessions: $0.cooked,
                restrictionViolations: $0.violations)
        })
}

// MARK: - Paired bootstrap

/// One arm's headline numbers with a bootstrap CI over seeds.
public struct ArmStats: Codable {
    public var arm: String
    public var family: String
    public var seeds: Int
    public var bootstrapResamples: Int
    public var meanNDCG: Double
    public var ndcgCI: [Double]
    public var meanRegret: Double?
    public var regretCI: [Double]?
    public var meanKendallTau: Double?
    public var repeatRate: Double?
    public var meanFairnessGap: Double?
    public var medianRecoveryCooks: Double?
    public var restrictionViolations: Int
    public var coverageFailures: Int
    public var perRegimeMeanNDCG: [String: Double]

    public init(
        arm: String, family: String, seeds: Int, bootstrapResamples: Int, meanNDCG: Double,
        ndcgCI: [Double], meanRegret: Double?, regretCI: [Double]?, meanKendallTau: Double?,
        repeatRate: Double?, meanFairnessGap: Double?, medianRecoveryCooks: Double?,
        restrictionViolations: Int, coverageFailures: Int, perRegimeMeanNDCG: [String: Double]
    ) {
        self.arm = arm
        self.family = family
        self.seeds = seeds
        self.bootstrapResamples = bootstrapResamples
        self.meanNDCG = meanNDCG
        self.ndcgCI = ndcgCI
        self.meanRegret = meanRegret
        self.regretCI = regretCI
        self.meanKendallTau = meanKendallTau
        self.repeatRate = repeatRate
        self.meanFairnessGap = meanFairnessGap
        self.medianRecoveryCooks = medianRecoveryCooks
        self.restrictionViolations = restrictionViolations
        self.coverageFailures = coverageFailures
        self.perRegimeMeanNDCG = perRegimeMeanNDCG
    }
}

/// The activation-gate comparison: relative NDCG@10 lift of the engine arm
/// against a baseline, paired per seed, bootstrap CI over seeds.
public struct LiftStats: Codable {
    public var baselineArm: String
    public var seeds: Int
    public var perSeedRelativeLift: [Double]
    public var meanRelativeLift: Double
    public var ciLow: Double
    public var ciHigh: Double
    /// The gate: the 95% interval LOW must clear +10% relative.
    public var gateLowMet: Bool
}

/// The full gate verdict for one campaign.
public struct GateVerdict: Codable {
    public var engineArm: String
    public var versusRule: LiftStats
    public var versusProfileOnly: LiftStats
    public var restrictionViolations: Int
    public var medianRecoveryCooks: Double?
    public var recoveryBarMet: Bool
    public var noViolations: Bool
    public var activationGateMet: Bool
}

/// Deterministic bootstrap: resample seed indices with a seeded RNG.
public func bootstrap(
    values: [Double], resamples: Int, seed: UInt64
) -> (low: Double, high: Double, mean: Double) {
    precondition(!values.isEmpty, "bootstrap of empty sample")
    var rng = SeededRNG(seed: SeedDeriver.child(seed, "bootstrap", values.count))
    let n = values.count
    var means: [Double] = []
    means.reserveCapacity(resamples)
    for _ in 0..<resamples {
        var sum = 0.0
        for _ in 0..<n {
            // nextUniform is in [0, 1); map to an index deterministically.
            let index = min(n - 1, Int(rng.nextUniform() * Double(n)))
            sum += values[index]
        }
        means.append(sum / Double(n))
    }
    means.sort()
    let low = means[max(0, Int(Double(resamples) * 0.025))]
    let high = means[min(resamples - 1, Int(Double(resamples) * 0.975))]
    return (low, high, values.reduce(0, +) / Double(n))
}

/// Builds the paired lift statistics for one baseline.
public func pairedLift(
    engineSeedNDCG: [Double], baselineSeedNDCG: [Double], baselineArm: String,
    resamples: Int
) -> LiftStats {
    precondition(engineSeedNDCG.count == baselineSeedNDCG.count)
    let n = engineSeedNDCG.count
    let perSeed = zip(engineSeedNDCG, baselineSeedNDCG).map { engine, baseline in
        baseline != 0 ? (engine - baseline) / baseline : 0.0
    }
    let interval = bootstrap(values: perSeed, resamples: resamples, seed: 77)
    return LiftStats(
        baselineArm: baselineArm, seeds: n, perSeedRelativeLift: perSeed,
        meanRelativeLift: interval.mean, ciLow: interval.low, ciHigh: interval.high,
        gateLowMet: interval.low >= 0.10)
}

/// Assembles the gate verdict from per-seed results.
public func gateVerdict(
    results: [ArmSeedResult], engineArm: String, ruleArm: String, profileArm: String,
    resamples: Int
) -> GateVerdict? {
    func seedNDCG(_ arm: String) -> [Double]? {
        let bySeed = results.filter { $0.arm == arm }.sorted { $0.seed < $1.seed }
        guard bySeed.count > 1, bySeed.allSatisfy({ $0.meanNDCG != nil }) else { return nil }
        return bySeed.map { $0.meanNDCG! }
    }
    guard let engine = seedNDCG(engineArm),
          let rule = seedNDCG(ruleArm),
          let profile = seedNDCG(profileArm)
    else { return nil }

    let versusRule = pairedLift(
        engineSeedNDCG: engine, baselineSeedNDCG: rule, baselineArm: ruleArm, resamples: resamples)
    let versusProfile = pairedLift(
        engineSeedNDCG: engine, baselineSeedNDCG: profile, baselineArm: profileArm,
        resamples: resamples)

    let engineResults = results.filter { $0.arm == engineArm }
    let violations = engineResults.reduce(0) { $0 + $1.restrictionViolations }
    let recoveries = engineResults.compactMap { $0.medianRecoveryCooks }
    let medianRecovery = recoveries.mean  // median of per-seed medians
    let recoveryBarMet = (medianRecovery ?? .infinity) <= 6.0
    let noViolations = violations == 0

    return GateVerdict(
        engineArm: engineArm, versusRule: versusRule, versusProfileOnly: versusProfile,
        restrictionViolations: violations, medianRecoveryCooks: medianRecovery,
        recoveryBarMet: recoveryBarMet, noViolations: noViolations,
        activationGateMet: versusRule.gateLowMet && versusProfile.gateLowMet
            && noViolations && recoveryBarMet)
}
