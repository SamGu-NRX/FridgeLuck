import XCTest
@testable import FLFoodSafety

/// Pins the strict canon contract (`data/food-safety/README.md` clauses 1–7):
/// a doneness check counts only when the instruction text the user reads
/// names a thermometer, states an internal temperature at or above the class
/// minimum, and states the required rest time. Oven/pan/microwave temperatures
/// never count; structured metadata the text does not show is a finding; an
/// unclassifiable protein flags for review; uncertainty fails closed.
final class StrictCanonContractTests: XCTestCase {
    private var linter: StepLinter!

    override func setUpWithError() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: RulebookValidationTests.root + "/data/food-safety/rules.json"))
        linter = StepLinter(rulebookData: data)
    }

    private func findings(_ step: String, recipe: String = "", safetyField: Data? = nil) -> [LintFinding] {
        linter.findings(step: step, recipe: recipe, safetyField: safetyField)
    }

    private func kinds(_ step: String, recipe: String = "", safetyField: Data? = nil) -> [LintFinding.Kind] {
        findings(step, recipe: recipe, safetyField: safetyField).map(\.kind)
    }

    private func safetyFieldJSON(class className: String, tempF: Double, method: String = "thermometer", source: String = "USDA FSIS Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling") -> Data {
        let object: [String: Any] = ["class": className, "temp_f": tempF, "method": method, "source": source]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Clause 1+2 — thermometer named, temperature at or above the minimum

    func testGroundPoultryAt160IsBelowMinimum() {
        // The ground-poultry-160 error class: 160 °F on ground poultry names
        // the ground-meat minimum, not the poultry minimum.
        let found = findings("Form the ground turkey into patties and cook to 160 °F.")
        XCTAssertEqual(found.map(\.kind), [.belowMinimumTemperature])
        let finding = found[0]
        XCTAssertEqual(finding.ruleID, "ground-poultry-165")
        XCTAssertEqual(finding.suggestedTempF, 165)
        XCTAssertTrue(finding.suggestedRewrite.contains("165 °F"), finding.suggestedRewrite)
        XCTAssertTrue(finding.suggestedRewrite.contains("74 °C"), finding.suggestedRewrite)
        XCTAssertFalse(finding.sourceAttribution.isEmpty)
        XCTAssertFalse(finding.sourceURL.isEmpty)
        XCTAssertFalse(finding.sourceQuote.isEmpty)
    }

    func testPoultryCelsiusBelowMinimumIsFound() {
        let found = findings("Cook the chicken breast to 70 °C with a thermometer.")
        XCTAssertEqual(found.map(\.kind), [.belowMinimumTemperature])
        XCTAssertTrue(found[0].suggestedRewrite.contains("74 °C"))
        XCTAssertTrue(found[0].suggestedRewrite.contains("165 °F"))
    }

    func testPoultryCelsiusAtMinimumPasses() {
        XCTAssertEqual(kinds("Insert an instant-read thermometer into the thickest part of the chicken breast and cook to 74 °C."), [])
    }

    func testRangeBelowMinimumIsFound() {
        // A range whose low end sits below the class minimum instructs
        // undercooking.
        XCTAssertEqual(kinds("Cook the chicken to 160–165 °F with a thermometer."), [.belowMinimumTemperature])
    }

    func testTempAtMinimumWithoutThermometerIsFound() {
        let found = findings("Cook the burger to 160 °F.", recipe: "Beef burgers with onions")
        XCTAssertEqual(found.map(\.kind), [.missingThermometer])
        XCTAssertEqual(found[0].ruleID, "ground-meat-160")
        XCTAssertTrue(found[0].suggestedRewrite.contains("thermometer"), found[0].suggestedRewrite)
    }

    func testThermometerSynonymsAllCount() {
        let synonyms = [
            "a food thermometer", "a meat thermometer", "an instant-read thermometer",
            "a digital thermometer", "a probe",
        ]
        for synonym in synonyms {
            let step = "Cook the pork chop to 145 °F with \(synonym), then rest at least 3 minutes."
            XCTAssertEqual(kinds(step), [], "thermometer synonym '\(synonym)' must count as a check")
        }
    }

    func testThermometerNamedButNoTemperatureIsFound() {
        XCTAssertEqual(
            kinds("Insert a thermometer into the chicken thigh and cook until done."),
            [.missingInternalTemperature])
    }

    // MARK: Clause 2 — rest time where the class requires one

    func testWholeCutPorkWithoutRestIsFound() {
        let found = findings("Cook the pork chop to 145 °F with a food thermometer.")
        XCTAssertEqual(found.map(\.kind), [.missingRestTime])
        XCTAssertEqual(found[0].ruleID, "whole-cut-pork-145-rest-3")
        XCTAssertTrue(found[0].suggestedRewrite.contains("3 minutes"), found[0].suggestedRewrite)
        XCTAssertTrue(found[0].detail.contains("3-minute rest"))
    }

    func testWholeCutPorkShortRestIsFound() {
        XCTAssertEqual(
            kinds("Cook the pork chop to 145 °F with a food thermometer and rest 2 minutes."),
            [.missingRestTime])
    }

    func testWholeCutPorkRestStatedPasses() {
        XCTAssertEqual(
            kinds("Cook the pork chop to 145 °F with a food thermometer, then rest at least 3 minutes."),
            [])
    }

    func testWordNumberRestPasses() {
        XCTAssertEqual(
            kinds("Cook the pork chop to 145 °F with a food thermometer and rest three minutes."),
            [])
    }

    func testWholeCutRedRestStatedPasses() {
        XCTAssertEqual(
            kinds("Cook the steak to 145 °F with a food thermometer and rest for 3 minutes.", recipe: "Ribeye steak"),
            [])
    }

    // MARK: Clause 3 — oven/pan/microwave temperatures never count

    func testOvenTempNeverCountsAsDoneness() {
        let found = findings("Bake the chicken at 400 °F until done.", recipe: "Roast chicken")
        XCTAssertEqual(found.map(\.kind), [.ovenTemperatureAsDoneness])
        XCTAssertTrue(found[0].detail.contains("oven"), found[0].detail)
        XCTAssertEqual(found[0].phrase, "400 °f")
        XCTAssertTrue(found[0].suggestedRewrite.contains("165 °F"))
    }

    func testOilTempNotADonenessCheck() {
        XCTAssertEqual(
            kinds("Heat the oil to 350 °F and fry the chicken until done.", recipe: "Fried chicken"),
            [.ovenTemperatureAsDoneness])
    }

    func testBareOvenTempStillNeedsACheck() {
        // A device temperature with no doneness claim still leaves the step
        // without any check — fail closed, never pass.
        XCTAssertEqual(
            kinds("Bake the chicken at 400 °F.", recipe: "Roast chicken"),
            [.missingInternalTemperature])
    }

    func testPanSearBeforeInternalTempDoesNotConfuseDeviceClassification() {
        // A strong device cue earlier in the sentence must not turn the later
        // stated internal temperature into a pan temperature.
        XCTAssertEqual(
            kinds("Sear the pork chops in a pan, then cook to 145 °F with a food thermometer and rest for 3 minutes.", recipe: "Pork chops"),
            [])
    }

    // MARK: Clause 4 — metadata the text does not show

    func testMetadataNotShownInTextIsFound() {
        let field = safetyFieldJSON(class: "meat_ground", tempF: 160)
        let found = findings("Form the burger and grill it.", recipe: "Burger night", safetyField: field)
        XCTAssertTrue(found.map(\.kind).contains(.metadataNotInText), found.map(\.kind).debugDescription)
        let finding = found.first { $0.kind == .metadataNotInText }!
        XCTAssertEqual(finding.ruleID, "ground-meat-160")
        XCTAssertTrue(finding.detail.contains("metadata the text does not show"), finding.detail)
        XCTAssertTrue(finding.suggestedRewrite.contains("160 °F"))
    }

    func testMetadataShownInTextPasses() {
        let field = safetyFieldJSON(class: "meat_poultry", tempF: 165)
        XCTAssertEqual(
            kinds("Insert an instant-read thermometer into the thickest part and cook to 165 °F (74 °C).", recipe: "Roast chicken", safetyField: field),
            [])
    }

    func testMetadataUnderstatedMinimumFailsClosed() {
        let field = safetyFieldJSON(class: "meat_ground", tempF: 150)
        let found = findings("Insert a thermometer and cook the burger to 160 °F.", safetyField: field)
        let finding = found.first { $0.kind == .belowMinimumTemperature }
        XCTAssertNotNil(finding, found.map(\.kind).debugDescription)
        XCTAssertTrue(finding?.detail.contains("below the rulebook minimum") ?? false, finding?.detail ?? "")
    }

    func testMetadataUnparseableFailsClosed() {
        let found = findings("Cook the burger.", safetyField: Data("{\"temp_f\": \"high\"}".utf8))
        XCTAssertEqual(found.map(\.kind), [.failClosed])
        XCTAssertTrue(found[0].detail.contains("could not be parsed"), found[0].detail)
    }

    func testMetadataUnknownClassFailsClosed() {
        let field = safetyFieldJSON(class: "dragon_meat", tempF: 165)
        let found = findings("Cook the burger.", safetyField: field)
        XCTAssertEqual(found.map(\.kind), [.failClosed])
        XCTAssertTrue(found[0].detail.contains("dragon_meat"), found[0].detail)
    }

    func testMetadataNonThermometerMethodFailsClosed() {
        let field = safetyFieldJSON(class: "meat_ground", tempF: 160, method: "visual")
        let found = findings("Cook the burger.", safetyField: field)
        XCTAssertEqual(found.map(\.kind), [.failClosed])
        XCTAssertTrue(found[0].detail.contains("visual"), found[0].detail)
    }

    // MARK: Clause 5 — unclassifiable protein flags for review

    func testUnclassifiableProteinFlagsForReview() {
        let found = findings("Braise the rabbit until tender.")
        XCTAssertEqual(found.map(\.kind), [.flagForReview])
        XCTAssertTrue(found[0].detail.contains("reviewer"), found[0].detail)
        XCTAssertTrue(found[0].detail.contains("rabbit"), found[0].detail)
    }

    // MARK: Reheating overrides the product class

    func testReheatingOverridesProductClass() {
        // Meatloaf's raw class minimum is 160 °F, but a reheating step binds
        // to the reheating rule's 165 °F — 160 does not pass.
        let found = findings("Reheat the leftover meatloaf to 160 °F with a food thermometer.")
        XCTAssertEqual(found.map(\.kind), [.belowMinimumTemperature])
        XCTAssertEqual(found[0].ruleID, "leftovers-reheat-165")
        XCTAssertEqual(found[0].suggestedTempF, 165)
    }

    func testReheatingTo165WithThermometerPasses() {
        XCTAssertEqual(kinds("Reheat the leftovers to 165 °F with a food thermometer."), [])
    }

    func testReheatingWithoutThermometerIsFlagged() {
        XCTAssertEqual(kinds("Reheat the leftovers in the oven until hot."), [.reheatingWithoutThermometer])
    }

    // MARK: Clause 7 — fail closed on unusable rulebook

    func testMissingRulebookFailsClosed() {
        let linter = StepLinter(rulebookData: nil)
        let found = linter.findings(step: "Cook the chicken to 165 °F with a thermometer.")
        XCTAssertEqual(found.map(\.kind), [.failClosed])
        XCTAssertTrue(found[0].detail.contains("no rules data"), found[0].detail)
    }

    func testUnparseableRulebookFailsClosed() {
        let linter = StepLinter(rulebookData: Data("{".utf8))
        let found = linter.findings(step: "Cook the chicken to 165 °F with a thermometer.")
        XCTAssertEqual(found.map(\.kind), [.failClosed])
        XCTAssertTrue(found[0].detail.contains("could not be decoded"), found[0].detail)
    }

    // MARK: True negatives — valid checks pass clean

    func testTrueNegativeSuite() {
        let cases: [(step: String, recipe: String)] = [
            ("Insert an instant-read thermometer into the thickest part and cook to 165 °F (74 °C).", "Roast chicken"),
            ("Cook to 145 °F with a food thermometer, then rest at least 3 minutes.", "Pork chops"),
            ("Cook to 160 °F, checked with a thermometer.", "Beef burger"),
            ("Reheat to 165 °F with a food thermometer.", "Leftover chilli"),
            ("Browning the onions for the stew.", "Beef stew"),
            ("Bake the bread at 400 °F.", "Sandwich bread"),
            ("Refrigerate within 2 hours.", "Chicken soup"),
            ("Fry the onions until golden.", "Onion relish"),
        ]
        for (step, recipe) in cases {
            XCTAssertEqual(kinds(step, recipe: recipe), [], "true negative must pass clean: \(step)")
        }
    }

    // MARK: Determinism and the canon finding format

    func testStrictFindingsAreDeterministic() {
        let first = findings("Form the ground turkey into patties and cook to 160 °F.")
        let second = findings("Form the ground turkey into patties and cook to 160 °F.")
        XCTAssertEqual(first, second)
    }

    func testFindingLineCarriesRuleIdAndCitation() {
        let found = findings("Form the ground turkey into patties and cook to 160 °F.")
        XCTAssertEqual(found.count, 1)
        let line = found[0].findingLine(file: "recipes/x.json", recordID: "r-42", field: "instructions")
        XCTAssertTrue(line.contains("ground-poultry-165"), line)
        XCTAssertTrue(line.contains(found[0].sourceURL), line)
        XCTAssertTrue(line.contains("retrieved"), line)
        XCTAssertTrue(line.contains(found[0].suggestedRewrite), line)
    }
}
