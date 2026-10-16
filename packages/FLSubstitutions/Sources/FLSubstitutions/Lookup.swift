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
    /// Both sides' per-100 g macros and the pair's typical original amount —
    /// the inputs the macro-delta method needs to compute an ALTERNATIVE
    /// role's delta from that role's own ratio. Captured at construction so
    /// the nutrition accessor needs no table reference; a missing side
    /// leaves that delta unknown (SPEC §3.5).
    let nutrition: NutritionInputs

    public var isRefused: Bool { recheck.isRefused }
    /// Unknown composition anywhere in the recheck — ask the user rather
    /// than offering silently.
    public var needsConfirmation: Bool { recheck.needsConfirmation }
    public var differenceText: String { pair.difference }
    public var preparation: [String] { pair.preparation }
    /// The macro delta for the REQUESTED role: the pair's recorded delta for
    /// the primary role; for an alternative role, computed from THAT role's
    /// own evidenced mass ratio — or nil, unknown nutrition, until that
    /// role's amount has evidence (PR #114 review round 2, fix 2). The
    /// primary delta never appears under another role's name.
    public var macroDelta: Macros? {
        guard requestedRole != pair.role else { return pair.macroDelta }
        return Self.macroDelta(
            ratio: ratio(for: requestedRole),
            originalPer100g: nutrition.originalPer100g,
            substitutePer100g: nutrition.substitutePer100g,
            typicalG: nutrition.typicalG
        )
    }
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

    /// The macro-delta method (data/substitutions/SCHEMA.md) on one ratio:
    /// substitute grams are the typical original amount × the ratio, kcal
    /// rounded to the nearest integer and the other nutrients to one
    /// decimal. Nil — unknown nutrition, never an approximation — when any
    /// input is missing, the amount is recorded `unknown`/`unsupported`, or
    /// the ratio is not a mass statement: a volume, count, or per-egg ratio
    /// is dimensionally invalid as a gram multiplier (review finding d).
    static func macroDelta(
        ratio: Ratio?, originalPer100g: Macros?, substitutePer100g: Macros?, typicalG: Double?
    ) -> Macros? {
        guard let ratio, let originalPer100g, let substitutePer100g, let typicalG else { return nil }
        switch ratio.status {
        case .sourced, .convention, .conflict:
            break // recorded amounts the verdict table trusts
        case .unknown, .unsupported:
            return nil // an amount with no (or refuted) evidence is not a computation input
        }
        guard massRatioBases.contains(ratio.basis) else { return nil }
        let substituteG = typicalG * ratio.value
        func delta(_ substitutePer100: Double, _ originalPer100: Double) -> Double {
            (substitutePer100 * substituteG - originalPer100 * typicalG) / 100
        }
        func oneDecimal(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        return Macros(
            kcal: delta(substitutePer100g.kcal, originalPer100g.kcal).rounded(),
            proteinG: oneDecimal(delta(substitutePer100g.proteinG, originalPer100g.proteinG)),
            carbsG: oneDecimal(delta(substitutePer100g.carbsG, originalPer100g.carbsG)),
            fatG: oneDecimal(delta(substitutePer100g.fatG, originalPer100g.fatG)),
            fiberG: oneDecimal(delta(substitutePer100g.fiberG, originalPer100g.fiberG)),
            sugarG: oneDecimal(delta(substitutePer100g.sugarG, originalPer100g.sugarG)),
            sodiumMg: oneDecimal(delta(substitutePer100g.sodiumMg, originalPer100g.sodiumMg))
        )
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

/// Ratio bases that are mass statements (data/substitutions/SCHEMA.md): the
/// only numeric values that scale grams. Every other basis is a kitchen-unit
/// statement, dimensionally invalid as a gram multiplier (review finding d).
let massRatioBases: Set<String> = ["weight", "weight-cooked"]

/// Nutrition inputs for the alternative-role macro delta (review round 2,
/// fix 2). See `SwapCandidate.nutrition`.
struct NutritionInputs: Sendable {
    let originalPer100g: Macros?
    let substitutePer100g: Macros?
    let typicalG: Double?
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
                    recheck: recheck,
                    nutrition: NutritionInputs(
                        originalPer100g: original.macrosPer100g,
                        substitutePer100g: substitute.macrosPer100g,
                        typicalG: pair.typicalAmountG
                    )
                )
            )
        }
        // Deterministic ranking: verdict first, then pair id. No ties survive.
        return candidates.sorted { lhs, rhs in
            if lhs.verdict != rhs.verdict { return lhs.verdict < rhs.verdict }
            return lhs.pair.id < rhs.pair.id
        }
    }

    /// The lookup's three-way verdict separation (PR #114 review round 2):
    /// only candidates with NO confirmation requirement are usable swaps;
    /// anything whose composition is unknown on either side of the recheck
    /// is a question for the eater, never a usable swap; the remainder is
    /// filtered from the offer.
    public struct ClassifiedSwaps: Sendable {
        /// Usable now: a `verified`/`plausible` verdict, no refusal, and no
        /// confirmation requirement anywhere in the recheck. A swap whose
        /// ORIGINAL is a known violation and whose substitute is known-safe
        /// lives here — removing the violation is the point of the swap.
        public let usable: [SwapCandidate]
        /// Composition unknown on the original or the substitute side, with
        /// no settled refusal in the way: surface as a question ("check the
        /// bottle"), never as a usable swap.
        public let needsConfirmation: [SwapCandidate]
        /// Everything the offer filters: settled substitute violations,
        /// conditional refusals, and context verdicts that are not evidence
        /// (`unknown`/`unsupported`) — including candidates that also need
        /// confirmation but are separately refused or evidence-less.
        public let refused: [SwapCandidate]
    }

    /// Every candidate for the lookup, separated into `usable` swaps,
    /// `needsConfirmation` questions, and the `refused` remainder. The
    /// buckets are disjoint and together contain every candidate
    /// `swapCandidates` returns; each bucket keeps the candidates'
    /// deterministic rank order.
    ///
    /// A candidate needing confirmation lands in `needsConfirmation` unless
    /// something else settles it first: a settled substitute violation or a
    /// conditional refusal refuses it outright, and a non-evidence context
    /// verdict keeps it filtered — confirming composition cannot promote
    /// either. Buttermilk → whole milk under vegetarian is the canonical
    /// first case: the original's composition is unknown, so the swap is a
    /// question even though the replacement (milk) is known-safe.
    public func classifiedSwaps(
        for ingredientName: String,
        role: Role,
        restrictions: [String]
    ) throws -> ClassifiedSwaps {
        var usable: [SwapCandidate] = []
        var needsConfirmation: [SwapCandidate] = []
        var refused: [SwapCandidate] = []
        for candidate in try swapCandidates(for: ingredientName, role: role, restrictions: restrictions) {
            let settledSubstituteRefusal =
                candidate.recheck.conditionalRefusal != nil
                || { if case .violated = candidate.recheck.outcome { return true } else { return false } }()
            let isEvidence = candidate.verdict == .verified || candidate.verdict == .plausible
            if candidate.needsConfirmation {
                // Unknown composition is a question, not a settled no —
                // unless the substitute side is separately settled refused,
                // or the context verdict carries no evidence to confirm for.
                if !settledSubstituteRefusal && isEvidence {
                    needsConfirmation.append(candidate)
                } else {
                    refused.append(candidate)
                }
            } else if candidate.isRefused || !isEvidence {
                refused.append(candidate)
            } else {
                usable.append(candidate)
            }
        }
        return ClassifiedSwaps(usable: usable, needsConfirmation: needsConfirmation, refused: refused)
    }

    /// Ranked swaps that are usable in this context and safe for every eater:
    /// verdicts `verified` or `plausible` only — `unknown` stays unknown and
    /// is never offered as if it were evidence, `unsupported` is never
    /// offered at all — and candidates the recheck refuses (a settled
    /// violation, unknown composition, or a conditional refusal) are filtered.
    /// A candidate needing confirmation is never usable, including when only
    /// the ORIGINAL ingredient's composition is unknown (buttermilk → whole
    /// milk under vegetarian); those surface in
    /// `classifiedSwaps(...).needsConfirmation`. Use `swapCandidates` for
    /// the full picture and `classifiedSwaps` for the three-way split.
    public func swaps(
        for ingredientName: String,
        role: Role,
        restrictions: [String]
    ) throws -> [SwapCandidate] {
        try classifiedSwaps(for: ingredientName, role: role, restrictions: restrictions).usable
    }

    /// Verified swaps for an ingredient across every role its pairs support
    /// (primary plus `supported_also`), for coverage reporting. One entry per
    /// (pair, role) that verifies and is safe for the given restrictions.
    /// A candidate needing confirmation is excluded here too — a coverage
    /// report must not count an unconfirmed composition as verified evidence
    /// (PR #114 review round 2).
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
                guard !recheck.isRefused && !recheck.needsConfirmation else { continue }
                out.append(SwapCandidate(
                    pair: pair,
                    requestedRole: role,
                    verdict: .verified,
                    recheck: recheck,
                    nutrition: NutritionInputs(
                        originalPer100g: original.macrosPer100g,
                        substitutePer100g: substitute.macrosPer100g,
                        typicalG: pair.typicalAmountG
                    )
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
