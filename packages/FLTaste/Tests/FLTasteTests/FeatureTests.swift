import XCTest
@testable import FLTaste

/// Feature extraction behaviour per FEATURES.md: documented rules, stable
/// vocabulary, deterministic values.
final class FeatureTests: XCTestCase {
    var space: FeatureSpace!
    var extractor: FeatureExtractor!

    override func setUp() {
        super.setUp()
        space = FeatureSpace(catalog: Fixtures.catalog())
        extractor = FeatureExtractor(catalog: Fixtures.catalog())
    }

    private func ones() -> [Double] { Array(repeating: 1, count: space.dimension) }

    private func value(_ recipe: RecipeID, _ key: FeatureKey) -> Double {
        guard let index = space.index(of: key) else { return .nan }
        return extractor.extract(Fixtures.catalog().recipes[recipe]!, catalog: Fixtures.catalog())
            .dot(ones(), keeping: [index])
    }

    func testVersionStringMatchesSpec() {
        XCTAssertEqual(extractor.version, "taste-features-v1")
        XCTAssertEqual(space.version, "taste-features-v1")
    }

    func testVocabularyIsSortedAndComplete() {
        XCTAssertEqual(space.keys, space.keys.sorted())
        // Every namespace from FEATURES.md is present.
        let namespaces = Set(space.keys.map(\.namespace))
        XCTAssertEqual(
            namespaces,
            [
                "bias", "ingredient", "cuisine", "style", "time", "effort", "servings",
                "nutrition.calorie", "nutrition.protein", "nutrition.fiber", "spice", "cost",
                "complexity", "technique",
            ])
        // Index round-trip.
        for (i, key) in space.keys.enumerated() {
            XCTAssertEqual(space.index(of: key), i)
            XCTAssertEqual(space.key(at: i), key)
        }
    }

    func testIngredientWeightsRequiredVersusOptional() {
        // r_peanut_noodles requires peanut_butter and lists lime as optional.
        XCTAssertEqual(
            value(RecipeID("r_peanut_noodles")!, FeatureKey(namespace: "ingredient", value: "peanut_butter")),
            1.0, accuracy: 1e-12)
        XCTAssertEqual(
            value(RecipeID("r_peanut_noodles")!, FeatureKey(namespace: "ingredient", value: "lime")),
            0.5, accuracy: 1e-12)
        XCTAssertNil(
            space.index(of: FeatureKey(namespace: "ingredient", value: "lime.opt")),
            "there is no separate .opt key")
    }

    func testNutritionUsesAppPerServingRule() {
        // Hand-computed: rice 300g @130/100g + chicken 400g @165/100g
        // = 390 + 660 = 1050 kcal over 4 servings = 262.5 kcal/serving.
        let baked = Fixtures.catalog().recipes[RecipeID("r_baked_rice")!]!
        let nutrition = extractor.nutritionPerServing(baked, catalog: Fixtures.catalog())
        XCTAssertEqual(nutrition.calories, 262.5, accuracy: 0.001)
        // le400 bucket set.
        XCTAssertEqual(
            value(RecipeID("r_baked_rice")!, FeatureKey(namespace: "nutrition.calorie", value: "le400")),
            1.0, accuracy: 1e-12)
        XCTAssertEqual(
            value(RecipeID("r_baked_rice")!, FeatureKey(namespace: "nutrition.calorie", value: "400to650")),
            0.0, accuracy: 1e-12)
    }

    func testTimeEffortServingsBuckets() {
        // r_tofu_salad: 15 min → le15; 2 ingredient kinds → simple; 1 serving → one.
        XCTAssertEqual(value(RecipeID("r_tofu_salad")!, FeatureKey(namespace: "time", value: "le15")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_tofu_salad")!, FeatureKey(namespace: "effort", value: "simple")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_tofu_salad")!, FeatureKey(namespace: "servings", value: "one")), 1.0, accuracy: 1e-12)
        // r_baked_rice: 90 min → gt60; 4 servings → threeToFour.
        XCTAssertEqual(value(RecipeID("r_baked_rice")!, FeatureKey(namespace: "time", value: "gt60")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_baked_rice")!, FeatureKey(namespace: "servings", value: "threeToFour")), 1.0, accuracy: 1e-12)
    }

    func testSpiceTiersFollowFixedIngredientLists() {
        XCTAssertEqual(value(RecipeID("r_chili_rice")!, FeatureKey(namespace: "spice", value: "hot")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_rice_bowl")!, FeatureKey(namespace: "spice", value: "mild")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_baked_rice")!, FeatureKey(namespace: "spice", value: "none")), 1.0, accuracy: 1e-12)
    }

    func testCostProxyFollowsBudgetTag() {
        XCTAssertEqual(value(RecipeID("r_peanut_noodles")!, FeatureKey(namespace: "cost", value: "budget")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_cilantro_chicken")!, FeatureKey(namespace: "cost", value: "standard")), 1.0, accuracy: 1e-12)
    }

    func testTechniquesComeFromInstructionKeywords() {
        XCTAssertEqual(value(RecipeID("r_baked_rice")!, FeatureKey(namespace: "technique", value: "bake")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_peanut_noodles")!, FeatureKey(namespace: "technique", value: "boil")), 1.0, accuracy: 1e-12)
        XCTAssertEqual(value(RecipeID("r_cilantro_chicken")!, FeatureKey(namespace: "technique", value: "grill")), 1.0, accuracy: 1e-12)
    }

    func testExtractionIsDeterministic() throws {
        let catalog = Fixtures.catalog()
        let salad = try XCTUnwrap(catalog.recipes[RecipeID("r_tofu_salad")!])
        let a = extractor.extract(salad, catalog: catalog)
        let b = extractor.extract(salad, catalog: catalog)
        XCTAssertEqual(a.components.count, b.components.count)
        for (x, y) in zip(a.components, b.components) {
            XCTAssertEqual(x.index, y.index)
            XCTAssertEqual(x.value, y.value)
        }
        // Indices strictly increasing (canonical sparse order).
        let indices = a.components.map(\.index)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count, "no duplicate indices")
    }

    func testUnknownRecipeExtractsOnlyBias() {
        let ghost = CatalogRecipe(
            id: RecipeID("r_ghost")!, title: "Ghost", timeMinutes: 10, servings: 1,
            requiredIngredients: [], optionalIngredients: [], instructions: "", tagBitmask: 0)
        let vector = extractor.extract(ghost, catalog: Fixtures.catalog())
        // A degenerate recipe still carries structural buckets (time, effort,
        // servings, nutrition, spice-none, cost, complexity, bias) but must
        // carry no identity, cuisine, style, or technique features.
        let namespaces = Set(
            vector.components.compactMap { space.key(at: $0.index)?.namespace })
        XCTAssertFalse(namespaces.contains("ingredient"), "no ingredient features for an empty recipe")
        XCTAssertFalse(namespaces.contains("cuisine"), "no cuisine features for an untagged recipe")
        XCTAssertFalse(namespaces.contains("style"), "no style features for an untagged recipe")
        XCTAssertFalse(namespaces.contains("technique"), "no technique features without instructions")
        XCTAssertTrue(namespaces.contains("bias"), "intercept is always present")
    }
}
