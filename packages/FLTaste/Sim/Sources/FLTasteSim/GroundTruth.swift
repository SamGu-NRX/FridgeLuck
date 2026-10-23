import Foundation
import FLTaste

/// Hidden truth recorded alongside the event stream: everything a scorer
/// needs that a learning model never sees. Serialized through Part 1's
/// `CanonicalJSON` (sorted keys, fixed number format), so the same seed and
/// config produce byte-identical ground truth on every run.
public struct GroundTruth: Sendable {

    /// Per cook session: the feasible set, the shown slate, the pick, and
    /// the scoring evidence — true ranking, true utilities, the choice
    /// probabilities (contamination included), and the rating draw.
    public struct Session: Sendable {
        /// What the session ended in.
        public enum SessionOutcome: String, Sendable {
            /// Cooked from the slate.
            case cooked
            /// Scheduled cook, but the pantry supported nothing legal.
            case nothingFeasible
            /// Household never opened the app; habit cook from history.
            case unattended
            /// Attended, slate shown, but the household skipped cooking.
            case skippedSession
        }

        // Mutable so the simulator can assemble a session incrementally.
        public var week: Int
        public var atMillis: Int64
        public var cookIndex: Int
        /// The eater who acted (cooked/rated/skipped) this session.
        public var actorId: String
        /// Recipe ids legal AND pantry-supported this session, sorted.
        public var feasibleIds: [String]
        /// The slate the ranker proposed (ordered, subset of feasible).
        public var slateIds: [String]
        /// What the household picked; nil when nothing was cooked.
        public var choiceId: String?
        public var outcome: SessionOutcome
        /// Feasible candidates ranked by true household utility, best first.
        public let trueRanking: [String]
        /// True household utility per feasible recipe id.
        public let utilities: [String: Double]
        /// Choice probabilities over the shown slate (slate order).
        public var choiceProbabilities: [String: Double]
        /// Pantry stock factor per feasible recipe id (contamination term).
        public var availability: [String: Double]
        /// Rating internals when this cook was rated.
        public var rating: RatingDraw?
        /// The skip this session emitted, when it emitted one.
        public var skip: SkipRecord?
        /// The substitution this session emitted, when it emitted one.
        public var substitution: SubstitutionRecord?
        /// The neverSuggest edit this session emitted, when it emitted one.
        public var neverSuggestIngredient: String?
    }

    /// The rating's anatomy: latent mean, rater bias, gaussian noise draw,
    /// and the emitted 1...5 stars.
    public struct RatingDraw: Sendable {
        public let latentMean: Double
        public let raterBias: Double
        public let noise: Double
        public let stars: Int
        public let wouldMakeAgain: Bool?
    }

    public struct SkipRecord: Sendable {
        public let recipeId: String
        public let reason: String
    }

    public struct SubstitutionRecord: Sendable {
        public let recipeId: String
        public let from: String
        public let to: String?
        public let mode: String
    }

    /// Eater latent vectors at a point in time (post-drift, post-shift).
    public struct LatentSnapshot: Sendable {
        public let week: Int
        public let atMillis: Int64
        /// eater id → dense latent vector.
        public let latents: [String: [Double]]
    }

    /// Applied shift, serialized for the scorer.
    public struct ShiftRecord: Sendable {
        public let week: Int
        public let atMillis: Int64
        public let kind: String
        public let detail: [String: String]
    }

    public let rankerId: String
    public let seed: UInt64
    public let weeks: Int
    /// Which latent regime produced the household latents (a scorer needs
    /// to know whether the run is rule-blind; a learning model never reads
    /// ground truth at all).
    public let latentRegime: LatentRegime
    /// Setup truth: initial latents and setup restrictions.
    public let householdInitial: Household
    /// Per-eater rater bias fixed at setup (a rating model term, not taste).
    public let raterBias: [String: Double]
    public let shifts: [ShiftRecord]
    public let latentsOverTime: [LatentSnapshot]
    public let sessions: [Session]
    /// Every gaussian rating-noise draw, in emission order — lets a scorer
    /// reproduce stars exactly from (latentMean, bias, noise).
    public let ratingNoiseDraws: [Double]
    public let missedCooks: Int
    public let eventCount: Int
}
