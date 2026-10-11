import Foundation

/// One candidate swap for a lookup: the pair, the context verdict, and the
/// allergen-recheck result. Refused candidates carry the violated classes;
/// `swaps(for:role:restrictions:)` filters them out.
public struct SwapCandidate: Sendable {
    public let pair: Pair
    /// The requested role this candidate was evaluated for.
    public let requestedRole: Role
    public let verdict: Verdict
    public let recheck: AllergenRecheck

    public var isRefused: Bool { recheck.isRefused }
    public var differenceText: String { pair.difference }
    public var preparation: [String] { pair.preparation }
    public var macroDelta: Macros? { pair.macroDelta }
    public var ratio: Ratio { pair.ratio }

    /// Substitute grams for a given original amount. Only defined when the
    /// ratio basis is `weight`; other bases are kitchen-unit statements
    /// (see the ratio note) and are never silently converted.
    public func scaledSubstituteGrams(originalGrams: Double) -> Double? {
        guard pair.ratio.basis == "weight" else { return nil }
        return originalGrams * pair.ratio.value
    }
}

extension SubstitutionTable {
    /// All candidates connecting `ingredientName` to `role`, ranked
    /// deterministically (verdict, then pair id). Pairs with no row
    /// connecting them to the role are not candidates at all.
    ///
    /// Ingredient is resolved by key, display name, or alias; unknown
    /// ingredients and unknown restriction names throw.
    public func swapCandidates(
        for ingredientName: String,
        role: Role,
        restrictions: [String]
    ) throws -> [SwapCandidate] {
        let key = try resolveIngredientKey(ingredientName)
        let restrictionSet = try RestrictionSet(names: restrictions, table: self)
        let originalClasses = sortedClasses(ingredients[key]?.classes ?? [])

        var candidates: [SwapCandidate] = []
        for pair in pairs(forOriginal: key) where pairConnects(pair, to: role) {
            let substituteClasses = sortedClasses(ingredients[pair.substitute]?.classes ?? [])
            let violated = sortedClasses(substituteClasses.filter { restrictionSet.forbidden.contains($0) })
            let introduced = sortedClasses(substituteClasses.filter { !originalClasses.contains($0) })
            let removed = sortedClasses(originalClasses.filter { !substituteClasses.contains($0) })
            let recheck = AllergenRecheck(
                originalClasses: originalClasses,
                substituteClasses: substituteClasses,
                introduced: introduced,
                removed: removed,
                violated: violated
            )
            candidates.append(
                SwapCandidate(
                    pair: pair,
                    requestedRole: role,
                    verdict: ContextRules.verdict(for: pair, requestedRole: role),
                    recheck: recheck
                )
            )
        }
        // Deterministic ranking: verdict first, then pair id. No ties survive.
        return candidates.sorted { lhs, rhs in
            if lhs.verdict != rhs.verdict { return lhs.verdict < rhs.verdict }
            return lhs.pair.id < rhs.pair.id
        }
    }

    /// Ranked swaps that are usable in this context and safe for every eater:
    /// verdicts `verified` or `plausible` only — `unknown` stays unknown and
    /// is never offered as if it were evidence, `unsupported` is never
    /// offered at all — and candidates whose substitute would violate a
    /// restriction are refused. Use `swapCandidates` for the full picture.
    public func swaps(
        for ingredientName: String,
        role: Role,
        restrictions: [String]
    ) throws -> [SwapCandidate] {
        try swapCandidates(for: ingredientName, role: role, restrictions: restrictions)
            .filter { candidate in
                guard !candidate.isRefused else { return false }
                return candidate.verdict == .verified || candidate.verdict == .plausible
            }
    }

    /// Verified swaps for an ingredient across every role its pairs support
    /// (primary plus `supported_also`), for coverage reporting. One entry per
    /// (pair, role) that verifies and is safe for the given restrictions.
    public func verifiedSwaps(
        for ingredientName: String,
        restrictions: [String]
    ) throws -> [SwapCandidate] {
        let key = try resolveIngredientKey(ingredientName)
        let restrictionSet = try RestrictionSet(names: restrictions, table: self)
        let originalClasses = sortedClasses(ingredients[key]?.classes ?? [])

        var out: [SwapCandidate] = []
        for pair in pairs(forOriginal: key) {
            var roles: [Role] = [pair.role]
            roles.append(contentsOf: pair.supportedAlso.map(\.role))
            for role in roles.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard ContextRules.verdict(for: pair, requestedRole: role) == .verified else { continue }
                let substituteClasses = sortedClasses(ingredients[pair.substitute]?.classes ?? [])
                let violated = sortedClasses(substituteClasses.filter { restrictionSet.forbidden.contains($0) })
                guard violated.isEmpty else { continue }
                out.append(SwapCandidate(
                    pair: pair,
                    requestedRole: role,
                    verdict: .verified,
                    recheck: AllergenRecheck(
                        originalClasses: originalClasses,
                        substituteClasses: substituteClasses,
                        introduced: sortedClasses(substituteClasses.filter { !originalClasses.contains($0) }),
                        removed: sortedClasses(originalClasses.filter { !substituteClasses.contains($0) }),
                        violated: []
                    )
                ))
            }
        }
        return out
    }

    private func pairConnects(_ pair: Pair, to role: Role) -> Bool {
        if pair.role == role { return true }
        if pair.supportedAlso.contains(where: { $0.role == role }) { return true }
        if pair.fails.contains(where: { $0.role == role }) { return true }
        return false
    }
}
