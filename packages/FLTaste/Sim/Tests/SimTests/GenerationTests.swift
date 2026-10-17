import XCTest
@testable import FLTasteSim
import FLTaste

final class GenerationTests: XCTestCase {

    func testHouseholdGenerationIsDeterministicPerSeed() {
        let catalog = SimFixtures.catalog()
        let config = SimFixtures.config(seed: 42)

        let first = HouseholdFactory.generate(config: config, catalog: catalog)
        let second = HouseholdFactory.generate(config: config, catalog: catalog)
        XCTAssertEqual(first.eaters.count, second.eaters.count)
        for (a, b) in zip(first.eaters, second.eaters) {
            XCTAssertEqual(a.latent, b.latent)
            XCTAssertEqual(a.restrictions, b.restrictions)
            XCTAssertEqual(a.id.rawValue, b.id.rawValue)
        }

        let other = HouseholdFactory.generate(config: SimFixtures.config(seed: 43), catalog: catalog)
        let differ = zip(first.eaters, other.eaters).contains { $0.latent != $1.latent }
        XCTAssertTrue(differ, "a different seed must draw a different household")
    }

    func testTwoEaterHouseholdUnionJoinsRestrictions() {
        // restrictionProbability = 1 forces one restriction per eater.
        var config = SimFixtures.config(seed: 5)
        config.restrictionProbability = 1.0
        let catalog = SimFixtures.catalog()
        let household = HouseholdFactory.generate(config: config, catalog: catalog)

        XCTAssertEqual(household.eaters.count, 2)
        XCTAssertEqual(household.eaters[0].restrictions.count, 1)
        XCTAssertEqual(household.eaters[1].restrictions.count, 1)

        // The union contains both eaters' restrictions: two eaters with
        // different restrictions must both bind.
        let union = household.restrictionUnion
        XCTAssertEqual(union.count, 2, "union holds one restriction per distinct draw")
        let targets = Set(union.map(\.target))
        XCTAssertEqual(targets, Set(household.eaters.flatMap { $0.restrictions.map(\.target) }))
    }

    func testOneEaterHouseholdUnionIsItsOwn() {
        var config = SimFixtures.config(seed: 9, householdSize: 1)
        config.restrictionProbability = 1.0
        let household = HouseholdFactory.generate(config: config, catalog: SimFixtures.catalog())

        XCTAssertEqual(household.eaters.count, 1)
        XCTAssertEqual(household.eaterIDs.first?.rawValue, "e1")
        XCTAssertEqual(household.restrictionUnion, household.eaters[0].restrictions)
    }

    func testLatentLivesOverTheRealFeatureSpace() throws {
        let catalog = SimFixtures.catalog()
        let config = SimFixtures.config(seed: 11)
        let space = FeatureExtractor(catalog: catalog).space
        let household = HouseholdFactory.generate(config: config, catalog: catalog)

        for eater in household.eaters {
            XCTAssertEqual(eater.latent.count, space.dimension)

            // The vector is sparse and ingredient-shaped: some liked, some
            // disliked, most features untouched. Utilities must vary across
            // recipes — a constant vector would make every choice a coin toss.
            var utilities: [Double] = []
            let extractor = FeatureExtractor(catalog: catalog)
            for id in catalog.recipes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let recipe = try XCTUnwrap(catalog.recipes[id])
                utilities.append(extractor.extract(recipe, catalog: catalog).dot(eater.latent))
            }
            let distinct = Set(utilities.map { ($0 * 1000).rounded() })
            XCTAssertGreaterThan(distinct.count, 5, "latent taste must separate recipes")
            XCTAssertLessThan(utilities.count, 100)  // sanity on the fixture size
        }
    }

    func testZeroRestrictionProbabilityYieldsUnrestrictedHousehold() {
        var config = SimFixtures.config(seed: 3)
        config.restrictionProbability = 0
        let household = HouseholdFactory.generate(config: config, catalog: SimFixtures.catalog())
        XCTAssertEqual(household.restrictionUnion, [])
    }
}

final class WorldTests: XCTestCase {

    func testShopRespectsWeeklyBudget() throws {
        let catalog = SimFixtures.catalog()
        var config = SimFixtures.config()
        config.weeklyBudget = 8.0  // deliberately tight
        var world = World(config: config, catalog: catalog)
        world.startWeek(week: 0, shelfLifeWeeks: config.pantryShelfLifeWeeks)

        let plans = try allRecipes(catalog).prefix(6).map { $0 }
        let record = world.shop(week: 0, plans: plans)

        XCTAssertLessThanOrEqual(record.spent, config.weeklyBudget + 1e-9)
        XCTAssertLessThan(record.boughtRecipeIds.count, plans.count, "a tight budget must drop plans")
        XCTAssertEqual(record.plannedRecipeIds, plans.map { $0.id.rawValue })
        XCTAssertGreaterThan(record.spent, 0)
    }

    func testPantrySupportConsumeAndSpoil() throws {
        let catalog = SimFixtures.catalog()
        var config = SimFixtures.config()
        config.weeklyBudget = 1000  // ample
        var world = World(config: config, catalog: catalog)
        world.startWeek(week: 0, shelfLifeWeeks: 2)

        let soup = try XCTUnwrap(catalog.recipes[RecipeID("r_noodle_soup")!])
        XCTAssertFalse(world.pantry.supports(soup), "empty pantry supports nothing")

        _ = world.shop(week: 0, plans: [soup])
        XCTAssertTrue(world.pantry.supports(soup))
        let soupUses = soup.requiredIngredients.map { $0.id }
        for id in soupUses {
            XCTAssertEqual(
                world.pantry.grams(of: id),
                soup.requiredIngredients.first { $0.id == id }?.grams ?? 0)
        }

        // Cooking consumes exactly the required grams; optional uses vanish
        // when present.
        world.consume(soup)
        for use in soup.requiredIngredients {
            XCTAssertEqual(world.pantry.grams(of: use.id), 0, accuracy: 1e-9)
        }

        // Spoilage: a lot bought in week w is gone at week w + 2.
        world.startWeek(week: 1, shelfLifeWeeks: 2)
        _ = world.shop(week: 1, plans: [soup])
        XCTAssertTrue(world.pantry.supports(soup))
        world.startWeek(week: 3, shelfLifeWeeks: 2)
        XCTAssertFalse(world.pantry.supports(soup), "all lots bought in week 1 spoiled by week 3")
    }

    func testFeasibilityFilterEnforcesRestrictionsNeverSuggestAndCapability() throws {
        let catalog = SimFixtures.catalog()
        let eggRice = try XCTUnwrap(catalog.recipes[RecipeID("r_egg_rice")!])
        let vegBowl = try XCTUnwrap(catalog.recipes[RecipeID("r_veg_bowl")!])
        let bake = try XCTUnwrap(catalog.recipes[RecipeID("r_chicken_bake")!])

        // Egg allergy blocks the egg recipe only.
        var filter = FeasibilityFilter(unionRestrictions: [
            Restriction(kind: .allergy, target: "egg", source: "setup")
        ])
        XCTAssertFalse(filter.isLegal(eggRice))
        XCTAssertTrue(filter.isLegal(vegBowl))

        // Vegetarian diet: recipes without the vegetarian tag are out.
        filter = FeasibilityFilter(unionRestrictions: [
            Restriction(kind: .diet, target: "vegetarian", source: "setup")
        ])
        XCTAssertFalse(filter.isLegal(eggRice))
        XCTAssertTrue(filter.isLegal(vegBowl))

        // Union: an egg allergy plus a second eater's vegetarian diet both bind.
        filter = FeasibilityFilter(unionRestrictions: [
            Restriction(kind: .allergy, target: "egg", source: "setup"),
            Restriction(kind: .diet, target: "vegetarian", source: "setup"),
        ])
        XCTAssertFalse(filter.isLegal(eggRice))
        XCTAssertTrue(filter.isLegal(try XCTUnwrap(catalog.recipes[RecipeID("r_lime_tofu")!])))

        // NeverSuggest beats feasibility even without any other restriction.
        filter = FeasibilityFilter(neverSuggest: [IngredientID("tofu")!])
        XCTAssertFalse(filter.isLegal(vegBowl))

        // Lost capability: recipes baking (or roasting through "Bake") drop out.
        filter = FeasibilityFilter(capabilityNeedles: ["bake"])
        XCTAssertFalse(filter.isLegal(bake))
        XCTAssertTrue(filter.isLegal(vegBowl))
    }

    func testShoppingSkipsRestrictedPlansOnlyThroughTheFilterNotTheWorld()
        throws
    {
        // The world is taste-free: it shops whatever plans it is given, and
        // restriction enforcement lives in the filter. A vegetarian household
        // never sees meat plans because the simulator plans legally.
        let catalog = SimFixtures.catalog()
        var config = SimFixtures.config()
        config.weeklyBudget = 1000
        var world = World(config: config, catalog: catalog)
        world.startWeek(week: 0, shelfLifeWeeks: 2)

        let beef = try XCTUnwrap(catalog.recipes[RecipeID("r_beef_stir")!])
        let record = world.shop(week: 0, plans: [beef])
        XCTAssertEqual(record.boughtRecipeIds, ["r_beef_stir"])
        XCTAssertEqual(world.pantry.grams(of: IngredientID("beef")!), 300)
    }

    func testBudgetShiftPersistsAcrossWeeks() {
        let catalog = SimFixtures.catalog()
        var config = SimFixtures.config()
        config.weeklyBudget = 20
        var world = World(config: config, catalog: catalog)

        world.startWeek(week: 3, shelfLifeWeeks: 2)
        XCTAssertEqual(world.currentBudget, 20)
        world.applyBudgetFactor(0.5)
        XCTAssertEqual(world.currentBudget, 10)
        // A budget change is a life event, not a one-week affair: later
        // weeks keep the reduced budget until another shift changes it.
        world.startWeek(week: 4, shelfLifeWeeks: 2)
        XCTAssertEqual(world.currentBudget, 10)
    }

    private func allRecipes(_ catalog: RecipeCatalog) -> [CatalogRecipe] {
        catalog.recipes.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { catalog.recipes[$0] }
    }
}
