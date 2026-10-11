import XCTest
@testable import FLFoodSafety

final class StepLinterTests: XCTestCase {
    private var book: Rulebook!
    private var linter: StepLinter!

    override func setUpWithError() throws {
        book = try Rulebook.decode(
            try Data(contentsOf: URL(fileURLWithPath: RulebookValidationTests.root + "/data/food-safety/rules.json"))
        )
        linter = StepLinter(rulebook: book)
    }

    private func flags(_ step: String, recipe: String = "") -> [LintFlag] {
        linter.lint(step: step, recipe: recipe)
    }

    private func kinds(_ step: String, recipe: String = "") -> [LintFlag.Kind] {
        flags(step, recipe: recipe).map(\.kind)
    }

    // MARK: 1. Doneness by appearance

    func testAppearanceDonenessIsFlaggedForPoultry() {
        // The step has both problems: an appearance cue AND a bare duration —
        // each finding carries its own rule, source and rewrite.
        XCTAssertEqual(kinds("Bake until no longer pink, about 25 minutes.").sorted { $0.rawValue < $1.rawValue },
                       [.appearanceDoneness, .timeOnlyCooking])
    }

    func testJuicesRunClearIsFlagged() {
        XCTAssertEqual(kinds("Roast the chicken until the juices run clear."), [.appearanceDoneness])
    }

    func testGoldenBrownIsFlaggedForProteinStep() {
        XCTAssertEqual(kinds("Fry the chicken until golden and crisp."), [.appearanceDoneness])
    }

    func testCookedThroughIsFlagged() {
        XCTAssertTrue(kinds("Cook the pork until cooked through.").contains(.appearanceDoneness))
    }

    func testNoPinkIsFlagged() {
        XCTAssertTrue(kinds("Grill until no pink remains.").contains(.appearanceDoneness))
    }

    func testNotPinkIsFlagged() {
        XCTAssertTrue(kinds("Bake the chicken until it is not pink.").contains(.appearanceDoneness))
    }

    func testAppearanceFlagCarriesRewriteWithClassTemperature() {
        let found = flags("Bake the chicken until no longer pink.")
        let appearance = found.first { $0.kind == .appearanceDoneness }
        XCTAssertEqual(appearance?.suggestedTempF, 165)
        XCTAssertTrue(appearance?.suggestedRewrite.contains("165") ?? false)
        XCTAssertTrue(appearance?.suggestedRewrite.contains("thermometer") ?? false)
        XCTAssertTrue(appearance?.suggestedRewrite.contains("https://") ?? false)
    }

    // MARK: 2. Time-only cooking for protein classes

    func testTimeOnlyPoultryIsFlagged() {
        XCTAssertEqual(kinds("Roast the chicken for 45 minutes."), [.timeOnlyCooking])
    }

    func testTimeOnlyGroundMeatIsFlagged() {
        XCTAssertTrue(kinds("Brown the beef mince for 5 minutes.").contains(.timeOnlyCooking))
    }

    func testTimeOnlyFishIsFlagged() {
        XCTAssertTrue(kinds("Bake the salmon fillets for 12 minutes.").contains(.timeOnlyCooking))
    }

    func testTimeOnlyEggsIsFlagged() {
        XCTAssertTrue(kinds("Bake the frittata for 20 minutes.").contains(.timeOnlyCooking))
    }

    func testTimeOnlyFlagPointsAtClassMinimum() {
        let found = flags("Roast the turkey for 3 hours.")
        let timeOnly = found.first { $0.kind == .timeOnlyCooking }
        XCTAssertEqual(timeOnly?.suggestedTempF, 165)
    }

    func testThermometerStepIsTrueNegativeForTimeOnly() {
        XCTAssertTrue(flags("Roast the chicken for 45 minutes, until the thigh reads 74°C (165°F) on a thermometer.").isEmpty)
    }

    func testTimerAsCheckReminderIsTrueNegative() {
        XCTAssertTrue(flags("After 45 minutes, check the chicken with a thermometer.").isEmpty)
    }

    // MARK: 3. Raw-egg dishes without a warning

    func testRawEggDishWithoutWarningIsFlagged() {
        XCTAssertTrue(kinds("Whisk the raw eggs with sugar and fold into the mousse.").contains(.rawEggNoWarning))
    }

    func testRawEggWithWarningIsTrueNegative() {
        XCTAssertTrue(flags("Whisk the raw eggs with sugar (note: raw or lightly cooked eggs carry a salmonella risk — use pasteurised eggs for the vulnerable).").isEmpty)
    }

    func testRawEggWithoutEggWordIsNotFlagged() {
        // "eggy" metaphor in a non-egg dish must not trigger.
        XCTAssertFalse(kinds("Fold the custard powder through the cream.").contains(.rawEggNoWarning))
    }

    // MARK: 4. Ambient thawing

    func testAmbientThawingIsFlagged() {
        let found = kinds("Thaw the chicken on the counter.")
        XCTAssertTrue(found.contains(.ambientThawing), "got \(found)")
    }

    func testCounterThawingVariantIsFlagged() {
        XCTAssertTrue(kinds("Leave the prawns at room temperature to defrost.").contains(.ambientThawing))
    }

    func testColdWaterOrFridgeThawingIsTrueNegative() {
        XCTAssertTrue(flags("Thaw the turkey overnight in the fridge.").isEmpty)
        XCTAssertTrue(flags("Thaw the prawns under cold running water.").isEmpty)
        XCTAssertTrue(flags("Defrost the berries in the microwave on low.").isEmpty)
    }

    // MARK: 5. Leftovers held at ambient temperature

    func testLeftoversLeftOutIsFlagged() {
        let found = kinds("Leave the leftovers on the counter overnight.")
        XCTAssertTrue(found.contains(.leftoversHeldOut), "got \(found)")
    }

    func testLeftoverRiceAtRoomTemperatureIsFlagged() {
        XCTAssertTrue(kinds("Let the cooked rice cool to room temperature overnight.").contains(.leftoversHeldOut))
    }

    func testPromptRefrigerationIsTrueNegative() {
        XCTAssertTrue(flags("Cool the leftovers quickly and refrigerate within 2 hours.").isEmpty)
    }

    // MARK: 6. Reheating without a thermometer

    func testReheatWithoutThermometerIsFlagged() {
        let found = kinds("Reheat the leftovers in the microwave for 2 minutes.")
        XCTAssertTrue(found.contains(.reheatingWithoutThermometer), "got \(found)")
    }

    func testReheatWithThermometerIsTrueNegative() {
        XCTAssertTrue(flags("Reheat the leftovers until a thermometer reads 74°C (165°F).").isEmpty)
    }

    // MARK: Whole-recipe context linting

    func testRecipeContextFlagsProteinInLaterStep() {
        let recipe = "Chicken kyiv\nchicken breasts, butter, eggs\n"
        let results = linter.lintRecipe(
            title: "Chicken kyiv",
            ingredients: "chicken breasts, butter, eggs",
            instructions: "1. Preheat the oven.\n2. Bake for 30 minutes."
        )
        let flagged = results.filter { !$0.flags.isEmpty }
        XCTAssertEqual(flagged.count, 1)
        XCTAssertEqual(flagged.first?.flags.map(\.kind), [.timeOnlyCooking])
    }

    func testCleanRecipeProducesNoFlags() {
        let results = linter.lintRecipe(
            title: "Fridge-clearing fried rice",
            ingredients: "cooked rice, eggs (pasteurised), peas",
            instructions: """
            1. Reheat the cooked rice until it steams and a thermometer reads 74°C (165°F).
            2. Push aside, add the pasteurised eggs and scramble until a thermometer reads 74°C (165°F).
            3. Toss everything with peas and soy sauce and serve at once.
            """
        )
        XCTAssertTrue(results.allSatisfy { $0.flags.isEmpty }, "expected no flags, got \(results.filter { !$0.flags.isEmpty })")
    }

    // MARK: Determinism and corpus-readiness

    func testLinterIsDeterministic() {
        let step = "Roast the chicken for 45 minutes until golden."
        XCTAssertEqual(flags(step), flags(step))
    }

    func testRealCorpusLintsAndEveryFlagCarriesSource() throws {
        let data = try BundledRecipeAudit.loadBundledData(
            path: RulebookValidationTests.root + "/apps/ios/Resources/data.json"
        )
        XCTAssertEqual(data.recipes.count, 166)
        let results = BundledRecipeAudit.lintCorpus(rulebook: book, data: data)
        let flaggedSteps = results.flatMap(\.flaggedRows)
        XCTAssertFalse(flaggedSteps.isEmpty, "the bundled corpus is expected to contain appearance/time-only doneness")
        for row in flaggedSteps {
            for flag in row.flags {
                XCTAssertFalse(flag.ruleID.isEmpty)
                XCTAssertFalse(flag.sourceQuote.isEmpty)
                XCTAssertTrue(flag.sourceURL.hasPrefix("https://"))
                XCTAssertFalse(flag.suggestedRewrite.isEmpty)
            }
        }
    }

    func testAuditReportIsByteDeterministic() throws {
        let data = try BundledRecipeAudit.loadBundledData(
            path: RulebookValidationTests.root + "/apps/ios/Resources/data.json"
        )
        let first = BundledRecipeAudit.renderReport(rulebook: book, data: data)
        let second = BundledRecipeAudit.renderReport(rulebook: book, data: data)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("## Findings"))
        XCTAssertTrue(first.contains("| Recipes audited | 166 |"))
        XCTAssertFalse(first.contains("2026-10-11T")) // no timestamps beyond the cited retrieval date
    }
}
