import XCTest
@testable import FLFoodSafety

final class RulebookValidationTests: XCTestCase {
    /// Repo root, located from the test file so tests run from any cwd.
    private static func repoRoot() -> String {
        #filePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropLast(5) // packages/FLFoodSafety/Tests/FLFoodSafetyTests/<file>
            .joined(separator: "/")
    }

    static let root = repoRoot()

    private func rulesJSON() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: Self.root + "/data/food-safety/rules.json"))
    }

    // MARK: The shipped rulebook is valid

    func testShippedRulebookDecodesAndValidates() throws {
        let book = try Rulebook.decode(try rulesJSON())
        XCTAssertEqual(book.schemaVersion, 1)
        XCTAssertFalse(book.rules.isEmpty)
        XCTAssertFalse(book.citations.isEmpty)
        XCTAssertTrue(book.validate().isEmpty, "shipped rules.json must validate clean")
    }

    func testEveryRuleCitesResolvableSourcesWithQuotes() throws {
        let book = try Rulebook.decode(try rulesJSON())
        for rule in book.rules {
            XCTAssertFalse(rule.citationIDs.isEmpty, "rule \(rule.id) has no citation")
            for id in rule.citationIDs {
                let citation = book.citation(id: id)
                XCTAssertNotNil(citation, "rule \(rule.id) cites unknown citation \(id)")
                XCTAssertGreaterThanOrEqual(citation?.quotes.count ?? 0, 1, "citation \(id) needs at least one verbatim quote")
                XCTAssertTrue(citation?.url.hasPrefix("https://") ?? false, "citation \(id) must be https")
                XCTAssertEqual(citation?.retrieved, "2026-10-11", "citation \(id) retrieval date")
                for quote in citation?.quotes ?? [] {
                    XCTAssertGreaterThanOrEqual(quote.count, 20, "citation \(id) quote too short to be verbatim")
                }
            }
        }
    }

    func testEveryDonenessRuleCarriesThermometerCheck() throws {
        let book = try Rulebook.decode(try rulesJSON())
        for rule in book.rules where rule.topic == .doneness {
            let check = try XCTUnwrap(rule.check, "rule \(rule.id) has no check")
            XCTAssertEqual(check.kind, .thermometer)
            XCTAssertGreaterThan(check.tempF, 90)
            let converted = (check.tempF - 32) * 5 / 9
            XCTAssertLessThanOrEqual(abs(check.tempC - converted), 1.0)
        }
    }

    func testFoodClassesUseTheSuiteCRSNames() throws {
        let book = try Rulebook.decode(try rulesJSON())
        let rsClasses: Set<FoodClass> = [.meatPoultry, .meatGround, .meatWholeCutPork,
                                         .meatWholeCutRed, .fleshFish, .fleshShellfish,
                                         .egg, .leftovers]
        let used = Set(book.rules.compactMap(\.foodClass))
        XCTAssertTrue(used.isSubset(of: rsClasses))
        // Every class minimum mirrors rs.py's FSIS_TEMP_F.
        XCTAssertEqual(FoodClass.meatPoultry.minimumTempF, 165)
        XCTAssertEqual(FoodClass.meatGround.minimumTempF, 160)
        XCTAssertEqual(FoodClass.meatWholeCutPork.minimumTempF, 145)
        XCTAssertEqual(FoodClass.meatWholeCutRed.minimumTempF, 145)
        XCTAssertEqual(FoodClass.fleshFish.minimumTempF, 145)
        XCTAssertEqual(FoodClass.fleshShellfish.minimumTempF, 145)
        XCTAssertEqual(FoodClass.egg.minimumTempF, 160)
        XCTAssertEqual(FoodClass.leftovers.minimumTempF, 165)
    }

    // MARK: Canon P1 corrections are pinned to the fetched FSIS values

    private func rule(_ id: String, in book: Rulebook) throws -> Rule {
        try XCTUnwrap(book.rules.first { $0.id == id }, "missing rule \(id)")
    }

    func testGroundPoultryPinnedAt165() throws {
        let book = try Rulebook.decode(try rulesJSON())
        let rule = try self.rule("ground-poultry-165", in: book)
        let check = try XCTUnwrap(rule.check)
        XCTAssertEqual(check.kind, .thermometer)
        XCTAssertEqual(check.tempF, 165)
        XCTAssertEqual(check.tempC, 74)
        XCTAssertEqual(rule.foodClass, .meatPoultry)
        XCTAssertTrue(rule.summary.contains("never meat_ground"),
                      "ground poultry must be excluded from the 160 °F ground-mammal class")
    }

    func testWholeCutRulesCarryThreeMinuteRest() throws {
        let book = try Rulebook.decode(try rulesJSON())
        for (id, cls) in [("whole-cut-pork-145-rest-3", FoodClass.meatWholeCutPork),
                          ("whole-cut-red-145-rest-3", FoodClass.meatWholeCutRed)] {
            let rule = try self.rule(id, in: book)
            let check = try XCTUnwrap(rule.check)
            XCTAssertEqual(check.kind, .thermometer)
            XCTAssertEqual(check.tempF, 145, "\(id) must be pinned at 145 °F")
            XCTAssertEqual(check.tempC, 63)
            XCTAssertEqual(check.restMinutes, 3, "\(id) must carry the FSIS 3-minute rest")
            XCTAssertEqual(rule.foodClass, cls)
            XCTAssertTrue(rule.summary.contains("rest"))
        }
    }

    func testReheatingRuleStatesTheProductClassOverride() throws {
        let book = try Rulebook.decode(try rulesJSON())
        let rule = try self.rule("leftovers-reheat-165", in: book)
        let check = try XCTUnwrap(rule.check)
        XCTAssertEqual(rule.topic, .reheating)
        XCTAssertEqual(check.kind, .thermometer)
        XCTAssertEqual(check.tempF, 165)
        XCTAssertEqual(check.tempC, 74)
        XCTAssertEqual(rule.foodClass, .leftovers)
        XCTAssertTrue(rule.summary.contains("overrides the product class"),
                      "the rulebook must state that reheating overrides the product class")
        XCTAssertTrue(rule.summary.contains("165 °F, not the 145 °F whole-cut minimum"),
                      "the override example must name the reheated pork-roast case")
    }

    func testHamConditionalPinsTheThreeFSISCases() throws {
        let book = try Rulebook.decode(try rulesJSON())
        let rule = try self.rule("ham-reheat-140-165", in: book)
        let check = try XCTUnwrap(rule.check)
        XCTAssertEqual(check.kind, .thermometer)
        XCTAssertEqual(check.tempF, 165)
        XCTAssertEqual(check.alternativeTempF, 140)
        XCTAssertEqual(rule.foodClass, .leftovers)
        XCTAssertTrue(rule.summary.contains("USDA-inspected plants"),
                      "140 °F is reserved for hams packaged in USDA-inspected plants")
        XCTAssertTrue(rule.summary.contains("145 °F (63 °C)"),
                      "fresh or smoked uncooked ham keeps 145 °F plus rest")
        XCTAssertTrue(rule.summary.contains("165 °F (73.9 °C)"),
                      "every other ham case goes to 165 °F")
    }

    func testCasseroleAndStuffingPinnedAt165() throws {
        let book = try Rulebook.decode(try rulesJSON())
        XCTAssertEqual(try self.rule("casseroles-165", in: book).check?.tempF, 165)
        XCTAssertEqual(try self.rule("stuffed-poultry-stuffing-165", in: book).check?.tempF, 165)
        XCTAssertEqual(try self.rule("casseroles-165", in: book).foodClass, .leftovers)
        XCTAssertEqual(try self.rule("stuffed-poultry-stuffing-165", in: book).foodClass, .meatPoultry)
        XCTAssertTrue(try self.rule("casseroles-165", in: book).summary.contains("meat and meatless"))
        XCTAssertTrue(try self.rule("stuffed-poultry-stuffing-165", in: book).summary.contains("stuffing"))
    }

    /// The #97 error class: no doneness check may undercut its FSIS class minimum.
    func testEveryCheckedRuleMeetsItsClassMinimum() throws {
        let book = try Rulebook.decode(try rulesJSON())
        for rule in book.rules {
            guard let check = rule.check, let foodClass = rule.foodClass else { continue }
            XCTAssertGreaterThanOrEqual(check.tempF, foodClass.minimumTempF,
                                        "rule \(rule.id) undercuts the FSIS minimum for \(foodClass.rawValue)")
        }
    }

    func testFoodCodeTwoStageCoolingRulePresent() throws {
        let book = try Rulebook.decode(try rulesJSON())
        let rule = try self.rule("cooling-two-stage-food-code", in: book)
        XCTAssertEqual(rule.topic, .coolingWindow)
        XCTAssertTrue(rule.citationIDs.contains("fda-food-code-2022"))
        let citation = try XCTUnwrap(book.citation(id: "fda-food-code-2022"))
        XCTAssertEqual(citation.url, "https://www.fda.gov/media/164194/download")
        XCTAssertTrue(citation.quotes.contains { $0.contains("Within 2 hours from") })
        XCTAssertTrue(citation.quotes.contains { $0.contains("Within a total of 6 hours from") })
    }

    // MARK: Fail loudly on schema violations (mutated fixtures)

    private func mutated(_ transform: (inout [String: Any]) -> Void) throws -> Data {
        var dict = try JSONSerialization.jsonObject(with: try rulesJSON()) as! [String: Any]
        transform(&dict)
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private func assertDecodeThrows(_ data: Data, issueContains needle: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try Rulebook.decode(data)
            XCTFail("expected decode to fail (\(needle))", file: file, line: line)
        } catch let error as RulebookError {
            XCTAssertTrue(error.issues.contains { $0.contains(needle) },
                          "expected an issue containing '\(needle)', got: \(error.issues)",
                          file: file, line: line)
        } catch {
            // DecodingError (structure/type violations) is also a loud failure.
        }
    }

    func testRuleWithoutCitationFailsLoudly() throws {
        let data = try mutated { dict in
            var rules = dict["rules"] as! [[String: Any]]
            rules[0]["citation_ids"] = [String]()
            dict["rules"] = rules
        }
        assertDecodeThrows(data, issueContains: "no citation")
    }

    func testRuleCitingUnknownSourceFailsLoudly() throws {
        let data = try mutated { dict in
            var rules = dict["rules"] as! [[String: Any]]
            rules[0]["citation_ids"] = ["does-not-exist"]
            dict["rules"] = rules
        }
        assertDecodeThrows(data, issueContains: "does not resolve")
    }

    func testCitationWithShortQuoteFailsLoudly() throws {
        let data = try mutated { dict in
            var citations = dict["citations"] as! [[String: Any]]
            citations[0]["quote"] = "too short"
            dict["citations"] = citations
        }
        assertDecodeThrows(data, issueContains: "too short")
    }

    func testCitationWithoutRetrievalDateFailsLoudly() throws {
        let data = try mutated { dict in
            var citations = dict["citations"] as! [[String: Any]]
            citations[0]["retrieved"] = "sometime"
            dict["citations"] = citations
        }
        assertDecodeThrows(data, issueContains: "not an ISO date")
    }

    func testUnknownRuleKeyFailsDecoding() throws {
        let data = try mutated { dict in
            var rules = dict["rules"] as! [[String: Any]]
            rules[0]["surprise_key"] = true
            dict["rules"] = rules
        }
        assertDecodeThrows(data, issueContains: "unknown key")
    }

    func testUnknownFoodClassFailsDecoding() throws {
        let data = try mutated { dict in
            var rules = dict["rules"] as! [[String: Any]]
            rules[0]["food_class"] = "mystery_meat"
            dict["rules"] = rules
        }
        assertDecodeThrows(data, issueContains: "")
    }

    /// Index of the first doneness rule that carries a `check` block.
    private func firstRuleWithCheck() throws -> Int {
        let dict = try JSONSerialization.jsonObject(with: try rulesJSON()) as! [String: Any]
        let rules = dict["rules"] as! [[String: Any]]
        let index = try XCTUnwrap(rules.firstIndex { $0["check"] != nil })
        return index
    }

    func testInconsistentTemperatureFailsValidation() throws {
        let index = try firstRuleWithCheck()
        let data = try mutated { dict in
            var rules = dict["rules"] as! [[String: Any]]
            var check = rules[index]["check"] as! [String: Any]
            check["temp_c"] = 99
            rules[index]["check"] = check
            dict["rules"] = rules
        }
        assertDecodeThrows(data, issueContains: "does not match temp_f")
    }

    func testDonenessRuleWithoutCheckFailsValidation() throws {
        let index = try firstRuleWithCheck()
        let data = try mutated { dict in
            var rules = dict["rules"] as! [[String: Any]]
            rules[index].removeValue(forKey: "check")
            dict["rules"] = rules
        }
        assertDecodeThrows(data, issueContains: "no thermometer check")
    }
}
