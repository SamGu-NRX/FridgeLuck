import XCTest
@testable import FLDomain

final class NutritionAndRestrictionTests: XCTestCase {
    // MARK: NutritionValues

    func testNutritionValuesRejectInvalidNumbers() {
        XCTAssertThrowsError(try NutritionValues(caloriesKcal: -1))
        XCTAssertThrowsError(try NutritionValues(proteinGrams: .nan))
        XCTAssertThrowsError(try NutritionValues(sodiumGrams: .infinity))
        XCTAssertNoThrow(try NutritionValues(caloriesKcal: 0))
    }

    func testNutritionValuesGapsAreHonest() throws {
        let values = try NutritionValues(caloriesKcal: 350, proteinGrams: 12)
        XCTAssertFalse(values.isComplete)
        XCTAssertTrue(values.missingLines.contains("fatGrams"))
        XCTAssertTrue(values.hasAnyLine)
        XCTAssertNil(values.value(forLine: "fatGrams"))
        XCTAssertEqual(values.value(forLine: "proteinGrams"), 12)
        XCTAssertNil(values.value(forLine: "notALine"))
    }

    func testCompleteValues() throws {
        let complete = try NutritionValues(
            caloriesKcal: 350, proteinGrams: 12, carbohydrateGrams: 40, fatGrams: 9,
            saturatedFatGrams: 2, fiberGrams: 3, sugarGrams: 6, sodiumGrams: 0.5
        )
        XCTAssertTrue(complete.isComplete)
        XCTAssertTrue(complete.missingLines.isEmpty)
    }

    // MARK: NutritionReport coherence

    private let completeValues = try! NutritionValues(
        caloriesKcal: 350, proteinGrams: 12, carbohydrateGrams: 40, fatGrams: 9,
        saturatedFatGrams: 2, fiberGrams: 3, sugarGrams: 6, sodiumGrams: 0.5
    )

    func testReportCompleteRequiresAllLines() throws {
        XCTAssertNoThrow(try NutritionReport(values: completeValues, coverage: .complete))
        XCTAssertThrowsError(try NutritionReport(
            values: NutritionValues(caloriesKcal: 350),
            coverage: .complete
        ))
    }

    func testReportPartialNamesMissingLines() throws {
        let values = try NutritionValues(caloriesKcal: 350, proteinGrams: 12)
        XCTAssertNoThrow(try NutritionReport(values: values, coverage: .partial(missingLines: values.missingLines)))
        // An empty missing list is incoherent for partial.
        XCTAssertThrowsError(try NutritionReport(values: values, coverage: .partial(missingLines: [])))
        // A line with a value cannot be listed as missing.
        XCTAssertThrowsError(try NutritionReport(values: values, coverage: .partial(missingLines: ["proteinGrams"])))
        // All-unknown is .unknown, never partial.
        XCTAssertThrowsError(try NutritionReport(values: NutritionValues(), coverage: .partial(missingLines: ["caloriesKcal"])))
    }

    func testReportUnknownMeansUnknown() throws {
        XCTAssertNoThrow(try NutritionReport(values: NutritionValues(), coverage: .unknown))
        XCTAssertThrowsError(try NutritionReport(values: completeValues, coverage: .unknown))
    }

    func testReportRoundTripAndCanonicalShape() throws {
        let values = try NutritionValues(caloriesKcal: 350, proteinGrams: 12)
        let report = try NutritionReport(values: values, coverage: .partial(missingLines: values.missingLines))
        let decoded = try FLJSON.canonicalDecoder().decode(NutritionReport.self, from: FLJSON.canonicalData(report))
        XCTAssertEqual(decoded, report)

        // Coverage encodes as a tagged object with an explicit kind.
        let text = String(data: try FLJSON.canonicalData(report.coverage), encoding: .utf8)!
        XCTAssertTrue(text.contains(#""kind" : "partial""#))
        XCTAssertTrue(text.contains(#""missingLines""#))
    }

    // MARK: Sodium display rule

    func testSodiumStaysGramsInDomain() throws {
        // 0.5 g stored; milligrams appear only at the display boundary.
        let values = try NutritionValues(sodiumGrams: 0.5)
        XCTAssertEqual(values.sodiumGrams! * 1000, 500)
    }

    // MARK: Restriction

    func testRestrictionPermitsHardFilter() throws {
        let allergy = try Restriction(allergens: [.peanuts])
        XCTAssertTrue(allergy.permits(canonicalName: "rice"))
        XCTAssertFalse(allergy.permits(canonicalName: "pad thai", allergens: [.peanuts]))
        // A custom exclusion matches exactly by canonical name.
        let custom = try Restriction(customExclusions: ["monosodium glutamate"])
        XCTAssertFalse(custom.permits(canonicalName: "monosodium glutamate"))
        XCTAssertTrue(custom.permits(canonicalName: "msg"))
        // Diet tags.
        let diet = try Restriction(dietExclusions: [.vegan])
        XCTAssertFalse(diet.permits(canonicalName: "omelette", dietTags: [.vegan]))
        XCTAssertTrue(diet.permits(canonicalName: "omelette"))
    }

    func testRestrictionUnionAcrossEaters() throws {
        let first = try Restriction(allergens: [.milk], customExclusions: ["msg"])
        let second = try Restriction(allergens: [.peanuts], dietExclusions: [.halal])
        let union = first.union(second)
        XCTAssertTrue(union.allergens.contains(.milk))
        XCTAssertTrue(union.allergens.contains(.peanuts))
        XCTAssertTrue(union.dietExclusions.contains(.halal))
        XCTAssertTrue(union.customExclusions.contains("msg"))
    }

    func testRestrictionValidationAndRoundTrip() throws {
        XCTAssertThrowsError(try Restriction(customExclusions: ["  "]))
        XCTAssertNoThrow(try Restriction())

        let restriction = try Restriction(
            allergens: [.milk, .eggs],
            dietExclusions: [.vegan],
            customExclusions: ["monosodium glutamate"]
        )
        let decoded = try FLJSON.canonicalDecoder().decode(Restriction.self, from: FLJSON.canonicalData(restriction))
        XCTAssertEqual(decoded, restriction)
    }
}
