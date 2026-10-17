import XCTest
@testable import FLFoodSafety

/// Tests for the spoilage / use-it-up copy lint (`CopyLint`).
///
/// The must-flag cases below are the named error cases of the policy in
/// `data/food-safety/COPY.md` ("Spoilage and use-it-up policy"); the true
/// negatives pin what clean copy looks like. Pattern data lives in
/// `data/food-safety/copy-lint-patterns.json` and is decoded strictly — the
/// fail-closed section mutates the shipped file and asserts the linter refuses
/// to run with a narrowed policy.
final class CopyLintTests: XCTestCase {
    /// Repo root, located from the test file so tests run from any cwd.
    private static func repoRoot() -> String {
        #filePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropLast(5) // packages/FLFoodSafety/Tests/FLFoodSafetyTests/<file>
            .joined(separator: "/")
    }

    static let root = repoRoot()

    private func patternsJSON() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: Self.root + "/data/food-safety/copy-lint-patterns.json"))
    }

    private func makeLint() throws -> CopyLint {
        try CopyLint(patternsData: try patternsJSON())
    }

    private func record(file: String, id: String, field: String, text: String) -> CopyRecord {
        CopyRecord(file: file, recordID: id, field: field, text: text)
    }

    /// The shipped pattern file, re-serialized after `transform`.
    private func mutatedPatternData(_ transform: (inout [String: Any]) -> Void) throws -> Data {
        var dict = try JSONSerialization.jsonObject(with: try patternsJSON()) as! [String: Any]
        transform(&dict)
        return try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: The shipped pattern data decodes and carries cited patterns

    func testShippedPatternDataDecodesWithAllFivePatterns() throws {
        let lint = try makeLint()
        XCTAssertEqual(lint.patternIDs, [
            "salvage-spoiled",
            "leafy-greens-too-far-gone",
            "cook-decayed-or-sprouted",
            "fish-curing-rescue",
            "smell-safety-test",
        ])
    }

    func testEveryPatternCitesHTTPSWithPinnedDateAndVerbatimQuote() throws {
        let doc = try JSONSerialization.jsonObject(with: try patternsJSON()) as! [String: Any]
        let patterns = try XCTUnwrap(doc["patterns"] as? [[String: Any]])
        XCTAssertEqual(patterns.count, 5)
        for pattern in patterns {
            let id = try XCTUnwrap(pattern["id"] as? String)
            let citation = try XCTUnwrap(pattern["citation"] as? [String: Any])
            XCTAssertEqual(citation["retrieved"] as? String, "2026-10-11", "\(id) retrieval date")
            let url = try XCTUnwrap(citation["url"] as? String)
            XCTAssertTrue(url.hasPrefix("https://"), "\(id) citation must be https")
            let quote = try XCTUnwrap(citation["quote"] as? String)
            XCTAssertGreaterThanOrEqual(quote.count, 20, "\(id) quote too short to be verbatim")
        }
    }

    // MARK: Must-flag — the policy's named error cases

    func testSpinachTooFarGoneIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-1", field: "step",
            text: "Your spinach is getting a bit too far gone, but it's fine once cooked into a curry.")])
        XCTAssertTrue(findings.map(\.patternID).contains("leafy-greens-too-far-gone"), "findings: \(findings)")
        XCTAssertTrue(findings.map(\.patternID).contains("salvage-spoiled"), "the same line also salvages spoiled food: \(findings)")
    }

    func testSlimyGreensBlendedIntoSmoothieIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "tips.json", id: "t-1", field: "tip",
            text: "Wilted spinach on the edge? Even if it's slimy, blend it into a smoothie — you won't notice.")])
        XCTAssertTrue(findings.map(\.patternID).contains("leafy-greens-too-far-gone"), "findings: \(findings)")
    }

    func testSproutedPotatoBoilIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-2", field: "step",
            text: "The potatoes have sprouted — cut the sprouts off and boil them as usual.")])
        XCTAssertTrue(findings.map(\.patternID).contains("cook-decayed-or-sprouted"), "findings: \(findings)")
    }

    func testRottenCarrotRoastIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-3", field: "step",
            text: "The carrots have gone a bit rotten; roast them anyway to save them.")])
        XCTAssertTrue(findings.map(\.patternID).contains("cook-decayed-or-sprouted"), "findings: \(findings)")
    }

    func testFishCureRescueIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-4", field: "step",
            text: "Rescue the raw fish: cure it in lime for an hour and it's safe for sushi.")])
        XCTAssertTrue(findings.map(\.patternID).contains("fish-curing-rescue"), "findings: \(findings)")
    }

    func testCitrusCooksFishClaimIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-5", field: "step",
            text: "The lime juice effectively cooks the raw fish, so it's safe to eat.")])
        XCTAssertTrue(findings.map(\.patternID).contains("fish-curing-rescue"), "findings: \(findings)")
    }

    func testSmellsFineSoSafeIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "lechef.json", id: "lc-1", field: "line",
            text: "It smells fine, so it's safe to eat.")])
        XCTAssertTrue(findings.map(\.patternID).contains("smell-safety-test"), "findings: \(findings)")
    }

    func testNoSmellBadStillGoodIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "ui.json", id: "u-1", field: "text",
            text: "It doesn't smell bad, so it should still be good.")])
        XCTAssertTrue(findings.map(\.patternID).contains("smell-safety-test"), "findings: \(findings)")
    }

    func testSpoiledLeftoversReheatedIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-6", field: "step",
            text: "The leftovers went a bit slimy in the fridge — still fine once reheated.")])
        XCTAssertTrue(findings.map(\.patternID).contains("salvage-spoiled"), "findings: \(findings)")
    }

    func testMoldyAvocadoDontWasteIsFlagged() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "tips.json", id: "t-2", field: "tip",
            text: "The avocado is moldy, but don't waste it — scoop around the mold.")])
        XCTAssertTrue(findings.map(\.patternID).contains("salvage-spoiled"), "findings: \(findings)")
    }

    // MARK: True negatives — clean copy passes with zero findings

    func testTrueNegativesPassClean() throws {
        let lint = try makeLint()
        let clean = [
            "Use spinach within 3 days of purchase.",
            "Discard the greens if they are slimy or off-smelling.",
            "When in doubt, throw it out.",
            "Best within 2 days for peak quality.",
            "Sprouted grain bread is made from sprouted wheat.",
            "Marinate the salmon overnight in the refrigerator.",
            "Freezing kills parasites that may be present in fish.",
            "Use the broccoli within a week, before it turns slimy.",
            "Cut away any damaged or bruised areas before preparing.",
            "The lime juice adds brightness; cook the fish to 63 °C on a food thermometer.",
            "Smell is not a safety test: judge by time and temperature.",
            "If the potatoes have sprouted, compost them.",
        ]
        let records = clean.enumerated().map { index, text in
            record(file: "clean.json", id: "c-\(index)", field: "text", text: text)
        }
        let findings = lint.lint(records)
        XCTAssertTrue(findings.isEmpty, "clean copy must pass with zero findings, got: \(findings.map(\.canonicalLine))")
    }

    // MARK: Finding shape — canon format, verbatim snippet, cited rewrite

    func testFindingCarriesExactRewriteAndCitation() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "lechef.json", id: "lc-1", field: "line",
            text: "It smells fine, so it's safe to eat.")])
        let finding = try XCTUnwrap(findings.first { $0.patternID == "smell-safety-test" })

        // The required change names the exact replacement copy plus the policy
        // citation, built from the shipped pattern's own fields.
        let doc = try JSONSerialization.jsonObject(with: try patternsJSON()) as! [String: Any]
        let patterns = try XCTUnwrap(doc["patterns"] as? [[String: Any]])
        let smellPattern = try XCTUnwrap(patterns.first { ($0["id"] as? String) == "smell-safety-test" })
        let citation = try XCTUnwrap(smellPattern["citation"] as? [String: Any])
        let expected = "Replace with: \(smellPattern["rewrite"] as! String) (policy: smell-safety-test; source: \(citation["org"] as! String) — \(citation["title"] as! String); \(citation["url"] as! String); retrieved \(citation["retrieved"] as! String): \"\(citation["quote"] as! String)\")"
        XCTAssertEqual(finding.requiredChange, expected)
        XCTAssertTrue(finding.requiredChange.hasPrefix("Replace with: Smell is not a safety test"))
        XCTAssertTrue(finding.requiredChange.contains("one cannot tell that a pathogen is present"))
    }

    func testCanonicalLineFormat() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "lechef.json", id: "lc-1", field: "line",
            text: "It smells fine, so it's safe to eat.")])
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.canonicalLine,
                       [finding.file, finding.recordID, finding.field, finding.currentText, finding.requiredChange]
                           .joined(separator: " · "))
    }

    func testSnippetIsVerbatimAndSpansCrossSentenceMatches() throws {
        let lint = try makeLint()

        // Single sentence: the snippet is that whole sentence, verbatim.
        let single = record(file: "recipes.json", id: "r-1", field: "step",
            text: "Your spinach is getting a bit too far gone, but it's fine once cooked into a curry.")
        let singleFindings = lint.lint([single])
        let singleLeafy = try XCTUnwrap(singleFindings.first { $0.patternID == "leafy-greens-too-far-gone" })
        XCTAssertEqual(singleLeafy.currentText, single.text)
        XCTAssertTrue(single.text.contains(singleLeafy.currentText))

        // Cross-sentence: the snippet spans from the first matched sentence to
        // the last, verbatim.
        let cross = record(file: "recipes.json", id: "r-9", field: "step",
            text: "Buy spinach. If it's already slimy, blend it into a smoothie anyway.")
        let crossFindings = lint.lint([cross])
        let crossLeafy = try XCTUnwrap(crossFindings.first { $0.patternID == "leafy-greens-too-far-gone" })
        XCTAssertEqual(crossLeafy.currentText, "Buy spinach. If it's already slimy, blend it into a smoothie anyway.")
        XCTAssertTrue(cross.text.contains(crossLeafy.currentText))
    }

    func testOneFindingPerPatternPerRecord() throws {
        let lint = try makeLint()
        let findings = lint.lint([record(file: "recipes.json", id: "r-7", field: "step",
            text: "The leftovers went slimy in the fridge — still fine once reheated. Even the slimy rice is probably fine.")])
        XCTAssertEqual(findings.filter { $0.patternID == "salvage-spoiled" }.count, 1,
                       "one finding per pattern per record, even when the pattern matches twice")
    }

    func testFindingsReportFileRecordAndFieldAcrossSurfaces() throws {
        let lint = try makeLint()
        let cases: [(file: String, id: String, field: String, text: String, expected: String)] = [
            ("recipes.json", "rec-12", "step",
             "The leftovers went slimy in the fridge — still fine once reheated.", "salvage-spoiled"),
            ("tips.json", "tip-7", "tip",
             "The avocado is moldy, but don't waste it — scoop around the mold.", "salvage-spoiled"),
            ("lechef.json", "lc-31", "line",
             "It smells fine, so it's safe to eat.", "smell-safety-test"),
            ("ui.json", "ui-storage-card", "text",
             "Potatoes with sprouts? Boil them as usual — no need to bin them.", "cook-decayed-or-sprouted"),
        ]
        let records = cases.map { record(file: $0.file, id: $0.id, field: $0.field, text: $0.text) }
        let findings = lint.lint(records)
        for testCase in cases {
            let matching = findings.filter { $0.file == testCase.file && $0.recordID == testCase.id }
            XCTAssertTrue(matching.map(\.patternID).contains(testCase.expected),
                          "\(testCase.file)/\(testCase.id) should flag \(testCase.expected): \(matching)")
            for finding in matching {
                XCTAssertEqual(finding.field, testCase.field)
                XCTAssertEqual(finding.recordID, testCase.id)
            }
        }
    }

    // MARK: Fail closed on invalid pattern data (mutated shipped file)

    func testUnknownTopLevelKeyFailsClosed() throws {
        let data = try mutatedPatternData { $0["extra_key"] = "nope" }
        XCTAssertThrowsError(try CopyLint(patternsData: data)) { error in
            guard case CopyLintError.validationFailed(let reason) = error else {
                return XCTFail("expected CopyLintError.validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("unknown key"), "unexpected reason: \(reason)")
        }
    }

    func testInvalidRegexFailsClosed() throws {
        let data = try mutatedPatternData { dict in
            var patterns = dict["patterns"] as! [[String: Any]]
            var first = patterns[0]
            var all = first["all"] as! [[Any]]
            all[0] = ["("]
            first["all"] = all
            patterns[0] = first
            dict["patterns"] = patterns
        }
        XCTAssertThrowsError(try CopyLint(patternsData: data)) { error in
            guard case CopyLintError.validationFailed(let reason) = error else {
                return XCTFail("expected CopyLintError.validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("invalid regex"), "unexpected reason: \(reason)")
        }
    }

    func testEmptyPatternSetFailsClosed() throws {
        let data = try mutatedPatternData { $0["patterns"] = [[String: Any]]() }
        XCTAssertThrowsError(try CopyLint(patternsData: data)) { error in
            guard case CopyLintError.validationFailed(let reason) = error else {
                return XCTFail("expected CopyLintError.validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("patterns must not be empty"), "unexpected reason: \(reason)")
        }
    }

    func testShortQuoteFailsClosed() throws {
        let data = try mutatedPatternData { dict in
            var patterns = dict["patterns"] as! [[String: Any]]
            var first = patterns[0]
            var citation = first["citation"] as! [String: Any]
            citation["quote"] = "too short"
            first["citation"] = citation
            patterns[0] = first
            dict["patterns"] = patterns
        }
        XCTAssertThrowsError(try CopyLint(patternsData: data)) { error in
            guard case CopyLintError.validationFailed(let reason) = error else {
                return XCTFail("expected CopyLintError.validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("citation.quote too short"), "unexpected reason: \(reason)")
        }
    }

    func testNonHTTPSURLFailsClosed() throws {
        let data = try mutatedPatternData { dict in
            var patterns = dict["patterns"] as! [[String: Any]]
            var first = patterns[0]
            var citation = first["citation"] as! [String: Any]
            citation["url"] = "http://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely"
            first["citation"] = citation
            patterns[0] = first
            dict["patterns"] = patterns
        }
        XCTAssertThrowsError(try CopyLint(patternsData: data)) { error in
            guard case CopyLintError.validationFailed(let reason) = error else {
                return XCTFail("expected CopyLintError.validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("citation.url must be https"), "unexpected reason: \(reason)")
        }
    }

    func testMalformedRetrievalDateFailsClosed() throws {
        let data = try mutatedPatternData { dict in
            var patterns = dict["patterns"] as! [[String: Any]]
            var first = patterns[0]
            var citation = first["citation"] as! [String: Any]
            citation["retrieved"] = "October 11, 2026"
            first["citation"] = citation
            patterns[0] = first
            dict["patterns"] = patterns
        }
        XCTAssertThrowsError(try CopyLint(patternsData: data)) { error in
            guard case CopyLintError.validationFailed(let reason) = error else {
                return XCTFail("expected CopyLintError.validationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("retrieval date must be"), "unexpected reason: \(reason)")
        }
    }
}
