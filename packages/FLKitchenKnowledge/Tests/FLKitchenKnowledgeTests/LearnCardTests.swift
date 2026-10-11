import XCTest
@testable import FLKitchenKnowledge

final class LearnCardTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)  // .../Tests/FLKitchenKnowledgeTests/
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/carrot.json")
        return try Data(contentsOf: url)
    }

    func testFixtureCardDecodesWithSourcedNutrition() throws {
        let card = try LearnCard.parse(from: fixtureData())

        XCTAssertEqual(card.id, "fixture-carrot")
        XCTAssertEqual(card.displayName, "Carrot")
        XCTAssertTrue(card.isCore)
        XCTAssertEqual(card.category, "vegetable")
        XCTAssertEqual(card.sources.count, 3)

        // Storage defers to the food-safety rulebook instead of restating it.
        XCTAssertEqual(card.sections.storage.foodSafetyRef?.path, "data/food-safety/rules.json")

        // Nutrition vector: present keys decode, absent keys stay nil.
        let nutrition = try XCTUnwrap(card.nutritionPer100g)
        XCTAssertEqual(nutrition.fdcId, 170606)
        XCTAssertEqual(nutrition.fdcDescription, "Carrots, raw")
        XCTAssertEqual(nutrition.nutrients.energyKcal, 41.0)
        XCTAssertEqual(nutrition.nutrients.proteinG, 0.93)
        XCTAssertEqual(nutrition.nutrients.vitaminARaeMcg, 835.0)
        XCTAssertNil(nutrition.nutrients.sugarG, "keys the fixture omits must stay nil")
        XCTAssertNil(nutrition.nutrients.folateMcg)

        XCTAssertEqual(card.substitutions?.count, 1)
        XCTAssertEqual(card.substitutions?.first?.substitute, "parsnip")
    }

    func testCardLookupsAndSourceRegister() throws {
        let directory = try makeTemporaryDirectory(named: "learn-cards-lookup")
        let cards = directory.appendingPathComponent("learn-cards/cards", isDirectory: true)
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        try fixtureData().write(to: cards.appendingPathComponent("fixture-carrot.json"))

        let knowledge = try KitchenKnowledge(directory: directory)

        XCTAssertEqual(knowledge.cards.count, 1)
        XCTAssertEqual(knowledge.card(id: "fixture-carrot")?.displayName, "Carrot")
        XCTAssertEqual(knowledge.cardsInCategory("vegetable").count, 1)
        XCTAssertEqual(knowledge.cardsInCategory("fruit").count, 0)
        XCTAssertEqual(knowledge.cards(named: "carrot").count, 1)
        XCTAssertEqual(knowledge.cards(named: "kale").count, 0)

        // Sources register: every card source surfaces with its licence.
        let sources = knowledge.allSources()
        XCTAssertEqual(sources.count, 3)
        XCTAssertTrue(sources.allSatisfy { !$0.licence.isEmpty && !$0.url.isEmpty })
    }

    func testIndexPayloadDecodes() throws {
        let directory = try makeTemporaryDirectory(named: "learn-cards-index")
        let cards = directory.appendingPathComponent("learn-cards/cards", isDirectory: true)
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        try fixtureData().write(to: cards.appendingPathComponent("fixture-carrot.json"))

        let index = """
        {"schemaVersion":1,"kind":"learn-card-index","retrieved":"2026-10-11","data":{
          "cards":[{"id":"fixture-carrot","displayName":"Carrot","isCore":true,"category":"vegetable","frequencyInBundledRecipes":12,"fdcId":170606}],
          "coverage":{"coreIngredients":50,"bundledDistinctIngredients":180,"cardsWritten":1}
        }}
        """
        try index.write(to: directory.appendingPathComponent("learn-cards/index.json"), atomically: true, encoding: .utf8)

        let knowledge = try KitchenKnowledge(directory: directory)
        XCTAssertEqual(knowledge.learnCardIndex?.cards.count, 1)
        XCTAssertEqual(knowledge.learnCardIndex?.cards.first?.frequencyInBundledRecipes, 12)
        XCTAssertEqual(knowledge.learnCardIndex?.coverage?.cardsWritten, 1)
    }

    func testEmptyDirectoryLoadsNothingWithoutThrowing() throws {
        let directory = try makeTemporaryDirectory(named: "kitchen-knowledge-empty")
        let knowledge = try KitchenKnowledge(directory: directory)
        XCTAssertTrue(knowledge.cards.isEmpty)
        XCTAssertNil(knowledge.waste)
        XCTAssertTrue(knowledge.budgetPacks.isEmpty)
    }
}
