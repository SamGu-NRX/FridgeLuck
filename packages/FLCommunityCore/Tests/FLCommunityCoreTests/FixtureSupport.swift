import XCTest
import FLDomain
@testable import FLCommunityCore

/// Builders shared by the FLCommunityCore test suites. Everything is
/// synthetic: invented households, invented recipes, fixed timestamps.
enum TestSupport {
    static func date(_ iso: String) throws -> Date {
        try FLTimestamp.decode(iso, target: "test")
    }

    static func license(
        text: RecipeLicense.Grant = .permitted,
        image: RecipeLicense.Grant = .permitted,
        modification: RecipeLicense.Grant = .permitted,
        caching: RecipeLicense.Grant = .permitted,
        offline: RecipeLicense.Grant = .permitted,
        attributionRequired: Bool = false,
        evidence: String = "author declaration recorded 2026-09-01: household original"
    ) throws -> RecipeLicense {
        try RecipeLicense(
            textRedistribution: text,
            imageRedistribution: image,
            modificationAllowed: modification,
            attributionRequired: attributionRequired,
            cachingAllowed: caching,
            offlineUseAllowed: offline,
            evidence: evidence
        )
    }

    static func ingredientLine(
        _ name: String,
        lineID: String,
        grams: Double = 200,
        garnish: Bool = false
    ) throws -> IngredientLine {
        try IngredientLine(
            lineID: lineID,
            ingredient: IngredientReference(canonicalName: name),
            quantity: .weighedGrams(GramMass(grams: grams)),
            isOptionalGarnish: garnish
        )
    }

    static func step(_ id: String, _ action: String, durationSeconds: Int? = nil) throws -> Step {
        try Step(stepID: id, action: action, durationSeconds: durationSeconds)
    }

    static func revision(
        origin: RecipeSource = .user,
        slug: String = "paneer-tikka",
        revisionNumber: Int = 3,
        license: RecipeLicense,
        ingredients: [String] = ["paneer", "yogurt", "paprika"],
        garnish: [String] = [],
        attribution: String? = nil,
        title: String = "Paneer Tikka"
    ) throws -> RecipeRevision {
        try RecipeRevision(
            key: RecipeKey(source: origin, sourceRecipeID: slug, revision: revisionNumber),
            title: title,
            servingBasis: ServingBasis(servings: 2),
            ingredientLines:
                ingredients.enumerated().map { index, name in
                    try ingredientLine(name, lineID: "line-\(index + 1)")
                }
                + garnish.enumerated().map { index, name in
                    try ingredientLine(name, lineID: "garnish-\(index + 1)", garnish: true)
                },
            steps: [try step("step-1", "Toss everything and roast", durationSeconds: 900)],
            source: RecipeSourceEvidence(origin: origin, attribution: attribution, license: license)
        )
    }

    static func cook(
        id: String,
        key: RecipeKey,
        completedAt: Date,
        rating: Int = 5,
        substitutions: [CookSubstitution] = [],
        note: String? = nil,
        startedAt: Date? = nil,
        servings: Int = 2
    ) throws -> Cook {
        try Cook(
            id: id,
            recipeRevision: key,
            servings: servings,
            substitutions: substitutions,
            rating: rating,
            note: note,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    static func substitution(from fromName: String, to toName: String, necessity: CookSubstitution.Necessity = .preferred) throws -> CookSubstitution {
        try CookSubstitution(
            from: IngredientReference(canonicalName: fromName),
            to: IngredientReference(canonicalName: toName),
            necessity: necessity
        )
    }

    static func declaration(
        kind: RecipeRightsDeclaration.Kind = .ownWork,
        statement: String = "original recipe written by me",
        declaredAt: Date
    ) throws -> RecipeRightsDeclaration {
        try RecipeRightsDeclaration(kind: kind, statement: statement, declaredAt: declaredAt)
    }

    static func payload(
        license: RecipeLicense,
        origin: RecipeSource = .user,
        sharedAt: Date,
        declarationKind: RecipeRightsDeclaration.Kind = .ownWork
    ) throws -> RecipeSharePayload {
        try RecipeSharePayload(
            revision: try revision(origin: origin, license: license),
            declaration: try declaration(declaredAt: sharedAt),
            sharedAt: sharedAt
        )
    }

    static func correction(_ id: String, _ mode: EventCorrection.Mode) throws -> EventCorrection {
        EventCorrection(priorEventID: try PreferenceEventID(id), mode: mode)
    }

    static func profileSentence(layer: ProfileSentence.Layer = .inferredTaste) throws -> ProfileSentence {
        try ProfileSentence(
            sentenceID: "sentence-coriander-removal",
            text: "You removed coriander 4 of the 5 times it was in a recipe you cooked",
            layer: layer,
            evidence: "removed coriander in 4 of 5 cooks that called for it",
            evidenceRevision: RecipeKey(source: .user, sourceRecipeID: "coriander-signals", revision: 1)
        )
    }

    static func profileEvent(
        _ id: String,
        sentence: ProfileSentence,
        verdict: ProfileSentenceVerdict,
        at iso: String,
        supersedes: EventCorrection? = nil
    ) throws -> PreferenceEvent {
        try PreferenceEvent(
            id: id,
            kind: .profileEdit,
            timestamp: try date(iso),
            recipeRevision: sentence.evidenceRevision,
            source: .userExplicit,
            supersedes: supersedes,
            sentenceID: sentence.sentenceID,
            verdict: verdict
        )
    }
}
