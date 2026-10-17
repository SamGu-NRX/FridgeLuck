import XCTest
@testable import FLKitchenKnowledge

/// The loader contract: a file that fails its shape, id or citation contract
/// throws rather than loading half-sourced data (data/kitchen-knowledge/SCHEMA.md,
/// "Swift loader contract"). Synthetic fixtures exercise each failure mode;
/// the joined-data test proves the real tree passes the same contract.
final class LoaderContractTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeValidTree()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    private static let cardSource = """
        "s1": {"title": "Example source", "publisher": "Example publisher",
               "url": "https://example.com/source", "retrieved": "2026-10-11",
               "licence": "Public domain (U.S. government work)"}
        """

    private func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeValidTree() throws {
        try write("learn-cards/cards/onion.json", """
            {"schemaVersion":1,"kind":"learn-card","retrieved":"2026-10-11","data":{
              "id":"onion","displayName":"Onion","isCore":true,"category":"produce",
              "sections":{
                "whatItIs":{"text":"T","citations":["s1"]},
                "historyNote":{"text":"T","citations":["s1"]},
                "howToChoose":{"text":"T","citations":["s1"]},
                "storage":{"text":"T","citations":["s1"]},
                "useItUp":{"text":"T","citations":["s1"]}},
              "sources":{\(Self.cardSource)}}}
            """)
        try write("learn-cards/index.json", """
            {"schemaVersion":1,"kind":"learn-card-index","retrieved":"2026-10-11","data":{
              "cards":[{"id":"onion","displayName":"Onion","isCore":true,
                        "category":"produce","frequencyInBundledRecipes":2,"fdcId":null}]}}
            """)
        try write("waste/emission_factors.json", """
            {"schemaVersion":1,"kind":"emission-factors","retrieved":"2026-10-11","data":{
              "source":{"citationId":"s1","title":"Emissions","publisher":"OWID",
                        "url":"https://example.com/emissions"},
              "method":"m",
              "factors":[{"ingredientKey":"onion","owidEntity":"Onion",
                          "kgCo2ePerKg":{"low":0.1,"central":0.2,"high":0.3},
                          "citationId":"s1"}]}}
            """)
        try write("waste/price_factors.json", """
            {"schemaVersion":1,"kind":"price-factors","retrieved":"2026-10-11","data":{
              "source":{"citationId":"s2","title":"Prices","publisher":"BLS",
                        "url":"https://example.com/prices"},
              "region":"US city average","asOf":"2026-09","method":"m",
              "prices":[{"ingredientKey":"onion","usdPerKg":1.0,
                         "citationId":"s2"}]}}
            """)
        try write("packs/budget_packs.json", packFile(kind: "budget-packs"))
        try write("packs/use_it_up_packs.json", packFile(kind: "use-it-up-packs", itemsKey: "ingredients"))
        try write("packs/seasonal_packs.json", seasonalFile)
    }

    private func packFile(kind: String, itemsKey: String = "items") -> String {
        """
        {"schemaVersion":1,"kind":"\(kind)","retrieved":"2026-10-11","data":{
          "packs":[{"id":"p1","name":"Pack","budgetUsd":10.0,"region":"US",
                    "priceDate":"2026-09",
                    "\(itemsKey)":[{"ingredientKey":"onion","displayName":"Onion",
                              "quantity":"2 lb","quantityKg":0.9,"priceUsd":2.0,
                              "priceSourceId":"s1","citationIds":["s1"]}],
                    "totalCostUsd":2.0,"citationIds":["s1"]}],
          "sources":[{"id":"s1","title":"BLS AP","publisher":"BLS",
                      "url":"https://download.bls.gov/ap/","retrieved":"2026-10-11",
                      "licence":"Public domain (U.S. government work)"}]}}
        """
    }

    private var seasonalFile: String {
        """
        {"schemaVersion":1,"kind":"seasonal-packs","retrieved":"2026-10-11","data":{
          "regions":[{"id":"midwest","name":"Midwest","definitionCitation":"s1"}],
          "months":[{"month":10,"packs":[{"regionId":"midwest","name":"October",
            "produce":[{"ingredientKey":"onion","displayName":"Onion"}],
            "citationIds":["s1"]}]}],
          "sources":[{"id":"s1","title":"Seasonality","publisher":"USDA",
                      "url":"https://example.com/seasonal","retrieved":"2026-10-11",
                      "licence":"Public domain (U.S. government work)"}]}}
        """
    }

    private func load(_ dir: URL? = nil) throws -> KitchenKnowledge {
        try KitchenKnowledge(directory: dir ?? root)
    }

    /// Mutates one fixture file (first occurrence of `anchor` replaced by
    /// `replacement`), expects the loader to throw a contract error, then
    /// restores the valid tree.
    private func assertContractThrows(
        _ path: String, anchor: String, replacement: String, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var fixture = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        guard fixture.contains(anchor) else {
            XCTFail("\(message): fixture lacks anchor \(anchor)", file: file, line: line)
            return
        }
        fixture = fixture.replacingOccurrences(of: anchor, with: replacement)
        try fixture.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try load(), message, file: file, line: line) { error in
            XCTAssertTrue(
                error is MissingSourceError || error is DuplicateIdError
                    || error is InvalidNumericError,
                "\(message): expected a contract error, got \(error)",
                file: file, line: line
            )
        }
        try writeValidTree()
    }

    // MARK: - Envelope contract

    func testValidTreeLoads() throws {
        let knowledge = try load()
        XCTAssertEqual(knowledge.cards.map(\.id), ["onion"])
        XCTAssertEqual(knowledge.budgetPacks.count, 1)
        XCTAssertEqual(knowledge.packSourcesByFile["budget_packs"]?.map(\.id), ["s1"])
        XCTAssertFalse(knowledge.allPackSources().isEmpty, "pack sources must load")
        XCTAssertNotNil(knowledge.waste)
        XCTAssertEqual(knowledge.waste?.emission(for: "onion")?.citationId, "s1")
    }

    func testWrongKindRefuses() throws {
        // A budget-packs file claiming another kind must not load.
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"budget-packs\"",
            replacement: "\"food-bank-packs\"", "wrong-kind envelope must throw")
    }

    func testWrongSchemaVersionRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"schemaVersion\":1",
            replacement: "\"schemaVersion\":2", "unsupported schemaVersion must throw")
    }

    // MARK: - Duplicate ids

    func testDuplicateCardIdRefuses() throws {
        // A second card file with the same id must throw, not crash the
        // uniqueKeysWithValues dictionary the loader builds.
        var twin = try String(
            contentsOf: root.appendingPathComponent("learn-cards/cards/onion.json"),
            encoding: .utf8)
        try write("learn-cards/cards/onion_twin.json", twin)
        _ = twin
        XCTAssertThrowsError(try load(), "duplicate card id must throw") { error in
            XCTAssertTrue(error is DuplicateIdError, "got \(error)")
        }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("learn-cards/cards/onion_twin.json"))
    }

    func testDuplicatePackIdRefuses() throws {
        var fixture = packFile(kind: "budget-packs")
        let anchor = "\"totalCostUsd\":2.0,\"citationIds\":[\"s1\"]}]"
        let twin = "\"totalCostUsd\":2.0,\"citationIds\":[\"s1\"]},{\"id\":\"p1\",\"name\":\"Pack2\","
            + "\"budgetUsd\":10.0,\"region\":\"US\",\"priceDate\":\"2026-09\",\"items\":[],"
            + "\"totalCostUsd\":0.0,\"citationIds\":[]}]"
        guard fixture.contains(anchor) else {
            XCTFail("duplicate-pack fixture anchor missing")
            return
        }
        fixture = fixture.replacingOccurrences(of: anchor, with: twin)
        try fixture.write(to: root.appendingPathComponent("packs/budget_packs.json"),
                          atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try load(), "duplicate pack id must throw") { error in
            XCTAssertTrue(error is DuplicateIdError, "got \(error)")
        }
        try writeValidTree()
    }

    func testDuplicateSourceRecordIdRefuses() throws {
        var fixture = try String(
            contentsOf: root.appendingPathComponent("packs/budget_packs.json"),
            encoding: .utf8)
        let record = "{\"id\":\"s1\",\"title\":\"BLS AP\",\"publisher\":\"BLS\",\"url\":\"https://download.bls.gov/ap/\",\"retrieved\":\"2026-10-11\",\"licence\":\"Public domain (U.S. government work)\"}"
        let range = fixture.range(of: "\"sources\":[")!
        fixture.replaceSubrange(range.upperBound..<range.upperBound,
                                with: record + ",")
        try fixture.write(to: root.appendingPathComponent("packs/budget_packs.json"),
                          atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try load(), "duplicate source-record id must throw") { error in
            XCTAssertTrue(error is DuplicateIdError, "got \(error)")
        }
        try writeValidTree()
    }

    func testDuplicateEmissionKeyRefuses() throws {
        var fixture = try String(
            contentsOf: root.appendingPathComponent("waste/emission_factors.json"),
            encoding: .utf8)
        let anchor = "\"citationId\":\"s1\"}]"
        let duplicated = "\"citationId\":\"s1\"},{\"ingredientKey\":\"onion\","
            + "\"owidEntity\":\"Onion\",\"kgCo2ePerKg\":{\"low\":0.1,\"central\":0.2,\"high\":0.3},"
            + "\"citationId\":\"s1\"}]"
        guard fixture.contains(anchor) else {
            XCTFail("duplicate-emission fixture anchor missing")
            return
        }
        fixture = fixture.replacingOccurrences(of: anchor, with: duplicated)
        try fixture.write(to: root.appendingPathComponent("waste/emission_factors.json"),
                          atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try load(), "duplicate ingredient key must throw") { error in
            XCTAssertTrue(error is DuplicateIdError, "got \(error)")
        }
        try writeValidTree()
    }

    // MARK: - Citation references

    func testUnknownPackCitationRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"citationIds\":[\"s1\"]}",
            replacement: "\"citationIds\":[\"sX\"]}", "unknown pack citation must throw")
    }

    func testUnknownPriceSourceRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"priceSourceId\":\"s1\"",
            replacement: "\"priceSourceId\":\"sX\"", "unknown priceSourceId must throw")
    }

    func testUnknownWasteRowCitationRefuses() throws {
        try assertContractThrows(
            "waste/emission_factors.json", anchor: "\"citationId\":\"s1\"}]",
            replacement: "\"citationId\":\"sX\"}]", "unknown factor-row citation must throw")
    }

    func testUnknownSeasonalRegionRefuses() throws {
        try assertContractThrows(
            "packs/seasonal_packs.json", anchor: "\"regionId\":\"midwest\"",
            replacement: "\"regionId\":\"nowhere\"", "unknown region reference must throw")
    }

    func testSeasonalMonthOutOfRangeRefuses() throws {
        try assertContractThrows(
            "packs/seasonal_packs.json", anchor: "\"month\":10",
            replacement: "\"month\":13", "month outside 1...12 must throw")
    }

    // MARK: - Numeric contract

    /// Injects a nutrition block with the given nutrient fields into the
    /// fixture card (before its sections), mirroring a card that carries
    /// nutrition from source s1.
    private func injectNutrition(_ nutrientsJSON: String) throws {
        var card = try String(
            contentsOf: root.appendingPathComponent("learn-cards/cards/onion.json"),
            encoding: .utf8)
        let nutrition = "\"nutritionPer100g\":{\"fdcId\":170026,\"fdcDescription\":\"X\","
            + "\"fdcDataType\":\"SR Legacy\",\"sourceId\":\"s1\",\"nutrients\":{"
            + "\(nutrientsJSON)}},"
        let anchor = card.range(of: "\"sections\":")!
        card.replaceSubrange(anchor.lowerBound..<anchor.lowerBound, with: nutrition)
        try card.write(to: root.appendingPathComponent("learn-cards/cards/onion.json"),
                       atomically: true, encoding: .utf8)
    }

    func testNegativeNutrientThrowsInvalidNumericError() throws {
        try injectNutrition("\"energyKcal\":-5")
        XCTAssertThrowsError(try load(), "negative kcal must throw") { error in
            XCTAssertTrue(error is InvalidNumericError, "got \(error)")
        }
        try writeValidTree()
    }

    func testOverCapNutrientRefuses() throws {
        // 5000 kcal per 100 g is physically impossible (pure fat is 884).
        try injectNutrition("\"energyKcal\":5000")
        XCTAssertThrowsError(try load(), "over-cap nutrient must throw") { error in
            XCTAssertTrue(error is InvalidNumericError, "got \(error)")
        }
        try writeValidTree()
    }

    func testNegativeBudgetItemPriceRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"priceUsd\":2.0",
            replacement: "\"priceUsd\":-2.0", "negative item price must throw")
    }

    func testNegativeBudgetRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"budgetUsd\":10.0",
            replacement: "\"budgetUsd\":-10.0", "negative budget must throw")
    }

    func testNegativeQuantityKgRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"quantityKg\":0.9",
            replacement: "\"quantityKg\":-0.9", "negative item mass must throw")
    }

    func testMisorderedEmissionRangeRefuses() throws {
        try assertContractThrows(
            "waste/emission_factors.json",
            anchor: "\"kgCo2ePerKg\":{\"low\":0.1,\"central\":0.2,\"high\":0.3}",
            replacement: "\"kgCo2ePerKg\":{\"low\":0.3,\"central\":0.2,\"high\":0.1}",
            "low > high emission range must throw")
    }

    func testNegativeUsdPerKgRefuses() throws {
        try assertContractThrows(
            "waste/price_factors.json", anchor: "\"usdPerKg\":1.0",
            replacement: "\"usdPerKg\":-1.0", "negative price factor must throw")
    }

    func testBudgetItemMissingPriceRefuses() throws {
        // A budget basket is priced line by line: a missing price must
        // refuse, never silently shrink the sum.
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"priceUsd\":2.0,",
            replacement: "", "missing budget item price must throw")
    }

    func testBudgetTotalMismatchRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"totalCostUsd\":2.0",
            replacement: "\"totalCostUsd\":3.0",
            "stated total must match the item sum")
    }

    func testBudgetOverspendRefuses() throws {
        try assertContractThrows(
            "packs/budget_packs.json", anchor: "\"budgetUsd\":10.0",
            replacement: "\"budgetUsd\":1.0",
            "item prices above the stated budget must throw")
    }

    func testOverCapEmissionRefuses() throws {
        // 300 kgCO2e/kg is beyond any credible per-kg food inventory
        // (shipped max 99.48).
        try assertContractThrows(
            "waste/emission_factors.json",
            anchor: "\"kgCo2ePerKg\":{\"low\":0.1,\"central\":0.2,\"high\":0.3}",
            replacement: "\"kgCo2ePerKg\":{\"low\":0.1,\"central\":0.2,\"high\":300}",
            "over-cap emission factor must throw")
    }

    func testOverCapUsdPerKgRefuses() throws {
        // 2000 USD/kg is a decimal or unit slip for a grocery staple
        // (shipped max 15.97).
        try assertContractThrows(
            "waste/price_factors.json", anchor: "\"usdPerKg\":1.0",
            replacement: "\"usdPerKg\":2000.0", "over-cap price factor must throw")
    }

    // MARK: - Index <-> cards consistency

    func testIndexListingUnknownCardRefuses() throws {
        try assertContractThrows(
            "learn-cards/index.json", anchor: "\"id\":\"onion\"",
            replacement: "\"id\":\"garlic\"", "index must only list existing cards")
    }

    func testCardMissingFromIndexRefuses() throws {
        // An index that lists nothing while a card file exists must refuse.
        try write("learn-cards/index.json", """
            {"schemaVersion":1,"kind":"learn-card-index","retrieved":"2026-10-11","data":{
              "cards":[]}}
            """)
        XCTAssertThrowsError(try load(), "card missing from the index must throw") { error in
            XCTAssertTrue(error is MissingSourceError, "got \(error)")
        }
        try writeValidTree()
    }

    func testIndexNutritionDisagreementRefuses() throws {
        // Give the card nutrition from source s1, but leave the index's
        // fdcId null: the mirror must disagree loudly.
        var card = try String(
            contentsOf: root.appendingPathComponent("learn-cards/cards/onion.json"),
            encoding: .utf8)
        let nutrition = "\"nutritionPer100g\":{\"fdcId\":170026,\"fdcDescription\":\"X\",\"fdcDataType\":\"sr_legacy\",\"sourceId\":\"s1\",\"nutrients\":{\"energyKcal\":40.0}},"
        let anchor = card.range(of: "\"sections\":")!
        card.replaceSubrange(anchor.lowerBound..<anchor.lowerBound, with: nutrition)
        try card.write(to: root.appendingPathComponent("learn-cards/cards/onion.json"),
                       atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try load(), "index fdcId disagreement must throw") { error in
            XCTAssertTrue(error is MissingSourceError, "got \(error)")
        }
        try writeValidTree()
    }

    // MARK: - Joined data

    func testJoinedRealTreePassesTheContract() throws {
        let dataDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FLKitchenKnowledgeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // FLKitchenKnowledge/
            .deletingLastPathComponent()  // packages/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("data/kitchen-knowledge", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dataDirectory.path) else {
            throw XCTSkip("data/kitchen-knowledge not on this branch yet (awaiting join)")
        }
        let knowledge = try KitchenKnowledge(directory: dataDirectory)
        XCTAssertGreaterThanOrEqual(knowledge.cards.count, 100, "learn cards must load")
        // The loader now captures pack provenance.
        XCTAssertGreaterThanOrEqual(knowledge.allPackSources().count, 1, "pack sources must load")
        for (file, sources) in knowledge.packSourcesByFile {
            XCTAssertFalse(sources.isEmpty, "pack file \(file) must carry sources")
        }
        // All citation ids across the loaded packs resolve by construction:
        // the loader threw otherwise; assert the non-vacuous case too.
        XCTAssertGreaterThanOrEqual(knowledge.budgetPacks.count, 1)
        XCTAssertGreaterThanOrEqual(knowledge.useItUpPacks.count, 1)
    }
}
