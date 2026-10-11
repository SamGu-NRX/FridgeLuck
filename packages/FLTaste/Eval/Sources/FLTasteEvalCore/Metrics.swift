import Foundation
import FLTaste
import FLTasteSim

// Metrics from the hidden ground truth (Part 2's `GroundTruth`) plus the
// arm's full feasible ordering per session. Pure functions of (ground truth,
// rank log): no wall clock, no global state, byte-reproducible per seed.
//
// Rank-call alignment: the simulator calls `ranker.rank` exactly once per
// session that is attended AND has a non-empty feasible set; such sessions
// end in `.cooked` or `.skippedSession`. Every other outcome
// (`.unattended`, `.nothingFeasible`) never reaches the ranker. The rank
// log therefore aligns 1:1, in order, with those sessions.

/// All metric accumulators for one arm over one household run.
public struct HouseholdMetrics {
    public var sessions = 0
    public var rankedSessions = 0
    public var cookedSessions = 0
    public var ndcgSum = 0.0
    public var bestInSlateSum = 0
    public var bestInSlateCount = 0
    public var choiceRankSum = 0.0
    public var choiceRankCount = 0
    public var regretSum = 0.0
    public var exposureRegretSum = 0.0
    /// Recipes the arm ordered that were not in the feasible set. Must be 0;
    /// anything else is a contract violation (the gate treats > 0 as failure).
    public var restrictionViolations = 0
    public var coverageFailures = 0
    public var recoveryCooks: [Int] = []
    public var recoveryCensored = 0
    public var tauSum = 0.0
    public var tauCount = 0
    public var repeats = 0
    public var fairnessGap: Double?

    /// Mean NDCG over ranked sessions.
    var meanNDCG: Double? {
        rankedSessions == 0 ? nil : ndcgSum / Double(rankedSessions)
    }

    var meanRegret: Double? {
        cookedSessions == 0 ? nil : regretSum / Double(cookedSessions)
    }
}

/// Recovery threshold: a cook "recovers" when its pick sits within this
/// absolute gap of the session's best feasible true utility. Utilities on
/// the household-latent scale (roughly [-1, 1] pre-contamination), so 0.1 is
/// a top-decile-quality pick. Declared here, once, before any results.
let recoveryUtilityGap = 0.1

/// Repetition window: cooking the same recipe within this many weeks of its
/// last cook counts as unwanted repetition.
let repetitionWindowWeeks = 4

/// Scores one completed household run.
public func scoreHousehold(
    groundTruth: GroundTruth, rankLog: [(week: Int, ordered: [RecipeID])]
) -> HouseholdMetrics {
    var metrics = HouseholdMetrics()
    metrics.sessions = groundTruth.sessions.count

    let rankedSessions = groundTruth.sessions.filter {
        $0.outcome == .cooked || $0.outcome == .skippedSession
    }
    precondition(
        rankedSessions.count == rankLog.count,
        "rank log \(rankLog.count) does not align with \(rankedSessions.count) ranked sessions")

    // One recovery counter per shift, armed the week the shift lands.
    let shifts = groundTruth.shifts.map(\.week)
    var shiftCounters = [Int](repeating: 0, count: shifts.count)
    var shiftActive = [Bool](repeating: false, count: shifts.count)

    var lastCookWeek: [String: Int] = [:]
    var eaterRegrets: [String: [Double]] = [:]

    for (session, logEntry) in zip(rankedSessions, rankLog) {
        metrics.rankedSessions += 1
        // Sim's Ranker returns FLTaste RecipeIDs; the ground truth records
        // raw string ids. Bridge once here, then work in raw ids throughout.
        let feasible = Set(session.feasibleIds)
        let ordered = logEntry.ordered.map(\.rawValue)
        let orderedSet = Set(ordered)

        // Zero-tolerance bookkeeping: ordering something infeasible is a
        // hard-restriction violation; dropping a feasible candidate is a
        // coverage failure. Both are recorded, neither silently forgiven.
        metrics.restrictionViolations += ordered.count - orderedSet.count
        metrics.restrictionViolations += orderedSet.subtracting(feasible).count
        if orderedSet != feasible { metrics.coverageFailures += 1 }

        // Score only over the feasible subset (defensive, mirrors the sim).
        let scoredOrder = ordered.filter { feasible.contains($0) }

        // NDCG@10 among feasible candidates.
        let ndcg = ndcg10(ordered: scoredOrder, utilities: session.utilities)
        metrics.ndcgSum += ndcg

        // Best-feasible-in-slate hit rate (the slate is the shown top slice).
        if let best = session.trueRanking.first {
            metrics.bestInSlateCount += 1
            if session.slateIds.contains(best) { metrics.bestInSlateSum += 1 }
        }

        // Kendall tau calibration against the true order.
        metrics.tauSum += kendallTau(ordered: scoredOrder, utilities: session.utilities)
        metrics.tauCount += 1

        guard session.outcome == .cooked, let choice = session.choiceId,
              let chosenUtility = session.utilities[choice],
              let bestID = session.trueRanking.first,
              let bestUtility = session.utilities[bestID]
        else { continue }

        metrics.cookedSessions += 1
        if let rankIndex = scoredOrder.firstIndex(of: choice) {
            metrics.choiceRankSum += Double(rankIndex + 1)
            metrics.choiceRankCount += 1
        }
        let regret = bestUtility - chosenUtility
        metrics.regretSum += regret
        let feasibleCount = max(1, feasible.count)
        let exposureShare =
            Double(min(session.slateIds.count, feasible.count)) / Double(feasibleCount)
        metrics.exposureRegretSum += regret * exposureShare

        eaterRegrets[session.actorId, default: []].append(regret)

        // Unwanted repetition.
        if let lastWeek = lastCookWeek[choice], session.week - lastWeek <= repetitionWindowWeeks {
            metrics.repeats += 1
        }
        lastCookWeek[choice] = session.week

        // Shift recovery: count cooks after each active shift until one pick
        // lands within `recoveryUtilityGap` of the session's best.
        for i in shifts.indices {
            if session.week >= shifts[i] { shiftActive[i] = true }
            guard shiftActive[i] else { continue }
            shiftCounters[i] += 1
            if bestUtility - chosenUtility <= recoveryUtilityGap {
                metrics.recoveryCooks.append(shiftCounters[i])
                shiftActive[i] = false  // recovered; stop counting this shift
            }
        }
    }

    // Shifts never recovered inside the horizon are censored.
    metrics.recoveryCensored = zip(shiftActive, shiftCounters).filter(\.0).count

    // Two-eater fairness: per-eater mean regret gap in a two-eater household.
    let eaters = eaterRegrets.keys.sorted()
    if eaters.count == 2,
       let a = eaterRegrets[eaters[0]]?.mean,
       let b = eaterRegrets[eaters[1]]?.mean {
        metrics.fairnessGap = abs(a - b)
    }
    return metrics
}

// MARK: - Pure metric functions

/// NDCG@10 among feasible candidates: exponential gains from true utilities,
/// compared against the ideal feasible ordering.
public func ndcg10(ordered: [String], utilities: [String: Double]) -> Double {
    func dcg(_ ids: ArraySlice<String>) -> Double {
        ids.enumerated().reduce(0.0) { acc, pair in
            let utility = utilities[pair.element] ?? 0.0
            return acc + (pow(2.0, min(1.0, max(0.0, utility))) - 1.0) / log2(Double(pair.offset + 2))
        }
    }
    let ideal = ordered.sorted {
        (utilities[$0] ?? -.infinity) > (utilities[$1] ?? -.infinity)
    }
    let idealGain = dcg(ideal.prefix(10))
    guard idealGain > 0 else { return 1.0 }  // all-equal utilities: any order is ideal
    return dcg(ordered.prefix(10)) / idealGain
}

/// Kendall tau between the arm's order and the true order, on a fixed
/// deterministic stride of pairs (feasible sets can reach ~100 ids).
public func kendallTau(ordered: [String], utilities: [String: Double]) -> Double {
    let n = min(ordered.count, 40)
    guard n >= 2 else { return 1.0 }
    var concordant = 0.0
    var total = 0.0
    for i in 0..<(n - 1) {
        for j in stride(from: i + 1, to: n, by: 3) {
            let ui = utilities[ordered[i]] ?? 0.0
            let uj = utilities[ordered[j]] ?? 0.0
            guard ui != uj else { continue }
            total += 1.0
            if (ui > uj) == (i < j) { concordant += 1.0 }
        }
    }
    guard total > 0 else { return 1.0 }
    return (2.0 * concordant - total) / total
}

extension Array where Element == Double {
    public var mean: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
