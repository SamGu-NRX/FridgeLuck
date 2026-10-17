import XCTest
@testable import FLKitchenKnowledge

final class PackTests: XCTestCase {
    func testBudgetPackDecodesAndStaysUnderBudget() throws {
        let json = """
        {"schemaVersion":1,"kind":"budget-packs","retrieved":"2026-10-11","data":{
          "packs":[{
            "id":"budget-us-10","name":"$10 week: rice-and-beans anchor","budgetUsd":10.0,
            "region":"United States, national average","priceDate":"2026-09",
            "items":[
              {"ingredientKey":"rice","displayName":"long-grain white rice","usdaFdcId":168878,
               "quantity":"1 lb bag","quantityKg":0.45359237,"priceUsd":1.02,"priceSourceId":"s1"},
              {"ingredientKey":"dried beans","displayName":"dried black beans","usdaFdcId":173735,
               "quantity":"1 lb bag","quantityKg":0.45359237,"priceUsd":1.48,"priceSourceId":"s1"}
            ],
            "totalCostUsd":2.50,"citationIds":["s1"],"notes":"fixture"
          }],
          "notes":"fixture packs"
        }}
        """
        let payload = try JSONDecoder()
            .decode(DataEnvelope<BudgetPacksPayload>.self, from: Data(json.utf8)).data

        let pack = try XCTUnwrap(payload.packs.first)
        XCTAssertEqual(pack.items.count, 2)
        XCTAssertEqual(pack.budgetUsd, 10.0)

        // The sum of item prices must equal the stated total and stay under budget.
        let sum = pack.items.compactMap(\.priceUsd).reduce(0, +)
        XCTAssertEqual(sum, pack.totalCostUsd ?? sum, accuracy: 0.001)
        XCTAssertLessThanOrEqual(sum, pack.budgetUsd)
    }

    func testFoodBankAndUseItUpPacksDecode() throws {
        let json = """
        {"schemaVersion":1,"kind":"food-bank-packs","retrieved":"2026-10-11","data":{
          "packs":[{
            "id":"tefap-typical-1","name":"Common TEFAP distribution basket",
            "items":[{"ingredientKey":"canned green beans","displayName":"canned cut green beans",
                      "usdaFdcId":170722,"typicalForm":"canned, drained","citationIds":["s2"]}],
            "citationIds":["s2"],"distributionNote":"fixture note"
          }]
        }}
        """
        let payload = try JSONDecoder()
            .decode(DataEnvelope<FoodBankPacksPayload>.self, from: Data(json.utf8)).data
        XCTAssertEqual(payload.packs.first?.items.first?.typicalForm, "canned, drained")

        let useItUp = """
        {"schemaVersion":1,"kind":"use-it-up-packs","retrieved":"2026-10-11","data":{
          "packs":[{
            "id":"stale-bread","name":"Bread box rescue","situation":"bread going stale",
            "ingredients":[{"ingredientKey":"bread","displayName":"bread","usdaFdcId":18069}],
            "tactic":"fixture tactic","citationIds":[]
          }]
        }}
        """
        let useItUpPayload = try JSONDecoder()
            .decode(DataEnvelope<UseItUpPacksPayload>.self, from: Data(useItUp.utf8)).data
        XCTAssertEqual(useItUpPayload.packs.first?.id, "stale-bread")
    }

    func testSeasonalPayloadDecodes() throws {
        let json = """
        {"schemaVersion":1,"kind":"seasonal-packs","retrieved":"2026-10-11","data":{
          "regions":[{"id":"northeast","name":"US Northeast","definitionCitation":"s3"}],
          "months":[{"month":1,"packs":[{"regionId":"northeast","name":"January in the Northeast",
            "produce":[{"ingredientKey":"cabbage","displayName":"cabbage","usdaFdcId":170029,"note":null}],
            "citationIds":["s4"]}]}]
        }}
        """
        let payload = try JSONDecoder()
            .decode(DataEnvelope<SeasonalPacksPayload>.self, from: Data(json.utf8)).data
        XCTAssertEqual(payload.regions.first?.id, "northeast")
        XCTAssertEqual(payload.months.first?.month, 1)
        XCTAssertEqual(payload.months.first?.packs.first?.produce.first?.usdaFdcId, 170029)
    }
}
