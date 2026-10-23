import XCTest
@testable import FLDomain

final class RecipeTests: XCTestCase {
    private let key = try! RecipeKey(source: .user, sourceRecipeID: "pancakes", revision: 1)
    private let flour = try! IngredientReference(canonicalName: "all-purpose flour")
    private let milk = try! IngredientReference(canonicalName: "whole milk")

    private func makeLine(
        _ lineID: String = "line-1",
        ingredient: IngredientReference,
        quantity: QuantityEvidence,
        isOptionalGarnish: Bool = false
    ) throws -> IngredientLine {
        try IngredientLine(lineID: lineID, ingredient: ingredient, quantity: quantity, isOptionalGarnish: isOptionalGarnish)
    }

    private func makeStep(_ stepID: String = "step-1", action: String = "Whisk the batter", duration: Int? = nil) throws -> Step {
        try Step(stepID: stepID, action: action, durationSeconds: duration)
    }

    private func makeLicense(grant: RecipeLicense.Grant = .permitted) throws -> RecipeLicense {
        try RecipeLicense(
            textRedistribution: grant,
            imageRedistribution: grant,
            modificationAllowed: grant,
            attributionRequired: false,
            cachingAllowed: grant,
            offlineUseAllowed: grant,
            evidence: "author declaration recorded at import"
        )
    }

    private func makeRevision(
        ingredientLines: [IngredientLine],
        steps: [Step],
        license: RecipeLicense
    ) throws -> RecipeRevision {
        try RecipeRevision(
            key: key,
            title: "Saturday Pancakes",
            servingBasis: try ServingBasis(servings: 4),
            ingredientLines: ingredientLines,
            steps: steps,
            source: RecipeSourceEvidence(
                origin: .user,
                attribution: nil,
                license: license
            )
        )
    }

    // MARK: Step / temperature / safety

    func testStepValidation() throws {
        XCTAssertThrowsError(try Step(stepID: "s1", action: "   "))
        XCTAssertThrowsError(try Step(stepID: "  ", action: "Stir"))
        XCTAssertThrowsError(try Step(stepID: "s1", action: "Bake", durationSeconds: 0))
        XCTAssertThrowsError(try Step(stepID: "s1", action: "Bake", equipment: ["  "]))
        XCTAssertNoThrow(try Step(stepID: "s1", action: "Bake", durationSeconds: 600))
    }

    func testCookingTemperaturePurposes() throws {
        XCTAssertNoThrow(try CookingTemperature(celsius: 200, purpose: .ovenTarget))
        XCTAssertNoThrow(try CookingTemperature(celsius: 74, purpose: .internalDoneness))
        XCTAssertThrowsError(try CookingTemperature(celsius: 500, purpose: .ovenTarget))
        XCTAssertThrowsError(try CookingTemperature(celsius: -150, purpose: .internalDoneness))
        XCTAssertThrowsError(try CookingTemperature(celsius: .nan, purpose: .ovenTarget))
    }

    func testSafetyCheckValidation() throws {
        let check = try SafetyCheck(
            instruction: "insert the thermometer into the thickest part of the thigh",
            minimumInternalCelsius: 74,
            source: "USDA FSIS Safe Minimum Internal Temperature Chart"
        )
        XCTAssertEqual(check.minimumInternalCelsius, 74)
        XCTAssertThrowsError(try SafetyCheck(instruction: "  ", minimumInternalCelsius: nil, source: "USDA FSIS"))
        XCTAssertThrowsError(try SafetyCheck(instruction: "check", minimumInternalCelsius: nil, source: "  "))
    }

    func testServingBasisValidation() {
        XCTAssertNoThrow(try ServingBasis(servings: 1))
        XCTAssertThrowsError(try ServingBasis(servings: 0))
    }

    // MARK: License quarantine

    func testLicenseQuarantineRules() throws {
        XCTAssertFalse(try makeLicense().isQuarantined)
        // Unknown rights means quarantine, not permission.
        XCTAssertTrue(try makeLicense(grant: .unknown).isQuarantined)
        XCTAssertTrue(try makeLicense(grant: .forbidden).isQuarantined)
        XCTAssertThrowsError(try RecipeLicense(
            textRedistribution: .permitted, imageRedistribution: .permitted,
            modificationAllowed: .permitted, attributionRequired: false,
            cachingAllowed: .permitted, offlineUseAllowed: .permitted,
            evidence: "  "
        ))
    }

    // MARK: IngredientLine

    func testIngredientLineValidationAndRoundTrip() throws {
        let line = try makeLine(
            ingredient: flour,
            quantity: .sourceGrams(try GramMass(grams: 250))
        )
        XCTAssertEqual(line.lineID, "line-1")
        XCTAssertFalse(line.isOptionalGarnish)

        XCTAssertThrowsError(try IngredientLine(lineID: " ", ingredient: flour, quantity: .unknown))

        let decoded = try FLJSON.canonicalDecoder().decode(IngredientLine.self, from: FLJSON.canonicalData(line))
        XCTAssertEqual(decoded, line)
    }

    // MARK: RecipeRevision

    func testRecipeRevisionValidation() throws {
        let license = try makeLicense()

        XCTAssertThrowsError(try RecipeRevision(
            key: key, title: "   ", servingBasis: try ServingBasis(servings: 4),
            ingredientLines: [], steps: [try makeStep()],
            source: RecipeSourceEvidence(origin: .user, attribution: nil, license: license)
        ))
        XCTAssertThrowsError(try makeRevision(ingredientLines: [], steps: [], license: license))

        // Duplicate line identity is rejected; the same ingredient on two lines is fine.
        let lineA = try makeLine("line-1", ingredient: flour, quantity: .unknown)
        let lineB = try makeLine("line-1", ingredient: milk, quantity: .unknown)
        let lineC = try makeLine("line-2", ingredient: milk, quantity: .unknown)
        XCTAssertThrowsError(try makeRevision(ingredientLines: [lineA, lineB], steps: [try makeStep()], license: license))
        XCTAssertNoThrow(try makeRevision(ingredientLines: [lineA, lineC], steps: [try makeStep()], license: license))

        // Duplicate step identity is rejected.
        XCTAssertThrowsError(try makeRevision(
            ingredientLines: [lineA],
            steps: [try makeStep("step-1"), try makeStep("step-1")],
            license: license
        ))
    }

    func testRequiredIngredientLinesExcludesGarnish() throws {
        let required = try makeLine(ingredient: flour, quantity: .unknown)
        let garnish = try makeLine("line-g", ingredient: milk, quantity: .unknown, isOptionalGarnish: true)
        let revision = try makeRevision(
            ingredientLines: [required, garnish],
            steps: [try makeStep()],
            license: try makeLicense()
        )
        XCTAssertEqual(revision.requiredIngredientLines.map(\.lineID), ["line-1"])
        XCTAssertEqual(revision.ingredientLines.count, 2)
    }

    func testRecipeRevisionRoundTrip() throws {
        let revision = try makeRevision(
            ingredientLines: [try makeLine(ingredient: flour, quantity: .sourceGrams(try GramMass(grams: 250)))],
            steps: [try Step(
                stepID: "step-1",
                action: "Cook until the internal temperature reads done",
                durationSeconds: 300,
                temperature: try CookingTemperature(celsius: 74, purpose: .internalDoneness),
                equipment: ["12-inch skillet"],
                safetyCheck: try SafetyCheck(
                    instruction: "read the thermometer",
                    minimumInternalCelsius: 74,
                    source: "USDA FSIS Safe Minimum Internal Temperature Chart"
                )
            )],
            license: try makeLicense()
        )
        let decoded = try FLJSON.canonicalDecoder().decode(RecipeRevision.self, from: FLJSON.canonicalData(revision))
        XCTAssertEqual(decoded, revision)
    }

    // MARK: - Review round 1, item 7: invalid safety temperatures are rejected

    func testSafetyCheckRejectsImplausibleInternalTemperatures() {
        XCTAssertThrowsError(try SafetyCheck(instruction: "read the thigh", minimumInternalCelsius: .nan, source: "USDA FSIS"), "NaN is not a safety bound")
        XCTAssertThrowsError(try SafetyCheck(instruction: "read the thigh", minimumInternalCelsius: -200, source: "USDA FSIS"), "an internal temperature below absolute zero is not a bound")
        XCTAssertThrowsError(try SafetyCheck(instruction: "read the thigh", minimumInternalCelsius: 999, source: "USDA FSIS"), "no food doneness bound approaches the boiling point of fat at 999 °C")
        XCTAssertNoThrow(try SafetyCheck(instruction: "read the thigh", minimumInternalCelsius: 74, source: "USDA FSIS"))
    }

    func testCookingTemperatureRejectsImplausibleValues() {
        XCTAssertThrowsError(try CookingTemperature(celsius: .nan, purpose: .ovenTarget), "NaN is not an oven setting")
        XCTAssertThrowsError(try CookingTemperature(celsius: 1e9, purpose: .ovenTarget), "an oven does not run at a billion degrees")
        XCTAssertNoThrow(try CookingTemperature(celsius: 180, purpose: .ovenTarget))
    }
}
