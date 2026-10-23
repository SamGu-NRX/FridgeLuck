import XCTest
@testable import FLTasteSim
import FLTaste

final class CatalogLoaderTests: XCTestCase {

    func testMiniDataJSONParsesIntoTypedCatalog() throws {
        let catalog = try CatalogLoader.load(dataJSON: SimFixtures.miniDataJSON())

        XCTAssertEqual(catalog.ingredients.count, 3)
        XCTAssertEqual(catalog.recipes.count, 2)

        // Ingredient ids are names; numeric keys and hint fields are dropped.
        let egg = try XCTUnwrap(catalog.ingredients[IngredientID("egg")!])
        XCTAssertEqual(egg.caloriesPer100g, 155)
        XCTAssertEqual(egg.proteinPer100g, 13)
        XCTAssertEqual(egg.carbsPer100g, 1.1)
        XCTAssertEqual(egg.fatPer100g, 11)
        XCTAssertEqual(egg.fiberPer100g, 0)

        // Recipe ids are decimal strings; positional uses become typed grams.
        let eggRice = try XCTUnwrap(catalog.recipes[RecipeID("1")!])
        XCTAssertEqual(eggRice.title, "Egg rice")
        XCTAssertEqual(eggRice.timeMinutes, 15)
        XCTAssertEqual(eggRice.servings, 2)
        XCTAssertEqual(
            eggRice.requiredIngredients.map { $0.id.rawValue }, ["egg", "rice"])
        XCTAssertEqual(eggRice.requiredIngredients.map(\.grams), [100, 200])
        XCTAssertEqual(eggRice.optionalIngredients.map { $0.id.rawValue }, ["chicken"])

        // Tag bitmasks decode against CatalogTag: 9 = quick(1) + asian(8).
        XCTAssertTrue(eggRice.hasTag(.quick))
        XCTAssertTrue(eggRice.hasTag(.asian))
        XCTAssertFalse(eggRice.hasTag(.vegetarian))
        // 264 = mexican(256) + mediterranean(8) + quick... 264 = 256+8 = mexican+asian.
        let chickenRice = try XCTUnwrap(catalog.recipes[RecipeID("2")!])
        XCTAssertTrue(chickenRice.hasTag(.mexican))
        XCTAssertTrue(chickenRice.hasTag(.asian))
        XCTAssertFalse(chickenRice.hasTag(.quick))
    }

    func testMalformedInputsThrowWithReason() {
        XCTAssertThrowsError(try CatalogLoader.load(dataJSON: "{}")) { error in
            XCTAssertEqual(
                error as? CatalogLoader.LoaderError, .malformed("missing ingredients object"))
        }
        XCTAssertThrowsError(try CatalogLoader.load(dataJSON: "not json"))
        let badTags = SimFixtures.miniDataJSON()
            .replacingOccurrences(of: "\"asian\"", with: "\"notatag\"")
        XCTAssertThrowsError(try CatalogLoader.load(dataJSON: badTags))
    }

    func testRealAppCatalogLoadsIfPresent() throws {
        guard let path = SimFixtures.repoDataJSONPath() else {
            throw XCTSkip("repo checkout with apps/ios/Resources/data.json not found")
        }
        let json = try String(contentsOfFile: path, encoding: .utf8)
        let catalog = try CatalogLoader.load(dataJSON: json)
        XCTAssertEqual(catalog.ingredients.count, 50, "the app ships 50 core ingredients")
        XCTAssertEqual(catalog.recipes.count, 166, "the app ships 166 recipes")
        // The feature space builds and yields the documented vocabulary.
        let space = FeatureExtractor(catalog: catalog).space
        XCTAssertTrue(space.keys.contains(FeatureKey(namespace: "bias", value: "one")))
        XCTAssertTrue(
            space.keys.contains(FeatureKey(namespace: "ingredient", value: "egg")))
        XCTAssertEqual(space.version, "taste-features-v1")
    }
}
