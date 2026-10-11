import XCTest
@testable import FLKitchenKnowledge

/// The missing-source refusal contract: numbers without a cited source never
/// load, and ledger totals never absorb unpriced grams silently.
final class RefusalTests: XCTestCase {
    private func cardData(_ json: String) -> Data {
        Data(json.utf8)
    }

    private var validCardJSON: String {
        """
        {"schemaVersion":1,"kind":"learn-card","retrieved":"2026-10-11","data":{
          "id":"rice","displayName":"Rice","isCore":true,"category":"grain",
          "sections":{
            "whatItIs":{"text":"x","citations":["s1"]},
            "historyNote":{"text":"x","citations":["s2"]},
            "howToChoose":{"text":"x","citations":[]},
            "storage":{"text":"x","citations":[],"foodSafetyRef":{"path":"data/food-safety/rules.json","note":"rulebook"}},
            "useItUp":{"text":"x","citations":[]}},
          "sources":{"s1":{"title":"t","publisher":"p","url":"https://example.test/1","retrieved":"2026-10-11","licence":"PD"},
                     "s2":{"title":"t","publisher":"p","url":"https://example.test/2","retrieved":"2026-10-11","licence":"PD"}}
        }}
        """
    }

    func testCardWithDanglingNutritionSourceRefuses() {
        // Nutrition block points at a source that is not in the sources map:
        // the card must refuse to load. (Full literal, no string surgery.)
        let broken = """
        {"schemaVersion":1,"kind":"learn-card","retrieved":"2026-10-11","data":{
          "id":"rice","displayName":"Rice","isCore":true,"category":"grain",
          "sections":{
            "whatItIs":{"text":"x","citations":["s1"]},
            "historyNote":{"text":"x","citations":["s2"]},
            "howToChoose":{"text":"x","citations":[]},
            "storage":{"text":"x","citations":[],"foodSafetyRef":{"path":"data/food-safety/rules.json","note":"rulebook"}},
            "useItUp":{"text":"x","citations":[]}},
          "nutritionPer100g":{"fdcId":170190,"fdcDescription":"Rice, white, long-grain, regular, raw, unenriched","fdcDataType":"SR Legacy","sourceId":"s7","nutrients":{"energyKcal":365}},
          "sources":{"s1":{"title":"t","publisher":"p","url":"https://example.test/1","retrieved":"2026-10-11","licence":"PD"},
                     "s2":{"title":"t","publisher":"p","url":"https://example.test/2","retrieved":"2026-10-11","licence":"PD"}}
        }}
        """

        XCTAssertThrowsError(try LearnCard.parse(from: cardData(broken))) { error in
            guard let missing = error as? MissingSourceError else {
                return XCTFail("expected MissingSourceError, got \(error)")
            }
            XCTAssertTrue(missing.subject.contains("nutritionPer100g"))
        }
    }

    func testCardWithoutHistoryCitationRefuses() {
        let broken = validCardJSON.replacingOccurrences(
            of: "\"historyNote\":{\"text\":\"x\",\"citations\":[\"s2\"]}",
            with: "\"historyNote\":{\"text\":\"x\",\"citations\":[]}"
        )
        XCTAssertThrowsError(try LearnCard.parse(from: cardData(broken)))
    }

    func testCardWithoutFoodSafetyRefRefuses() {
        let broken = validCardJSON.replacingOccurrences(
            of: "\"storage\":{\"text\":\"x\",\"citations\":[],\"foodSafetyRef\":{\"path\":\"data/food-safety/rules.json\",\"note\":\"rulebook\"}}",
            with: "\"storage\":{\"text\":\"x\",\"citations\":[]}"
        )
        XCTAssertThrowsError(try LearnCard.parse(from: cardData(broken)))
    }

    func testLedgerRefusesUnpricedIngredientsInsteadOfGuessing() throws {
        // rice has both factors; an exotic mushroom has neither. The mushroom's
        // grams stay visible in its bucket but are excluded from money and CO2e,
        // and the refusal is reported.
        var ledger = WasteLedger(
            prices: [PriceFactor(ingredientKey: "rice", usdPerKg: 1.5, displayQuantity: nil, displayPriceUsd: nil, sourceSeries: nil, citationId: "s1")],
            emissions: [EmissionFactor(ingredientKey: "rice", owidEntity: nil, kgCo2ePerKg: Range3(low: 1.8, central: 1.8, high: 1.8), citationId: "s2")]
        )
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "rice", grams: 500, on: "2026-10-10"))
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "maitake-mushroom", grams: 250, on: "2026-10-10"))

        let result = ledger.result()
        XCTAssertEqual(result.wasted.grams, 750.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.wasted.moneyUsd), 0.75, accuracy: 0.0001) // rice only
        XCTAssertEqual(try XCTUnwrap(result.wasted.kgCo2e?.central), 0.9, accuracy: 0.0001) // rice only

        XCTAssertEqual(result.refusals.count, 2)
        XCTAssertTrue(result.refusals.contains {
            $0.ingredientKey == "maitake-mushroom" && $0.reason == .missingPrice
                && ($0.grams - 250.0).magnitude < 0.001
        })
        XCTAssertTrue(result.refusals.contains {
            $0.ingredientKey == "maitake-mushroom" && $0.reason == .missingEmissionFactor
        })
    }

    func testRefusalsAggregateAcrossBucketsPerIngredientAndReason() throws {
        var ledger = WasteLedger()
        ledger.record(KitchenEvent(kind: .discard, ingredientKey: "x", grams: 100, on: "2026-10-10"))
        ledger.record(KitchenEvent(kind: .expire, ingredientKey: "x", grams: 50, on: "2026-10-10"))
        let result = ledger.result()
        XCTAssertEqual(result.refusals.count, 2)
        XCTAssertEqual(try XCTUnwrap(result.refusals.first { $0.reason == .missingPrice }).grams, 150.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.refusals.first { $0.reason == .missingEmissionFactor }).grams, 150.0, accuracy: 0.001)
    }

    func testWrongEnvelopeKindOrVersionRefuses() {
        let wrongKind = """
        {"schemaVersion":1,"kind":"not-a-card","retrieved":"2026-10-11","data":{}}
        """
        XCTAssertThrowsError(try DataEnvelope<LearnCard>.decode(cardData(wrongKind), expectingKind: "learn-card"))

        let wrongVersion = """
        {"schemaVersion":2,"kind":"learn-card","retrieved":"2026-10-11","data":{}}
        """
        XCTAssertThrowsError(try DataEnvelope<LearnCard>.decode(cardData(wrongVersion), expectingKind: "learn-card"))
    }
}
