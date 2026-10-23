import XCTest
@testable import FLDomain

final class IdentityAndQuantityTests: XCTestCase {
    // MARK: RecipeKey

    func testRecipeKeyTrimsAndValidates() throws {
        let key = try RecipeKey(source: .user, sourceRecipeID: "  pancakes  ", revision: 1)
        XCTAssertEqual(key.sourceRecipeID, "pancakes")
        XCTAssertEqual(key.description, "user:pancakes@r1")
        XCTAssertThrowsError(try RecipeKey(source: .user, sourceRecipeID: "   ", revision: 1))
        XCTAssertThrowsError(try RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 0))
        XCTAssertThrowsError(try RecipeKey(source: .user, sourceRecipeID: String(repeating: "x", count: 257), revision: 1))
    }

    func testRecipeKeyRoundTrip() throws {
        let key = try RecipeKey(source: .community, sourceRecipeID: "chili", revision: 3)
        let decoded = try FLJSON.canonicalDecoder().decode(RecipeKey.self, from: FLJSON.canonicalData(key))
        XCTAssertEqual(decoded, key)
    }

    func testRecipeKeyDecodeRunsValidation() throws {
        let json = #"{"source":"user","sourceRecipeID":" ","revision":1}"#
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(RecipeKey.self, from: Data(json.utf8)))
    }

    // MARK: FDCIngredientKey

    func testFDCIngredientKeyRequiresPositiveID() {
        XCTAssertNoThrow(try FDCIngredientKey(fdcID: 171910))
        XCTAssertThrowsError(try FDCIngredientKey(fdcID: 0))
        XCTAssertThrowsError(try FDCIngredientKey(fdcID: -1))
    }

    // MARK: IngredientReference

    func testIngredientReferenceValidation() throws {
        let reference = try IngredientReference(
            fdc: try FDCIngredientKey(fdcID: 171910),
            localIngredientID: 42,
            canonicalName: " whole milk ",
            resolverVersion: 1
        )
        XCTAssertEqual(reference.canonicalName, "whole milk")
        XCTAssertEqual(reference.localIngredientID, 42)

        XCTAssertThrowsError(try IngredientReference(canonicalName: "  "))
        XCTAssertThrowsError(try IngredientReference(canonicalName: "milk", resolverVersion: 0))
        XCTAssertNoThrow(try IngredientReference(canonicalName: "milk"))
    }

    func testIngredientReferenceRoundTrip() throws {
        let reference = try IngredientReference(
            fdc: try FDCIngredientKey(fdcID: 171910),
            canonicalName: "whole milk",
            resolverVersion: 2
        )
        let decoded = try FLJSON.canonicalDecoder().decode(IngredientReference.self, from: FLJSON.canonicalData(reference))
        XCTAssertEqual(decoded, reference)
    }

    // MARK: RecipeIdentityMapping

    private func makeMapping() throws -> RecipeIdentityMapping {
        try RecipeIdentityMapping(
            schemaVersion: 1,
            entries: [
                try .init(
                    key: RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1),
                    localRowID: 7
                ),
                try .init(
                    key: RecipeKey(source: .catalog, sourceRecipeID: "waffles", revision: 2),
                    localRowID: 9
                ),
            ]
        )
    }

    func testIdentityMappingLookups() throws {
        let mapping = try makeMapping()
        let pancakes = try RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1)
        XCTAssertEqual(mapping.localRowID(for: pancakes), 7)
        XCTAssertEqual(mapping.key(forLocalRowID: 9)?.sourceRecipeID, "waffles")
        XCTAssertNil(mapping.localRowID(for: try RecipeKey(source: .user, sourceRecipeID: "nope", revision: 1)))
    }

    func testIdentityMappingRejectsWrongSchemaVersion() {
        XCTAssertThrowsError(try RecipeIdentityMapping(schemaVersion: 2, entries: [])) { error in
            guard case FLDomainError.unsupportedSchemaVersion = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
        }
    }

    func testIdentityMappingRejectsDuplicateSides() throws {
        let key = try RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1)
        XCTAssertThrowsError(
            try RecipeIdentityMapping(schemaVersion: 1, entries: [
                try .init(key: key, localRowID: 7),
                try .init(key: key, localRowID: 9),
            ])
        )
        XCTAssertThrowsError(
            try RecipeIdentityMapping(schemaVersion: 1, entries: [
                try .init(key: key, localRowID: 7),
                try .init(
                    key: RecipeKey(source: .user, sourceRecipeID: "waffles", revision: 1),
                    localRowID: 7
                ),
            ])
        )
        // Row IDs are positive.
        XCTAssertThrowsError(try RecipeIdentityMapping.Entry(key: key, localRowID: 0))
    }

    func testIdentityMappingRoundTrip() throws {
        let mapping = try makeMapping()
        let decoded = try FLJSON.canonicalDecoder().decode(RecipeIdentityMapping.self, from: FLJSON.canonicalData(mapping))
        XCTAssertEqual(decoded, mapping)
        // A foreign mapping with a future schema version is refused, not reinterpreted.
        let future = #"{"schemaVersion":2,"entries":[]}"#
        XCTAssertThrowsError(try FLJSON.canonicalDecoder().decode(RecipeIdentityMapping.self, from: Data(future.utf8)))
    }

    // MARK: GramMass

    func testGramMassValidation() {
        XCTAssertNoThrow(try GramMass(grams: 0))
        XCTAssertNoThrow(try GramMass(grams: 250.5))
        XCTAssertThrowsError(try GramMass(grams: -1))
        XCTAssertThrowsError(try GramMass(grams: .infinity))
        XCTAssertThrowsError(try GramMass(grams: .nan))
    }

    // MARK: HouseholdMeasure

    func testHouseholdMeasureValidation() throws {
        XCTAssertNoThrow(
            try HouseholdMeasure(amount: 2, unit: "cup", gramsPerUnit: 244, conversionSource: "USDA FNDDS: 1 cup whole milk = 244 g")
        )
        XCTAssertThrowsError(try HouseholdMeasure(amount: 2, unit: "  ", gramsPerUnit: 244, conversionSource: "USDA"))
        XCTAssertThrowsError(try HouseholdMeasure(amount: 2, unit: "cup", gramsPerUnit: 0, conversionSource: "USDA"))
        XCTAssertThrowsError(try HouseholdMeasure(amount: -1, unit: "cup", gramsPerUnit: 244, conversionSource: "USDA"))
        XCTAssertThrowsError(try HouseholdMeasure(amount: 2, unit: "cup", gramsPerUnit: 244, conversionSource: "  "))
    }

    func testHouseholdMeasureTotalGrams() throws {
        let measure = try HouseholdMeasure(amount: 2, unit: "cup", gramsPerUnit: 244, conversionSource: "USDA FNDDS")
        XCTAssertEqual(try measure.totalGrams, try GramMass(grams: 488))
    }

    // MARK: QuantityEvidence

    func testQuantityEvidenceGramsIfKnown() throws {
        let weighed = try GramMass(grams: 120)
        XCTAssertEqual(QuantityEvidence.weighedGrams(weighed).gramsIfKnown, weighed)
        XCTAssertEqual(QuantityEvidence.sourceGrams(weighed).gramsIfKnown, weighed)
        let measure = try HouseholdMeasure(amount: 1, unit: "cup", gramsPerUnit: 244, conversionSource: "USDA FNDDS")
        XCTAssertEqual(QuantityEvidence.householdMeasure(measure).gramsIfKnown, try GramMass(grams: 244))
        XCTAssertNil(QuantityEvidence.unknown.gramsIfKnown)
        XCTAssertTrue(QuantityEvidence.unknown.isUnknown)
        XCTAssertFalse(QuantityEvidence.sourceGrams(weighed).isUnknown)
    }

    func testQuantityEvidenceRoundTripsAllVariants() throws {
        let decoder = FLJSON.canonicalDecoder()
        let weighed = QuantityEvidence.weighedGrams(try GramMass(grams: 120))
        XCTAssertEqual(try decoder.decode(QuantityEvidence.self, from: FLJSON.canonicalData(weighed)), weighed)

        let measure = QuantityEvidence.householdMeasure(
            try HouseholdMeasure(amount: 2, unit: "tbsp", gramsPerUnit: 14.2, conversionSource: "USDA FNDDS: 1 tbsp = 14.2 g")
        )
        XCTAssertEqual(try decoder.decode(QuantityEvidence.self, from: FLJSON.canonicalData(measure)), measure)

        let unknown = QuantityEvidence.unknown
        XCTAssertEqual(try decoder.decode(QuantityEvidence.self, from: FLJSON.canonicalData(unknown)), unknown)

        // Unknown is a tagged object, and never becomes a number by default.
        let unknownJSON = String(data: try FLJSON.canonicalData(unknown), encoding: .utf8)!
        XCTAssertTrue(unknownJSON.contains(#""kind" : "unknown""#))
    }
}
