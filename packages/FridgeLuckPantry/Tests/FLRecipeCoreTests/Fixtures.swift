import XCTest
import FLDomain
import FLInventoryCore
import FLIngredientFacts
@testable import FLRecipeCore

/// Shared synthetic fixtures for the feasibility tests. Recipes are built
/// through Part 1's validated constructors; pantry stock is built through the
/// real fold over synthetic events, so a fixture can never drift from the
/// evidence model it feeds.
enum RecipeFixtures {
    static func makeLine(
        _ lineID: String,
        ingredient: IngredientReference,
        grams: Double?,
        preparation: String? = nil,
        isOptionalGarnish: Bool = false
    ) throws -> IngredientLine {
        try IngredientLine(
            lineID: lineID,
            ingredient: ingredient,
            quantity: grams.map { try QuantityEvidence.sourceGrams(GramMass(grams: $0)) } ?? .unknown,
            preparation: preparation,
            isOptionalGarnish: isOptionalGarnish
        )
    }

    static func makeLicense() throws -> RecipeLicense {
        try RecipeLicense(
            textRedistribution: .permitted,
            imageRedistribution: .permitted,
            modificationAllowed: .permitted,
            attributionRequired: false,
            cachingAllowed: .permitted,
            offlineUseAllowed: .permitted,
            evidence: "author declaration recorded at import"
        )
    }

    static func makeRecipe(
        _ lines: [IngredientLine],
        title: String = "Test Recipe"
    ) throws -> RecipeRevision {
        try RecipeRevision(
            key: RecipeKey(source: .user, sourceRecipeID: "test-recipe", revision: 1),
            title: title,
            servingBasis: ServingBasis(servings: 2),
            ingredientLines: lines,
            steps: [Step(stepID: "s1", action: "Cook everything together")],
            source: RecipeSourceEvidence(origin: .user, attribution: nil, license: makeLicense())
        )
    }

    static func ingredient(
        _ name: String,
        fdc: Int? = nil,
        local: Int64? = nil
    ) -> IngredientReference {
        try! IngredientReference(
            fdc: fdc.map { try! FDCIngredientKey(fdcID: $0) },
            localIngredientID: local,
            canonicalName: name
        )
    }

    static func purchase(
        _ id: String,
        ingredient: IngredientReference,
        grams: Double?,
        preparation: String? = nil,
        household: FLHouseholdID = try! FLHouseholdID("hh-test-1"),
        timestamp: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: "cmd-\(id)",
            householdID: household,
            kind: .purchase,
            ingredient: ingredient,
            quantity: grams.map { try! QuantityEvidence.sourceGrams(GramMass(grams: $0)) } ?? .unknown,
            preparation: preparation,
            source: .receipt,
            timestamp: timestamp
        )
    }

    static func consume(
        _ id: String,
        ingredient: IngredientReference,
        grams: Double?,
        preparation: String? = nil,
        household: FLHouseholdID = try! FLHouseholdID("hh-test-1"),
        timestamp: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> FLStockEvent {
        try! FLStockEvent(
            id: id,
            commandID: "cmd-\(id)",
            householdID: household,
            kind: .consumption,
            ingredient: ingredient,
            quantity: grams.map { try! QuantityEvidence.sourceGrams(GramMass(grams: $0)) } ?? .unknown,
            preparation: preparation,
            source: .manual,
            timestamp: timestamp
        )
    }

    /// Stock built the real way: fold synthetic purchase events.
    static func stock(_ events: [FLStockEvent]) throws -> [FLItemStock] {
        try FLStockFold.fold(events: events)
    }

    static func expectRefusal(
        _ expected: FLDomainError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () throws -> Void
    ) {
        do {
            try block()
            XCTFail("expected a validation error, got none", file: file, line: line)
        } catch let error as FLDomainError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: Composition facts (Review round 2)

    /// A deterministic in-memory facts source: each entry states the
    /// allergens an ingredient carries and the diet tags it fails, in the
    /// facts package's own axis vocabulary. An ingredient with no entry is
    /// unknown — exactly the case the seam must refuse, never pass.
    struct FixtureFacts: FLIngredientFactsEvaluating {
        struct Entry {
            var allergens: Set<FLAllergen> = []
            var dietTags: Set<FLDiet> = []
        }

        var entries: [String: Entry]

        init(entries: [String: Entry]) {
            self.entries = entries
        }

        func evaluate(ingredient: String, restrictions: FLRestrictions) -> FLEvaluation {
            let key = ingredient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let entry = entries[key] else {
                let axis: FLRestriction
                if let allergen = restrictions.allergens.first {
                    axis = .allergen(allergen)
                } else if let diet = restrictions.diets.first {
                    axis = .diet(diet)
                } else {
                    axis = .allergen(.milk)
                }
                return .unknown(FLUnknown(
                    ingredient: key,
                    restriction: axis,
                    missing: ["no facts entry for '\(key)'"],
                    reason: "facts do not settle the restricted properties"
                ))
            }
            let violatedAllergens = entry.allergens.intersection(restrictions.allergens)
            let violatedDiets = entry.dietTags.intersection(restrictions.diets)
            for allergen in violatedAllergens.sorted(by: { $0.rawValue < $1.rawValue }) {
                return .violated(FLViolation(
                    ingredient: key,
                    restriction: .allergen(allergen),
                    reason: "'\(key)' is not '\(allergen.rawValue)'-free",
                    evidence: []
                ))
            }
            for diet in violatedDiets.sorted(by: { $0.rawValue < $1.rawValue }) {
                return .violated(FLViolation(
                    ingredient: key,
                    restriction: .diet(diet),
                    reason: "'\(key)' does not satisfy '\(diet.rawValue)'",
                    evidence: []
                ))
            }
            return .allowed([])
        }
    }

    /// Every fixture ingredient resolves to known, property-free composition:
    /// the pre-fix behavior for everything except what a test declares.
    static let allKnownEmpty = FixtureFacts(entries: [:])

    /// Fixture facts for the round-2 regressions: cream cheese carries milk
    /// and fails vegan; butter fails vegan. Absent entries (like stock cube's
    /// brand-dependent composition in the real dataset) stay unknown.
    static let round2Fixtures = FixtureFacts(entries: [
        "cream cheese": FixtureFacts.Entry(allergens: [.milk], dietTags: [.vegan, .dairyFree]),
        "butter": FixtureFacts.Entry(dietTags: [.vegan, .dairyFree]),
        // Known-clean: the entry exists and settles every axis as free.
        "olive oil": FixtureFacts.Entry(),
        // Known-clean AND not an assumed staple, so a refused swap falls
        // through to missing instead of the staple assumption.
        "tahini": FixtureFacts.Entry(),
    ])

}
