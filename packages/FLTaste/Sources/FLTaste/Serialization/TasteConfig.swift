import Foundation

/// Hyperparameters of the taste engine. Serialized with every snapshot so a
/// fixture reproduces exactly; restore fails closed on an unknown
/// configVersion. Every knob is justified in DESIGN.md.
public struct TasteConfig: Equatable, Sendable {
    public let configVersion: Int

    // Recency and drift (days). The posterior forgets with one half-life;
    // per-evidence-class counters use their own.
    public var posteriorHalfLifeDays: Double
    public var cookedEvidenceHalfLifeDays: Double
    public var savedEvidenceHalfLifeDays: Double
    public var openedEvidenceHalfLifeDays: Double
    public var viewedEvidenceHalfLifeDays: Double
    public var skippedEvidenceHalfLifeDays: Double
    public var substitutionEvidenceHalfLifeDays: Double
    public var feedbackEvidenceHalfLifeDays: Double

    // Exposure weighting (availability as confound).
    public var exposureVarietyReference: Double
    public var exposureFloor: Double

    // Linear-Gaussian model.
    public var observationNoiseVariance: Double
    public var priorWeightVariance: Double

    // Exploration: Thompson draw inflation decays with evidence.
    public var explorationInflation: Double
    public var explorationDecayEvidence: Double

    // Cold start: blend of prior/baseline until this much effective evidence.
    public var coldStartEvidence: Double

    // Repeat affinity (per-recipe decayed cook count multiplier).
    public var repeatAffinityWeight: Double
    public var repeatAffinityHalfLifeDays: Double

    // Soft dismissal of a profile sentence expires after this many days.
    public var softDismissalExpiryDays: Int64

    public static let standard = TasteConfig(
        configVersion: 1,
        posteriorHalfLifeDays: 90,
        cookedEvidenceHalfLifeDays: 120,
        savedEvidenceHalfLifeDays: 60,
        openedEvidenceHalfLifeDays: 30,
        viewedEvidenceHalfLifeDays: 30,
        skippedEvidenceHalfLifeDays: 45,
        substitutionEvidenceHalfLifeDays: 90,
        feedbackEvidenceHalfLifeDays: 45,
        exposureVarietyReference: 6,
        exposureFloor: 0.15,
        observationNoiseVariance: 1,
        priorWeightVariance: 0.25,
        explorationInflation: 2,
        explorationDecayEvidence: 8,
        coldStartEvidence: 12,
        repeatAffinityWeight: 0.15,
        repeatAffinityHalfLifeDays: 60,
        softDismissalExpiryDays: 120
    )

    public init(
        configVersion: Int, posteriorHalfLifeDays: Double, cookedEvidenceHalfLifeDays: Double,
        savedEvidenceHalfLifeDays: Double, openedEvidenceHalfLifeDays: Double,
        viewedEvidenceHalfLifeDays: Double, skippedEvidenceHalfLifeDays: Double,
        substitutionEvidenceHalfLifeDays: Double, feedbackEvidenceHalfLifeDays: Double,
        exposureVarietyReference: Double, exposureFloor: Double,
        observationNoiseVariance: Double, priorWeightVariance: Double,
        explorationInflation: Double, explorationDecayEvidence: Double,
        coldStartEvidence: Double, repeatAffinityWeight: Double,
        repeatAffinityHalfLifeDays: Double, softDismissalExpiryDays: Int64
    ) {
        self.configVersion = configVersion
        self.posteriorHalfLifeDays = posteriorHalfLifeDays
        self.cookedEvidenceHalfLifeDays = cookedEvidenceHalfLifeDays
        self.savedEvidenceHalfLifeDays = savedEvidenceHalfLifeDays
        self.openedEvidenceHalfLifeDays = openedEvidenceHalfLifeDays
        self.viewedEvidenceHalfLifeDays = viewedEvidenceHalfLifeDays
        self.skippedEvidenceHalfLifeDays = skippedEvidenceHalfLifeDays
        self.substitutionEvidenceHalfLifeDays = substitutionEvidenceHalfLifeDays
        self.feedbackEvidenceHalfLifeDays = feedbackEvidenceHalfLifeDays
        self.exposureVarietyReference = exposureVarietyReference
        self.exposureFloor = exposureFloor
        self.observationNoiseVariance = observationNoiseVariance
        self.priorWeightVariance = priorWeightVariance
        self.explorationInflation = explorationInflation
        self.explorationDecayEvidence = explorationDecayEvidence
        self.coldStartEvidence = coldStartEvidence
        self.repeatAffinityWeight = repeatAffinityWeight
        self.repeatAffinityHalfLifeDays = repeatAffinityHalfLifeDays
        self.softDismissalExpiryDays = softDismissalExpiryDays
    }
}
