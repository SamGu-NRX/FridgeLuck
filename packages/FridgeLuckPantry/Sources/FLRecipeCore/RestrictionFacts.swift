import Foundation
import FLDomain
import FLIngredientFacts

// MARK: - Composition truth (Review round 2)
//
// The feasibility engine used to judge hard restrictions on canonical names
// alone: `Restriction.permits(canonicalName:)` defaulted the allergen and
// diet arguments to empty sets, so an undeclared composition read as "no
// allergens, no diet conflicts" and unknown passed as safe — a milk-allergic
// household could be served a complete cream-cheese recipe, and a swap to
// any substitute not named in the custom exclusions rescued a line.
//
// Composition now comes from the facts source. Its verdicts are allowed,
// violated, or unknown, and unknown never counts as allowed: a line whose
// composition the facts source cannot decide against the household's
// restrictions becomes `needsConfirmation` — a refusal to serve, distinct
// from a household's explicit prohibition so the app can ask the cook
// instead of merely rejecting.

/// The seam the engine consumes: composition verdicts for canonical
/// ingredient names against a restriction set. The canonical
/// `FLIngredientFactsStore` conforms; tests inject deterministic fakes.
public protocol FLIngredientFactsEvaluating: Sendable {
    func evaluate(ingredient: String, restrictions: FLRestrictions) -> FLEvaluation
}

extension FLIngredientFactsStore: FLIngredientFactsEvaluating {}

extension Restriction {
    /// The facts-package view of this restriction: the allergen and diet
    /// axes the facts dataset models, as `FLRestrictions`.
    ///
    /// Axis mapping (the dataset README pins wheat and gluten as independent
    /// axes):
    /// - `Allergen.gluten` maps onto the dataset's `glutenFree` diet axis,
    ///   the only form the dataset carries it in. An ingredient without a
    ///   gluten fact evaluates to unknown — never allowed.
    /// - `DietExclusion.lactoseFree` maps onto `dairyFree`, the stricter
    ///   axis: a false block costs a confirmation prompt, a false pass
    ///   serves dairy.
    /// - `halal`, `kosher`, `lowSodium`, `noPork` and `noAlcohol` have no
    ///   facts axis yet; they stay enforced through the name-based custom
    ///   exclusions, and the gap is recorded in the PR Handoff.
    public var factsRestrictions: FLRestrictions {
        var mappedDiets: Set<FLDiet> = []
        for diet in dietExclusions {
            switch diet {
            case .vegetarian: mappedDiets.insert(.vegetarian)
            case .vegan: mappedDiets.insert(.vegan)
            case .pescatarian: mappedDiets.insert(.pescatarian)
            case .lactoseFree: mappedDiets.insert(.dairyFree)
            case .halal, .kosher, .lowSodium, .noPork, .noAlcohol:
                continue
            }
        }
        for allergen in allergens where allergen == .gluten {
            mappedDiets.insert(.glutenFree)
        }
        var mappedAllergens: Set<FLAllergen> = []
        for allergen in allergens {
            switch allergen {
            case .peanuts: mappedAllergens.insert(.peanuts)
            case .treeNuts: mappedAllergens.insert(.treeNuts)
            case .milk: mappedAllergens.insert(.milk)
            case .eggs: mappedAllergens.insert(.egg)
            case .wheat: mappedAllergens.insert(.wheat)
            case .soy: mappedAllergens.insert(.soy)
            case .fish: mappedAllergens.insert(.fish)
            case .shellfish: mappedAllergens.insert(.crustaceanShellfish)
            case .sesame: mappedAllergens.insert(.sesame)
            case .gluten: continue // carried as the glutenFree diet axis above
            }
        }
        return FLRestrictions(allergens: mappedAllergens, diets: mappedDiets)
    }
}

/// The engine's restriction verdict for one ingredient: proceed only when
/// the facts source settles every modeled axis as acceptable.
enum FLRestrictionVerdict {
    case proceed
    /// A custom exclusion or a facts violation forbids the ingredient.
    case blocked(String)
    /// The facts source cannot decide the composition against this
    /// household's restrictions. Refuse to serve; ask for confirmation.
    case needsConfirmation(String)
}

/// Judges one ingredient against one household restriction set: the
/// name-based custom-exclusion layer first (the household named the
/// ingredient itself — known and absolute), then the facts verdict, where
/// unknown composition is a refusal, never a pass. The facts consult arms
/// only when the household's restrictions name allergen or diet axes; a
/// name-only or empty restriction leaves the facts source nothing to
/// settle, so an unfactored ingredient cannot fail closed there.
func restrictionVerdict(
    restriction: Restriction,
    facts: FLIngredientFactsEvaluating,
    canonicalName: String
) -> FLRestrictionVerdict {
    if restriction.excludes(canonicalName: canonicalName) {
        return .blocked("'" + canonicalName + "' is excluded by this household's hard restrictions")
    }
    let axes = restriction.factsRestrictions
    if axes.allergens.isEmpty && axes.diets.isEmpty {
        return .proceed
    }
    switch facts.evaluate(ingredient: canonicalName, restrictions: axes) {
    case .allowed:
        return .proceed
    case .violated(let violation):
        return .blocked("'" + canonicalName + "' is excluded by this household's hard restrictions: " + violation.reason)
    case .unknown(let unknown):
        var reason = "'" + canonicalName + "' needs confirmation: " + unknown.reason
        if !unknown.missing.isEmpty {
            reason += " — " + unknown.missing.joined(separator: "; ")
        }
        return .needsConfirmation(reason)
    }
}
