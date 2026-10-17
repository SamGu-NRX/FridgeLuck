import XCTest
@testable import FLFoodSafety

final class DonenessLookupTests: XCTestCase {
    private var book: Rulebook!

    override func setUpWithError() throws {
        book = try Rulebook.decode(
            try Data(contentsOf: URL(fileURLWithPath: RulebookValidationTests.root + "/data/food-safety/rules.json"))
        )
    }

    private func lookup() -> DonenessLookup { DonenessLookup(rulebook: book) }

    private func assertCheck(_ text: String, expectedClass: FoodClass,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let match = try XCTUnwrap(lookup().check(text: text), "'\(text)' matched nothing", file: file, line: line)
        XCTAssertEqual(match.rule.foodClass, expectedClass, "'\(text)'", file: file, line: line)
        let check = try XCTUnwrap(match.rule.check, file: file, line: line)
        XCTAssertEqual(check.tempF, expectedClass.minimumTempF, file: file, line: line)
        XCTAssertFalse(match.matchedKeyword.isEmpty, file: file, line: line)
    }

    // MARK: Each lookup class

    func testPoultry() throws {
        try assertCheck("Roast the chicken", expectedClass: .meatPoultry)
        try assertCheck("season the turkey breast", expectedClass: .meatPoultry)
        try assertCheck("ground turkey browns fast", expectedClass: .meatPoultry)
        try assertCheck("duck legs confit", expectedClass: .meatPoultry)
    }

    func testGroundMeat() throws {
        try assertCheck("brown the beef mince", expectedClass: .meatGround)
        try assertCheck("add the ground pork", expectedClass: .meatGround)
        try assertCheck("form the burger patties", expectedClass: .meatGround)
    }

    func testWholeCutPork() throws {
        try assertCheck("sear the pork chops", expectedClass: .meatWholeCutPork)
        try assertCheck("roast the pork loin", expectedClass: .meatWholeCutPork)
        try assertCheck("glaze the gammon joint", expectedClass: .meatWholeCutPork)
    }

    func testWholeCutRedMeat() throws {
        try assertCheck("sear the ribeye steak", expectedClass: .meatWholeCutRed)
        try assertCheck("lamb shoulder, low and slow", expectedClass: .meatWholeCutRed)
        try assertCheck("season the beef roast", expectedClass: .meatWholeCutRed)
    }

    func testFish() throws {
        try assertCheck("poach the salmon fillet", expectedClass: .fleshFish)
        try assertCheck("cod loin in butter", expectedClass: .fleshFish)
        try assertCheck("grilled tuna steak", expectedClass: .fleshFish)
    }

    func testShellfish() throws {
        try assertCheck("sauté the shrimp", expectedClass: .fleshShellfish)
        try assertCheck("steam the mussels", expectedClass: .fleshShellfish)
        try assertCheck("king prawns with garlic", expectedClass: .fleshShellfish)
    }

    func testEggs() throws {
        try assertCheck("whisk the eggs", expectedClass: .egg)
        try assertCheck("fold in the beaten egg yolks", expectedClass: .egg)
        try assertCheck("a runny raw egg on top", expectedClass: .egg)
        try assertCheck("that egg mixture", expectedClass: .egg)
    }

    func testLeftovers() throws {
        try assertCheck("reheat the leftovers", expectedClass: .leftovers)
        try assertCheck("reheat until steaming", expectedClass: .leftovers)
        try assertCheck("rewarm last night's curry", expectedClass: .leftovers)
    }

    // MARK: True negatives — safe or irrelevant text matches nothing

    func testTrueNegatives() {
        let look = lookup()
        let negatives = [
            "Preheat the oven to 200°C.",
            "Chop the onions and garlic.",
            "Simmer the stock and add the rice.",
            "Season with salt and pepper.",
            "Toss the salad with olive oil.",
            "Toast the almonds in a dry pan.",
            "Melt the chocolate over a water bath.",
            "Knead the dough for 5 minutes.",
            "Whisk the cream until soft peaks.",
            "Boil the kettle.",
        ]
        for text in negatives {
            XCTAssertNil(look.check(text: text), "true negative violated by '\(text)'")
        }
    }

    func testProteinWordAloneDoesNotMatchWithoutFoodContext() {
        // "meat" / "fish" generically without a qualifying food word must not
        // resolve to a class (would over-trigger the linter).
        XCTAssertNil(lookup().check(text: "the meat counter"))
        XCTAssertNil(lookup().check(text: "fish sauce"))
    }

    // MARK: Specificity and citation plumbing

    func testGroundBeatsWholeCutForSameSpecies() throws {
        // "ground pork" must resolve to the ground rule, not whole-cut pork.
        try assertCheck("ground pork", expectedClass: .meatGround)
        // Poultry mince keeps the poultry minimum (FSIS ground poultry is
        // 165 °F, not meat_ground's 160 °F).
        try assertCheck("chicken breast mince", expectedClass: .meatPoultry)
        try assertCheck("chicken breast", expectedClass: .meatPoultry)
    }

    func testEveryClassHasALookupRuleWithCheck() {
        let look = lookup()
        for foodClass in FoodClass.allCases {
            let rule = look.rule(for: foodClass)
            XCTAssertNotNil(rule, "no rule for \(foodClass.rawValue)")
            XCTAssertNotNil(rule?.check, "\(foodClass.rawValue) rule lacks a check")
        }
    }

    func testCheckCitationsResolve() {
        let look = lookup()
        for foodClass in FoodClass.allCases {
            guard let rule = look.rule(for: foodClass) else { continue }
            XCTAssertFalse(rule.citationIDs.isEmpty, "\(foodClass.rawValue) rule must cite")
            for id in rule.citationIDs {
                XCTAssertNotNil(book.citation(id: id))
            }
        }
    }
}
