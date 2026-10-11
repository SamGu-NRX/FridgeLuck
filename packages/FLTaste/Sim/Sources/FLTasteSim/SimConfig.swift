import Foundation

/// Every knob of the household simulator, with its documented default.
///
/// Calibration lives in `SIM-ASSUMPTIONS.md` (package root). The cook
/// frequency, rating sparsity, and horizon numbers come from overhaul
/// finding 8: "At three cooks a week, week 1 has at most three cooks and
/// month 3 about 39, with perhaps 13 ratings." Everything else is a
/// documented assumption, safe to sweep.
public struct SimConfig: Sendable, Equatable {

    // MARK: Run shape

    /// Master seed. The same seed and config reproduce byte-identical output.
    public var seed: UInt64
    /// Simulation start in epoch milliseconds UTC. Default is
    /// 2026-01-01T00:00:00Z, the same base instant Part 1's fixtures use.
    public var startMillis: Int64
    /// Weeks to simulate. 13 weeks at three cooks a week is "month 3" of
    /// finding 8: about 39 cooks, perhaps 13 ratings.
    public var weeks: Int
    /// Eaters in the household: 1 or 2. One code path covers both.
    public var householdSize: Int

    // MARK: Cook frequency

    /// Mean cooked dinners per week (Poisson). Finding 8: three cooks a week.
    public var cooksPerWeek: Double
    /// Meals shopped for each week. One more than the mean cook rate, so the
    /// pantry usually but not always supports the week's cooks and
    /// availability genuinely binds sometimes.
    public var shopMealsPerWeek: Int

    // MARK: Budget and pantry

    /// Weekly shopping budget in synthetic currency units. Prices are
    /// synthetic (see `PriceModel`); the default buys four planned meals with
    /// a little slack.
    public var weeklyBudget: Double
    /// Weeks before an unused pantry lot spoils and is dropped.
    public var pantryShelfLifeWeeks: Int

    // MARK: The decision surface

    /// Candidates the app surface shows per session. Finding 5 describes a
    /// 10-slot surface ("fewer than 6 of 10 does not imply two good swaps").
    public var slateSize: Int
    /// Probability the chooser is attentive: picks by taste (softmax over the
    /// shown slate) rather than distracted: uniform over the shown slate.
    /// Distracted picks are why "cooked what was shown" is weak evidence.
    public var attentionProbability: Double
    /// Softmax temperature over true household utility, in utility units.
    /// Lower is more taste-driven.
    public var choiceTemperature: Double
    /// Utility bonus per position from the top of the slate: position bias.
    /// Earlier slots are slightly more likely to be picked, independently of
    /// taste.
    public var positionBias: Double
    /// Probability a session rejects one or two shown candidates with a
    /// typed skip reason before choosing.
    public var skipSessionProbability: Double

    // MARK: Ratings and cook-complete answers

    /// Probability a cook carries a rating. Finding 8: about a third
    /// (13 ratings in 39 cooks).
    public var ratingProbability: Double
    /// Standard deviation of the Gaussian noise added to the respondent's
    /// latent utility before quantising to the 1-5 scale. Higher is noisier.
    public var ratingNoiseSigma: Double
    /// Maps latent utility to the rating scale: rating ~ round(3 + slope
    /// times utility + noise), clamped to 1...5.
    public var ratingSlope: Double
    /// Probability a completed cook also answers "would make again".
    public var wouldMakeAgainProbability: Double
    /// Logistic midpoint and slope mapping the respondent's latent utility
    /// to the probability of answering "would make again" = true.
    public var wouldMakeAgainMidpoint: Double
    public var wouldMakeAgainSlope: Double

    // MARK: Other behavioural events

    /// Probability a cook substitutes one required ingredient.
    public var substitutionProbability: Double
    /// Probability a substitution is "preferred" (taste) rather than
    /// "necessary" (pantry). The app asks which; the mix matters because the
    /// two carry different evidence.
    public var preferredSubstitutionProbability: Double
    /// Probability a cook logs LeChef structured feedback.
    public var leChefFeedbackProbability: Double
    /// Probability a session logs a detail view (opened) of a shown
    /// candidate that was not chosen.
    public var extraOpenProbability: Double
    /// Probability a shown candidate with utility at or above
    /// `saveUtilityThreshold` is saved to the cookbook.
    public var saveProbability: Double
    /// Household-mean utility above which a shown candidate may be saved.
    public var saveUtilityThreshold: Double
    /// Probability a cook logs an editedServings event (doubling for
    /// leftovers, the two-eater case).
    public var doubleServingsProbability: Double
    /// Probability a cook whose household utility is at or below
    /// `neverSuggestUtility` ends in a "don't ask again" write on the recipe's
    /// least-liked required ingredient.
    public var neverSuggestProbability: Double
    /// Household-mean utility at or below which the neverSuggest draw can
    /// fire. NeverSuggest is a strong explicit signal; rare by design.
    public var neverSuggestUtility: Double

    // MARK: Dynamics

    /// Slow taste drift: rotation angle in radians per week, applied to each
    /// eater's latent vector in an eater-specific pseudo-random plane.
    public var driftPerWeek: Double
    /// Mid-history shifts and capability changes, applied at the start of
    /// their week, in the order listed.
    public var shifts: [ShiftSpec]

    // MARK: Setup restrictions

    /// Probability each eater carries one hard restriction drawn at setup
    /// (allergy or diet). Set to 0 for restriction-free households; set to 1
    /// to always draw one.
    public var restrictionProbability: Double

    public init() {
        self.seed = 1
        self.startMillis = 1_767_225_600_000  // 2026-01-01T00:00:00Z
        self.weeks = 13
        self.householdSize = 2
        self.cooksPerWeek = 3.0
        self.shopMealsPerWeek = 4
        self.weeklyBudget = 18.0
        self.pantryShelfLifeWeeks = 2
        self.slateSize = 10
        self.attentionProbability = 0.85
        self.choiceTemperature = 0.35
        self.positionBias = 0.05
        self.skipSessionProbability = 0.5
        self.ratingProbability = 1.0 / 3.0
        self.ratingNoiseSigma = 0.75
        self.ratingSlope = 0.8
        self.wouldMakeAgainProbability = 0.5
        self.wouldMakeAgainMidpoint = 0.0
        self.wouldMakeAgainSlope = 0.7
        self.substitutionProbability = 0.15
        self.preferredSubstitutionProbability = 0.5
        self.leChefFeedbackProbability = 0.12
        self.extraOpenProbability = 0.3
        self.saveProbability = 0.12
        self.saveUtilityThreshold = 0.8
        self.doubleServingsProbability = 0.08
        self.neverSuggestProbability = 0.3
        self.neverSuggestUtility = -1.0
        self.driftPerWeek = 0.02
        self.shifts = []
        self.restrictionProbability = 0.6
    }

    /// Throws when a config value cannot describe a run.
    public enum ConfigError: Error, Equatable {
        case invalidHouseholdSize(Int)
        case invalidWeeks(Int)
        case invalidProbability(String, Double)
        case invalidPositive(String, Double)
        case shiftsOutOfWeekOrder
    }

    /// Fails fast on values that would silently produce a broken run.
    /// Probabilities must sit in 0...1; weeks and householdSize have hard
    /// bounds; shifts must be listed in non-decreasing week order.
    public func validate() throws {
        guard householdSize == 1 || householdSize == 2 else {
            throw ConfigError.invalidHouseholdSize(householdSize)
        }
        guard weeks >= 1 else { throw ConfigError.invalidWeeks(weeks) }
        for (name, value) in [
            ("attentionProbability", attentionProbability),
            ("skipSessionProbability", skipSessionProbability),
            ("ratingProbability", ratingProbability),
            ("wouldMakeAgainProbability", wouldMakeAgainProbability),
            ("substitutionProbability", substitutionProbability),
            ("preferredSubstitutionProbability", preferredSubstitutionProbability),
            ("leChefFeedbackProbability", leChefFeedbackProbability),
            ("extraOpenProbability", extraOpenProbability),
            ("saveProbability", saveProbability),
            ("doubleServingsProbability", doubleServingsProbability),
            ("neverSuggestProbability", neverSuggestProbability),
            ("restrictionProbability", restrictionProbability),
        ] {
            guard value >= 0 && value <= 1 else {
                throw ConfigError.invalidProbability(name, value)
            }
        }
        for (name, value) in [
            ("cooksPerWeek", cooksPerWeek),
            ("weeklyBudget", weeklyBudget),
            ("choiceTemperature", choiceTemperature),
            ("ratingNoiseSigma", ratingNoiseSigma),
        ] {
            guard value > 0 else { throw ConfigError.invalidPositive(name, value) }
        }
        guard shifts.map({ $0.week }) == shifts.map({ $0.week }).sorted() else {
            throw ConfigError.shiftsOutOfWeekOrder
        }
    }
}

/// One planned mid-history change, applied at the start of its week.
public enum ShiftSpec: Sendable, Equatable {
    /// An eater's diet becomes a hard restriction from that week on —
    /// "went vegetarian". Emitted as a `profileEdit(.setRestriction)` event
    /// attributed to the eater, and the household union gains the diet.
    case diet(eaterIndex: Int, diet: Diet, week: Int)
    /// The weekly budget is multiplied by `factor` from that week on —
    /// an income or cost-of-living change that tightens or relaxes shopping.
    case budgetChange(factor: Double, week: Int)
    /// Recipes whose instructions contain `needle` become infeasible from
    /// that week on — "the oven broke" (needle "bake").
    case lostCapability(needle: String, week: Int)

    public enum Diet: String, Sendable {
        case vegetarian
        case vegan
    }

    public var week: Int {
        switch self {
        case .diet(_, _, let week): return week
        case .budgetChange(_, let week): return week
        case .lostCapability(_, let week): return week
        }
    }
}
