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
    /// - A FUNCTIONAL failure row is absolute: the substitute cannot perform
    ///   the role, and evidence for an amount does not create the function —
    ///   a sourced ratio can never override it (review finding e).
    /// - A CONDITIONAL failure row does not block the verdict: the swap works
    ///   in general and is refused at the recheck layer for the eaters the
    ///   row names (e.g. seitan as protein is refused for gluten-free).
    /// - `verified` requires BOTH sourced function evidence and sourced ratio
    ///   evidence (PR #49 semantics). A conflicting ratio never verifies.
    /// - Unknown function or ratio evidence stays `unknown`.
    /// - A pair with no row connecting it to the requested role is `unknown`
    ///   (or `unsupported` with the recorded reason when the pair records a
    ///   FUNCTIONAL failure for that role).
    public static func verdict(for pair: Pair, requestedRole role: Role) -> Verdict {
        let ratioStatus: EvidenceStatus
        if role == pair.role {
            ratioStatus = pair.ratio.status
        } else if let also = pair.supportedAlso.first(where: { $0.role == role }) {
            ratioStatus = also.status
        } else {
            // No ratio row connects the pair to this role. A functional
            // failure row still rules the role out; a conditional row is a
            // restriction note, not evidence either way.
            if let fail = pair.fails.first(where: { $0.role == role }), fail.kind == .functional {
                return .unsupported
            }
            return .unknown
        }

        // Functional failures cannot be outvoted by ratio evidence.
        if let fail = pair.fails.first(where: { $0.role == role }), fail.kind == .functional {
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
