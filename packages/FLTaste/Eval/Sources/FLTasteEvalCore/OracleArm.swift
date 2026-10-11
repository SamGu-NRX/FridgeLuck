import Foundation
import FLTaste
import FLTasteSim

/// Diagnostic arm that ranks by the true latent household utility — the
/// ceiling every real arm is measured against. Deliberately NOT in the
/// registry: it sees what a real ranker must never see. The arm-sanity
/// test uses it to prove the metrics pipeline rewards a correct ranking.
public struct OracleArm: ArmFactory {
    public let id = "oracle"
    public let rationale =
        "Diagnostic ceiling: ranks by the hidden latent utility to validate the scoring pipeline; not part of the preregistered 12."
    public let family = "diagnostic"
    public let isStateless = true

    public init() {}

    public func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        OracleArmState()
    }
}

final class OracleArmState: ArmState, @unchecked Sendable {
    private var scores: [RecipeID: Double] = [:]

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(uniqueKeysWithValues: candidates.map { ($0.recipe.id, $0.householdUtility) })
        return ArmOrdering.ordered(candidates) { $0.householdUtility }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}
