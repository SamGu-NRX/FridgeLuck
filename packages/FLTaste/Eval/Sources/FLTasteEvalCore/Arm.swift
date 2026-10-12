import Foundation
import FLTaste
import FLTasteSim

/// One week's frozen learner state for an arm. Classes, because a state
/// captures its scores at rank time and learners mutate internal buffers
/// during `learn`-building construction; states are frozen once handed to
/// the versioned ranker.
///
/// The simulator's `Ranker` seam is stateless: it offers no feedback hook,
/// so a learning arm cannot observe what was cooked from inside a run. The
/// campaign therefore learns at week granularity through staged runs: stage
/// k re-simulates weeks 0..<k with per-week state versions, and week w is
/// always ranked with the state folded from the canonical trajectory's
/// weeks 0..<w events. By induction over stages, each stage reproduces all
/// earlier weeks exactly, so the final stage's run IS the weekly-continual
/// trajectory. This type is one state version: it ranks and reports the
/// scores it used (for the calibration metric).
public protocol ArmState: AnyObject, Sendable {
    /// Ranks candidates best-first (the simulator's seam contract).
    func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID]

    /// Predicted score per candidate id from the most recent `rank` call.
    /// Calibration compares these against hidden true utilities. Default:
    /// empty (the arm opts out of calibration).
    func lastScores() -> [RecipeID: Double]
}

extension ArmState {
    func lastScores() -> [RecipeID: Double] { [:] }
}

/// Creates per-week state versions for one arm. Instances must be
/// deterministic: all internal randomness derives from
/// `(householdSeed, armSeed)`, never the wall clock.
public protocol ArmFactory: Sendable {
    var id: String { get }
    /// One-line rationale, published with the arm list in RESULTS.md.
    var rationale: String { get }
    /// Family grouping per PLAN: "family-1"…"family-5", "baseline", "ablation".
    var family: String { get }
    /// Stateless arms never learn, so one run per household suffices
    /// (no staging). Learning arms are staged per week.
    var isStateless: Bool { get }

    /// A fresh state folded from `events` (empty for a cold start).
    func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState
}

public extension ArmFactory {
    var isStateless: Bool { false }
}

/// Ranks each week with that week's frozen state version.
///
/// `states[w]` is the state folded from events of weeks 0..<w. During a
/// staged run of weeks 0..<k, week w picks `states[min(w, states.count-1)]`:
/// already-built versions rank their own weeks, and filler weeks at the
/// front of a later stage reuse the newest version (their events are
/// discarded by the runner anyway — only the newest week's events are
/// folded, and earlier weeks reproduce earlier stages byte for byte).
struct VersionedRanker: Ranker {
    let armID: String
    let states: [any ArmState]

    var id: String { armID }

    func rank(_ candidates: [RankerCandidate], context: RankingContext) -> [RecipeID] {
        let index = min(context.week, states.count - 1)
        return states[index].rank(candidates, context: context)
    }
}

/// Shared plumbing for arms that score candidates by a numeric function.
///
/// Deterministic ordering: score descending, ties by raw id ascending —
/// lexicographic, so the order never depends on sort-algorithm internals.
/// (The simulator's true ranking breaks ties numerically; tied candidates
/// have equal utilities, so no NDCG difference can be manufactured.)
enum ArmOrdering {
    static func ordered(_ candidates: [RankerCandidate], score: (RankerCandidate) -> Double) -> [RecipeID] {
        candidates
            .sorted { a, b in
                let sa = score(a), sb = score(b)
                if sa != sb { return sa > sb }
                return a.id.rawValue < b.id.rawValue
            }
            .map { $0.id }
    }
}
