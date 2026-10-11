import XCTest
import FLDomain
import FLInventoryCore
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
}
