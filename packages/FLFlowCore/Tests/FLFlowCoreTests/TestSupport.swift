import Foundation
import FLDomain
@testable import FLFlowCore

// MARK: - Test builders
// Deterministic builders so tests construct validated domain values without
// repeating every argument. Nothing here reaches production code.

enum TestBuilders {
    static func recipeKey(_ id: String, source: RecipeSource = .catalog, revision: Int = 1) -> RecipeKey {
        try! RecipeKey(source: source, sourceRecipeID: id, revision: revision)
    }

    static func ingredient(_ name: String, fdc: Int? = nil) -> IngredientReference {
        try! IngredientReference(
            fdc: fdc.map { try! FDCIngredientKey(fdcID: $0) },
            localIngredientID: nil,
            canonicalName: name
        )
    }

    static func grams(_ value: Double) -> QuantityEvidence {
        .sourceGrams(try! GramMass(grams: value))
    }

    static func line(
        _ lineID: String,
        _ name: String,
        _ quantity: QuantityEvidence,
        garnish: Bool = false
    ) -> IngredientLine {
        try! IngredientLine(
            lineID: lineID,
            ingredient: ingredient(name),
            quantity: quantity,
            isOptionalGarnish: garnish
        )
    }

    static func step(_ stepID: String, seconds: Int? = nil) -> Step {
        try! Step(stepID: stepID, action: "Do \(stepID)", durationSeconds: seconds)
    }

    /// A rights-clear license: every offline-relevant right granted.
    static func clearLicense() -> RecipeLicense {
        try! RecipeLicense(
            textRedistribution: .permitted,
            imageRedistribution: .permitted,
            modificationAllowed: .permitted,
            attributionRequired: false,
            cachingAllowed: .permitted,
            offlineUseAllowed: .permitted,
            evidence: "test: original recipe authored in the fixture"
        )
    }

    static func revision(
        _ id: String,
        lines: [IngredientLine],
        steps: [Step]? = nil,
        basisServings: Int = 2,
        source: RecipeSource = .catalog
    ) -> RecipeRevision {
        try! RecipeRevision(
            key: recipeKey(id, source: source),
            title: "Test \(id)",
            servingBasis: try! ServingBasis(servings: basisServings),
            ingredientLines: lines,
            steps: steps ?? [step("s1"), step("s2")],
            source: RecipeSourceEvidence(origin: source, attribution: nil, license: clearLicense())
        )
    }

    static func pantryLine(
        _ name: String,
        _ quantity: QuantityEvidence,
        confirmedAt: Date? = nil,
        source: String = "test receipt"
    ) -> FlowPantryLine {
        try! FlowPantryLine(canonicalName: name, quantity: quantity, lastConfirmedAt: confirmedAt, source: source)
    }

    static func restriction(
        allergens: Set<Allergen> = [],
        diets: Set<DietExclusion> = [],
        custom: Set<String> = []
    ) -> Restriction {
        try! Restriction(allergens: allergens, dietExclusions: diets, customExclusions: custom)
    }
}
