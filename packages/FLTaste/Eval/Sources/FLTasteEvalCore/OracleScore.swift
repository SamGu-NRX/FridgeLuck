import Foundation
import FLTaste
import FLTasteSim

// The diagnostic ceiling is no longer a Ranker arm: the post-seam ranker
// input is a proven-latent-free observable projection (Sim's
// `testRankerSeesNoLatentDataEvenUnderReflection`), so nothing — not even a
// diagnostic arm — can read true utilities at the seam. The oracle instead
// validates the scoring pipeline post hoc: it rebuilds every ranked
// session's ordering from the ground truth's own `trueRanking` and scores
// that log through the same `scoreHousehold` every arm goes through. An
// oracle-log NDCG far above every arm's (and near 1) proves the metrics
// pipeline rewards a correct ranking.

/// The oracle rank log: each ranked session ordered by hidden utility.
/// Pure post-hoc data over the exported ground truth — never a ranker.
public func oracleRankLog(groundTruth: GroundTruth) -> [(week: Int, ordered: [RecipeID])] {
    groundTruth.sessions
        .filter { $0.outcome == .cooked || $0.outcome == .skippedSession }
        .map { session in
            (session.week, session.trueRanking.compactMap { RecipeID($0) })
        }
}
