import Foundation

/// Whether a pair applies to a requested role in a recipe's steps.
/// Ordered for ranking; `unknown` stays unknown — never upgraded to fit.
public enum Verdict: Int, Comparable, Sendable {
    case verified = 0
    case plausible = 1
    case unknown = 2
    case unsupported = 3

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ContextRules {
    /// Decide the verdict for `pair` when the ingredient's role in the
    /// recipe's steps is `role`.
    ///
    /// Rules (documented in data/substitutions/SCHEMA.md):
    /// - Explicit failure evidence wins: a `fails` entry for the role makes
    ///   the verdict `unsupported` unless the ratio evidence for that role is
    ///   sourced (a sourced row with a fails entry is eater-conditional, and
    ///   the restriction refusal — not the verdict — carries the safety rule).
    /// - `verified` requires BOTH sourced function evidence and sourced ratio
    ///   evidence (PR #49 semantics). A conflicting ratio never verifies.
    /// - Unknown function or ratio evidence stays `unknown`.
    /// - A pair with no row connecting it to the requested role is `unknown`
    ///   (or `unsupported` with the recorded reason when the pair records a
    ///   failure for that role).
    public static func verdict(for pair: Pair, requestedRole role: Role) -> Verdict {
        let ratioStatus: EvidenceStatus
        if role == pair.role {
            ratioStatus = pair.ratio.status
        } else if let also = pair.supportedAlso.first(where: { $0.role == role }) {
            ratioStatus = also.status
        } else {
            return pair.fails.contains { $0.role == role } ? .unsupported : .unknown
        }

        if pair.fails.contains(where: { $0.role == role }) && ratioStatus != .sourced {
            return .unsupported
        }

        switch (pair.functionStatus, ratioStatus) {
        case (.sourced, .sourced):
            return .verified
        case (.unknown, _), (_, .unknown):
            return .unknown
        case (_, .conflict):
            return .plausible
        case (_, .unsupported):
            return .unsupported
        default:
            // sourced/convention function with convention ratio: plausible.
            return .plausible
        }
    }
}
