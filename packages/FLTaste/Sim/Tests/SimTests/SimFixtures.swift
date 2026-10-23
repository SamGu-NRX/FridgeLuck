import Foundation
@testable import FLTasteSim
import FLTaste

/// Deterministic fixtures for simulator tests: a small hand-built catalog
/// (15 ingredients, 14 recipes) with enough variety to exercise
/// restrictions, tags, spice, and the bake capability needle. Never uses
/// wall-clock time.
enum SimFixtures {

    static let baseMillis: Int64 = 1_767_225_600_000  // 2026-01-01T00:00:00Z

    static func config(
        seed: UInt64 = 7, weeks: Int = 4, householdSize: Int = 2, shifts: [ShiftSpec] = []
    ) -> SimConfig {
        var config = SimConfig()
        config.seed = seed
        config.weeks = weeks
        config.householdSize = householdSize
        config.shifts = shifts
        config.slateSize = 6
        return config
    }

    static func ingredient(
        _ id: String, cal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double
    ) -> CatalogIngredient {
        CatalogIngredient(
            id: IngredientID(id)!, name: id.replacingOccurrences(of: "_", with: " "),
            caloriesPer100g: cal, proteinPer100g: protein, carbsPer100g: carbs, fatPer100g: fat,
            fiberPer100g: fiber)
    }

    /// Small deterministic catalog.
    static func catalog() -> RecipeCatalog {
        let ingredients = [
            ingredient("chicken", cal: 165, protein: 31, carbs: 0, fat: 3.6, fiber: 0),
            ingredient("beef", cal: 250, protein: 26, carbs: 0, fat: 15, fiber: 0),
            ingredient("rice", cal: 130, protein: 2.7, carbs: 28, fat: 0.3, fiber: 0.4),
            ingredient("noodles", cal: 138, protein: 4.5, carbs: 25, fat: 1.2, fiber: 1.7),
            ingredient("tofu", cal: 76, protein: 8, carbs: 1.9, fat: 4.8, fiber: 0.3),
            ingredient("coconut_milk", cal: 197, protein: 2, carbs: 3, fat: 21, fiber: 0),
            ingredient("peanut_butter", cal: 588, protein: 25, carbs: 20, fat: 50, fiber: 6),
            ingredient("chili", cal: 40, protein: 1.9, carbs: 9, fat: 0.4, fiber: 1.5),
            ingredient("lime", cal: 30, protein: 0.7, carbs: 10.5, fat: 0.2, fiber: 2.8),
            ingredient("cilantro", cal: 23, protein: 2.1, carbs: 3.0, fat: 0.7, fiber: 2.7),
            ingredient("egg", cal: 155, protein: 13, carbs: 1.1, fat: 11, fiber: 0),
            ingredient("cheese", cal: 402, protein: 25, carbs: 1.3, fat: 33, fiber: 0),
            ingredient("tomato", cal: 18, protein: 0.9, carbs: 3.9, fat: 0.2, fiber: 1.2),
            ingredient("onion", cal: 40, protein: 1.1, carbs: 9.3, fat: 0.1, fiber: 1.7),
            ingredient("ginger", cal: 80, protein: 1.8, carbs: 18, fat: 0.8, fiber: 2),
        ]
        func recipe(
            _ id: String, _ title: String, time: Int, servings: Int,
            required: [(String, Double)], optional: [(String, Double)] = [],
            tags: [CatalogTag], instructions: String
        ) -> CatalogRecipe {
            CatalogRecipe(
                id: RecipeID(id)!, title: title, timeMinutes: time, servings: servings,
                requiredIngredients: required.map {
                    CatalogRecipe.IngredientUse(id: IngredientID($0.0)!, grams: $0.1)
                },
                optionalIngredients: optional.map {
                    CatalogRecipe.IngredientUse(id: IngredientID($0.0)!, grams: $0.1)
                },
                instructions: instructions,
                tagBitmask: tags.reduce(0) { $0 | $1.bit })
        }
        let recipes = [
            recipe(
                "r_chicken_rice", "Chicken rice", time: 25, servings: 2,
                required: [("chicken", 300), ("rice", 200)], optional: [("lime", 20)],
                tags: [.mexican, .quick, .highProtein], instructions: "Fry the chicken. Add the rice."),
            recipe(
                "r_beef_chili_bake", "Beef chili bake", time: 70, servings: 4,
                required: [("beef", 400), ("chili", 20), ("tomato", 150)],
                tags: [.mexican, .comfort], instructions: "Bake the beef with chili and tomato."),
            recipe(
                "r_veg_bowl", "Vegan rice bowl", time: 30, servings: 2,
                required: [("rice", 200), ("tofu", 150), ("coconut_milk", 200)],
                optional: [("ginger", 10)],
                tags: [.asian, .vegetarian, .vegan, .budget],
                instructions: "Simmer the coconut milk. Add the tofu and rice."),
            recipe(
                "r_peanut_noodles", "Peanut noodles", time: 20, servings: 2,
                required: [("noodles", 200), ("peanut_butter", 60), ("chili", 10)],
                optional: [("lime", 30)],
                tags: [.asian, .vegetarian, .quick, .budget],
                instructions: "Boil the noodles. Toss with the peanut sauce."),
            recipe(
                "r_egg_rice", "Egg fried rice", time: 15, servings: 2,
                required: [("rice", 200), ("egg", 100), ("onion", 50)],
                tags: [.asian, .quick],
                instructions: "Fry the rice. Scramble the egg."),
            recipe(
                "r_tofu_salad", "Tofu salad", time: 15, servings: 1,
                required: [("tofu", 120), ("lime", 20)], optional: [("cilantro", 5)],
                tags: [.vegetarian, .vegan, .quick],
                instructions: "Toss the tofu and lime. No cook."),
            recipe(
                "r_chicken_bake", "Chicken cheese bake", time: 60, servings: 4,
                required: [("chicken", 400), ("cheese", 100), ("tomato", 100)],
                tags: [.mediterranean, .comfort],
                instructions: "Bake the chicken with cheese and tomato."),
            recipe(
                "r_chili_rice", "Chili rice", time: 25, servings: 4,
                required: [("rice", 300), ("chili", 20)], optional: [("onion", 30)],
                tags: [.mexican, .asian, .quick],
                instructions: "Fry the chili. Add the rice."),
            recipe(
                "r_noodle_soup", "Coconut noodle soup", time: 30, servings: 2,
                required: [("noodles", 200), ("coconut_milk", 200), ("ginger", 10)],
                tags: [.asian, .vegetarian],
                instructions: "Simmer the noodles in coconut milk."),
            recipe(
                "r_cheese_rice", "Cheese rice", time: 35, servings: 2,
                required: [("rice", 250), ("cheese", 80)],
                tags: [.vegetarian, .comfort, .budget],
                instructions: "Simmer the rice. Stir in the cheese."),
            recipe(
                "r_beef_stir", "Beef stir-fry", time: 20, servings: 2,
                required: [("beef", 300), ("chili", 15), ("onion", 60)],
                tags: [.mexican, .quick, .highProtein],
                instructions: "Stir-fry the beef with chili."),
            recipe(
                "r_coconut_chicken", "Coconut chicken", time: 40, servings: 3,
                required: [("chicken", 350), ("coconut_milk", 200), ("lime", 30)],
                tags: [.asian],
                instructions: "Simmer the chicken in coconut milk."),
            recipe(
                "r_lime_tofu", "Lime chili tofu", time: 15, servings: 2,
                required: [("tofu", 150), ("lime", 25), ("chili", 10)],
                tags: [.vegetarian, .vegan, .quick],
                instructions: "Fry the tofu. Add lime and chili."),
            recipe(
                "r_big_roast", "Sunday roast", time: 90, servings: 4,
                required: [("beef", 500), ("onion", 80), ("tomato", 100), ("cheese", 60)],
                tags: [.comfort],
                instructions: "Roast the beef. Bake the tomato on the side."),
        ]
        return RecipeCatalog(ingredients: ingredients, recipes: recipes)
    }

    /// A tiny `data.json` document in the app's positional schema, for loader
    /// tests. Mirrors the real file's shape: ingredients keyed by integer
    /// string, positional arrays, 12-name tag list.
    static func miniDataJSON() -> String {
        """
        {
          "ingredients": {
            "1": ["egg", 155, 13.0, 1.1, 11.0, 0.0, 1.1, 0.124, "1 large (50g)", "Refrigerate"],
            "2": ["rice", 130, 2.7, 28.0, 0.3, 0.4, 0.05, 0.001, "1 cup (195g)", "Dry"],
            "3": ["chicken", 165, 31.0, 0.0, 3.6, 0.0, 0.0, 0.082, "1 breast (174g)", "Refrigerate"]
          },
          "recipes": [
            [1, "Egg rice", 15, 2, [[1, 100], [2, 200]], [[3, 20]], "1. Fry the rice.\\n2. Scramble the egg.", 9],
            [2, "Chicken rice", 25, 2, [[3, 300], [2, 200]], [], "1. Fry the chicken. Add the rice.", 264]
          ],
          "tags": ["quick", "vegetarian", "vegan", "asian", "breakfast", "budget", "comfort", "mediterranean", "mexican", "highProtein", "lowCarb", "onePot"]
        }
        """
    }

    /// Locates the repo checkout's real catalog by walking up from this
    /// source file. Returns nil outside a repo checkout, so the test skips
    /// instead of failing.
    static func repoDataJSONPath() -> String? {
        #if swift(>=5.9)
        let file = #filePath
        #else
        let file = #file
        #endif
        var url = URL(fileURLWithPath: file)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("apps/ios/Resources/data.json").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
