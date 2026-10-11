import Foundation

/// One arm's published roster entry (arm list with rationale, RESULTS.md).
public struct ArmRosterEntry: Codable, Sendable {
    public var id: String
    public var family: String
    public var rationale: String
    public var stateless: Bool

    public init(id: String, family: String, rationale: String, stateless: Bool) {
        self.id = id
        self.family = family
        self.rationale = rationale
        self.stateless = stateless
    }
}

/// Fail-close contract checks shared by the executable and the suite wiring:
/// a result set is publishable only when every registered arm is present
/// with finite metrics and zero hard-restriction violations. The
/// planted-failure self-test feeds deliberately corrupt results through
/// this validator and asserts they are rejected.
public enum SuiteContract {
    /// All problems found, human-readable. Empty list = publishable.
    public static func validate(results: [ArmSeedResult], roster: [ArmRosterEntry]) -> [String] {
        var problems: [String] = []
        let expectedArms = roster.map { $0.id }
        let presentArms = Set(results.map { $0.arm })
        for id in expectedArms where !presentArms.contains(id) {
            problems.append("missing arm results: \(id)")
        }
        for result in results {
            if result.restrictionViolations != 0 {
                problems.append(
                    "arm \(result.arm) seed \(result.seed): \(result.restrictionViolations) restriction violations (hard-fail)")
            }
            if result.coverageFailures != 0 {
                problems.append(
                    "arm \(result.arm) seed \(result.seed): \(result.coverageFailures) ground-truth coverage failures")
            }
            if let ndcg = result.meanNDCG, !ndcg.isFinite || ndcg < 0 || ndcg > 1 {
                problems.append("arm \(result.arm) seed \(result.seed): NDCG out of range or non-finite")
            }
            if result.households < 1 {
                problems.append("arm \(result.arm) seed \(result.seed): no households measured")
            }
        }
        return problems
    }
}
