import Foundation

// MARK: - Feasibility oracle (port of oracle.py)

/// Verdict of the data-model oracle for one (state, recipe) pair.
struct OracleVerdict: Codable {
    var feasible: Bool
    var infeasible_reasons: [String]
    var missing_required_ids: [Int64]
    var excluded_ids: [Int64]
    var tag_violation: Bool
    /// Required ingredient IDs whose grams are satisfied only by presence of an
    /// unknown (estimated) quantity — never invented figures.
    var unknown_quantity_assumptions: [Int64]
    var insufficient: [InsufficientRow]

    struct InsufficientRow: Codable {
        var ingredient_id: Int64
        var required_grams: Double
        var available_grams: Double
    }
}

enum ReplayOracle {
    /// Available IDs: pantry IDs present with a known positive quantity.
    /// Unknown (estimated) lots are presence-only assumptions and never
    /// contribute grams; zero-remaining lots are exhausted.
    static func availableIDs(_ state: EvalState) -> Set<Int64> {
        var ids: Set<Int64> = []
        for lot in state.pantry where !lot.is_estimate && (lot.known_grams ?? 0) > 0 {
            ids.insert(lot.ingredient_id)
        }
        return ids
    }

    static func evaluate(
        state: EvalState, recipe: CatalogRecipe
    ) -> OracleVerdict {
        let profile = EvalHealthProfile(from: state.profile)
        let excluded = profile.effectiveAllergenExclusionIds
            .union(profile.dietaryExcludedIngredientIds)

        var missing: [Int64] = []
        var excludedHit: [Int64] = []
        var unknownAssumptions: [Int64] = []
        var insufficient: [OracleVerdict.InsufficientRow] = []

        let available = availableIDs(state)

        // Exclusions cover EVERY recipe row: an allergen in an optional row
        // still makes the dish unsafe for this user.
        for (id, _) in recipe.requiredPairs where excluded.contains(id) {
            excludedHit.append(id)
        }
        for (id, _) in recipe.optionalPairs where excluded.contains(id) {
            excludedHit.append(id)
        }
        excludedHit.sort()

        let requiredMask = profile.requiredRecipeTagMask
        let tagViolation = requiredMask != 0 && (recipe.tags & requiredMask) != requiredMask

        for (id, requiredGrams) in recipe.requiredPairs where !excluded.contains(id) {
            let lots = state.pantry.filter { $0.ingredient_id == id }
            if lots.isEmpty {
                if !available.contains(id) {
                    missing.append(id)
                    continue
                }
            }
            if lots.isEmpty { continue }

            var knownTotal = 0.0
            var hasUnknown = false
            for lot in lots {
                if lot.is_estimate {
                    hasUnknown = true
                } else if let grams = lot.known_grams {
                    knownTotal += grams
                }
            }
            if hasUnknown {
                // Presence with an unknown amount can never refute feasibility.
                // The requirement is met on an explicit assumption; no gram
                // figure is invented anywhere.
                unknownAssumptions.append(id)
            } else if knownTotal < requiredGrams {
                insufficient.append(
                    OracleVerdict.InsufficientRow(
                        ingredient_id: id,
                        required_grams: requiredGrams,
                        available_grams: knownTotal))
            }
        }
        missing.sort()
        unknownAssumptions.sort()

        var reasons: [String] = []
        if !missing.isEmpty { reasons.append("missing_required_ingredient") }
        if !insufficient.isEmpty { reasons.append("insufficient_known_quantity") }
        if !excludedHit.isEmpty { reasons.append("excluded_ingredient") }
        if tagViolation { reasons.append("diet_tag_violation") }

        return OracleVerdict(
            feasible: reasons.isEmpty,
            infeasible_reasons: reasons,
            missing_required_ids: missing,
            excluded_ids: excludedHit,
            tag_violation: tagViolation,
            unknown_quantity_assumptions: unknownAssumptions,
            insufficient: insufficient.sorted { $0.ingredient_id < $1.ingredient_id })
    }
}

// MARK: - Production predicate (transcribed)

/// What production's `RecipeRepository.findMakeable` would return for a state,
/// transcribed from `apps/ios/Platform/Persistence/Repository/RecipeRepository.swift`.
/// Production matches on ingredient-ID membership over `availableIds` — a
/// zero-remaining or sub-quantity pantry never blocks a recipe whose IDs are
/// present. Allergen exclusion covers every recipe row, and the diet tag mask
/// filters recipes before matching, matching the production SQL.
struct ProductionVerdict: Codable {
    var makeable: Bool
    var missing_required_ids: [Int64]
    var excluded: Bool
    var tag_violation: Bool
}

enum ProductionPredicate {
    static func evaluate(
        state: EvalState, recipe: CatalogRecipe
    ) -> ProductionVerdict {
        let profile = EvalHealthProfile(from: state.profile)
        let excluded = profile.effectiveAllergenExclusionIds
            .union(profile.dietaryExcludedIngredientIds)
        let available = state.availableIDSet

        let excludedHit =
            recipe.requiredPairs.contains { excluded.contains($0.0) }
            || recipe.optionalPairs.contains { excluded.contains($0.0) }

        let requiredMask = profile.requiredRecipeTagMask
        let tagViolation = requiredMask != 0 && (recipe.tags & requiredMask) != requiredMask

        var missing: [Int64] = []
        for (id, _) in recipe.requiredPairs where !available.contains(id) {
            missing.append(id)
        }
        missing.sort()

        return ProductionVerdict(
            makeable: missing.isEmpty && !excludedHit && !tagViolation,
            missing_required_ids: missing,
            excluded: excludedHit,
            tag_violation: tagViolation)
    }
}
