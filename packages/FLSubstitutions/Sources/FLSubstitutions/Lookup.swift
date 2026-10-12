import Foundation

/// One candidate swap for a lookup: the pair, the context verdict, and the
/// allergen-recheck result. Refused candidates carry the refusal in the
/// recheck (a settled store violation, unknown composition, or a conditional
/// refusal for the eater); `swaps(for:role:restrictions:)` filters them out.
public struct SwapCandidate: Sendable {
    public let pair: Pair
    /// The requested role this candidate was evaluated for.
    public let requestedRole: Role
    public let verdict: Verdict
    public let recheck: AllergenRecheck

    public var isRefused: Bool { recheck.isRefused }
    /// Unknown composition anywhere in the recheck — ask the user rather
    /// than offering silently.
    public var needsConfirmation: Bool { recheck.needsConfirmation }
    public var differenceText: String { pair.difference }
    public var preparation: [String] { pair.preparation }
    public var macroDelta: Macros? { pair.macroDelta }
    /// The PRIMARY role's ratio (the pair's own role). For an alternative
    /// requested role use `ratio(for:)` — the primary ratio must not leak
    /// into another role's scaling (review finding f).
    public var ratio: Ratio { pair.ratio }

    /// The ratio evidenced for THIS role: the pair's own ratio for the
    /// primary role, or the `supported_also` row's OWN ratio for an
    /// alternative role. Nil for an alternative role whose row carries no
    /// ratio yet — scaling is unavailable there until the amount is sourced
    /// and stored, rather than reusing the primary ratio.
    public func ratio(for role: Role) -> Ratio? {
        if role == pair.role { return pair.ratio }
        return pair.supportedAlso.first { $0.role == role }?.ratio
    }

    /// Substitute grams for a given original amount, for the requested role.
    /// Only defined when THAT role's ratio basis is `weight`; other bases are
    /// kitchen-unit statements (see the ratio note) and are never silently
    /// converted.
    public func scaledSubstituteGrams(originalGrams: Double, role: Role) -> Double? {
        guard let ratio = ratio(for: role), ratio.basis == "weight" else { return nil }
        return originalGrams * ratio.value
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
        guard let original = ingredients[key] else {
            throw SubstitutionError.unknownIngredient(key)
        }

        var candidates: [SwapCandidate] = []
        for pair in pairs(forOriginal: key) where pairConnects(pair, to: role) {
            // Load validation guarantees every pair's keys resolve.
            guard let substitute = ingredients[pair.substitute] else {
                throw SubstitutionError.invalidData("pair \(pair.id): missing substitute record")
            }
            let recheck = AllergenRecheck(
                originalName: original.display,
                original: original,
                substitute: substitute,
                set: restrictionSet,
                table: self,
                conditionalRefusal: conditionalRefusal(for: pair, role: role, set: restrictionSet)
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
    /// offered at all — and candidates the recheck refuses (a settled
    /// violation, unknown composition, or a conditional refusal) are filtered.
    /// Use `swapCandidates` for the full picture.
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
        guard let original = ingredients[key] else {
            throw SubstitutionError.unknownIngredient(key)
        }

        var out: [SwapCandidate] = []
        for pair in pairs(forOriginal: key) {
            var roles: [Role] = [pair.role]
            roles.append(contentsOf: pair.supportedAlso.map(\.role))
            for role in roles.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard ContextRules.verdict(for: pair, requestedRole: role) == .verified else { continue }
                // Load validation guarantees every pair's keys resolve.
                guard let substitute = ingredients[pair.substitute] else {
                    throw SubstitutionError.invalidData("pair \(pair.id): missing substitute record")
                }
                let recheck = AllergenRecheck(
                    originalName: original.display,
                    original: original,
                        substitute: substitute,
                    set: restrictionSet,
                    table: self,
                    conditionalRefusal: conditionalRefusal(for: pair, role: role, set: restrictionSet)
                )
                guard !recheck.isRefused else { continue }
                out.append(SwapCandidate(
                    pair: pair,
                    requestedRole: role,
                    verdict: .verified,
                    recheck: recheck
                ))
            }
        }
        return out
    }

    /// A CONDITIONAL failure row refuses the swap when the eater's
    /// restrictions include one the row names. Kept separate from the
    /// context verdict so sourced ratio evidence cannot launder a
    /// restriction refusal into an offer (review finding e), and functional
    /// rows never reach here — they make the verdict `unsupported` outright.
    private func conditionalRefusal(for pair: Pair, role: Role, set: RestrictionSet) -> String? {
        for fail in pair.fails where fail.role == role && fail.kind == .conditional {
            let hits = (fail.restrictions ?? []).filter { set.names.contains($0) }
            if !hits.isEmpty {
                return "\(hits.joined(separator: ", ")): \(fail.why)"
            }
        }
        return nil
    }

    private func pairConnects(_ pair: Pair, to role: Role) -> Bool {
        if pair.role == role { return true }
        if pair.supportedAlso.contains(where: { $0.role == role }) { return true }
        if pair.fails.contains(where: { $0.role == role }) { return true }
        return false
    }
}
