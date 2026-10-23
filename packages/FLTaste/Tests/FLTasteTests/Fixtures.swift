import Foundation
@testable import FLTaste

/// Deterministic fixtures: a small hand-computable catalog and event
/// builders with fixed UTC timestamps. Never uses wall-clock time.
enum Fixtures {
    /// 2026-01-01T00:00:00Z in epoch milliseconds.
    static let baseMillis: Int64 = 1_767_225_600_000

    static func instant(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Instant {
        let millis = baseMillis + Int64(day) * 86_400_000
            + Int64(hour) * 3_600_000 + Int64(minute) * 60_000
        return Instant(millisecondsSinceEpoch: millis)!
    }

    static func ingredient(_ id: String, cal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double) -> CatalogIngredient {
        CatalogIngredient(
            id: IngredientID(id)!, name: id.replacingOccurrences(of: "_", with: " "),
            caloriesPer100g: cal, proteinPer100g: protein, carbsPer100g: carbs,
            fatPer100g: fat, fiberPer100g: fiber)
    }

    /// Small deterministic catalog: 13 ingredients, 6 recipes.
    static func catalog() -> RecipeCatalog {
        let ingredients = [
            ingredient("lime", cal: 30, protein: 0.7, carbs: 10.5, fat: 0.2, fiber: 2.8),
            ingredient("red_pepper_flakes", cal: 282, protein: 13, carbs: 50, fat: 3, fiber: 12),
            ingredient("ginger", cal: 80, protein: 1.8, carbs: 18, fat: 0.8, fiber: 2),
            ingredient("cumin", cal: 375, protein: 18, carbs: 44, fat: 22, fiber: 12.5),
            ingredient("cilantro", cal: 23, protein: 2.1, carbs: 3.0, fat: 0.7, fiber: 2.7),
            ingredient("peanut_butter", cal: 588, protein: 25, carbs: 20, fat: 50, fiber: 6),
            ingredient("peanuts", cal: 567, protein: 26, carbs: 16, fat: 49, fiber: 8.5),
            ingredient("chicken", cal: 165, protein: 31, carbs: 0, fat: 3.6, fiber: 0),
            ingredient("rice", cal: 130, protein: 2.7, carbs: 28, fat: 0.3, fiber: 0.4),
            ingredient("chili", cal: 40, protein: 1.9, carbs: 9, fat: 0.4, fiber: 1.5),
            ingredient("noodles", cal: 138, protein: 4.5, carbs: 25, fat: 1.2, fiber: 1.7),
            ingredient("tofu", cal: 76, protein: 8, carbs: 1.9, fat: 4.8, fiber: 0.3),
            ingredient("coconut_milk", cal: 197, protein: 2, carbs: 3, fat: 21, fiber: 0),
        ]
        func recipe(
            _ id: String, _ title: String, time: Int, servings: Int,
            required: [(String, Double)], optional: [(String, Double)] = [],
            tags: [CatalogTag], instructions: String
        ) -> CatalogRecipe {
            CatalogRecipe(
                id: RecipeID(id)!, title: title, timeMinutes: time, servings: servings,
                requiredIngredients: required.map { CatalogRecipe.IngredientUse(id: IngredientID($0.0)!, grams: $0.1) },
                optionalIngredients: optional.map { CatalogRecipe.IngredientUse(id: IngredientID($0.0)!, grams: $0.1) },
                instructions: instructions,
                tagBitmask: tags.reduce(0) { $0 | $1.bit })
        }
        let recipes = [
            recipe(
                "r_peanut_noodles", "Peanut noodles", time: 20, servings: 2,
                required: [("noodles", 200), ("peanut_butter", 60), ("chili", 10)],
                optional: [("lime", 30)], tags: [.asian, .quick, .budget],
                instructions: "Boil the noodles. Toss with the peanut sauce."),
            recipe(
                "r_cilantro_chicken", "Cilantro chicken", time: 40, servings: 2,
                required: [("chicken", 300), ("cilantro", 20), ("lime", 40)],
                tags: [.mediterranean, .highProtein],
                instructions: "Grill the chicken. Chop the cilantro."),
            recipe(
                "r_rice_bowl", "Rice bowl", time: 30, servings: 2,
                required: [("rice", 200), ("tofu", 150), ("coconut_milk", 200)],
                optional: [("ginger", 10)], tags: [.asian, .vegan, .budget],
                instructions: "Simmer the coconut milk. Add the tofu and rice."),
            recipe(
                "r_chili_rice", "Chili rice", time: 25, servings: 4,
                required: [("rice", 300), ("chili", 20)],
                optional: [("red_pepper_flakes", 2)], tags: [.mexican, .asian, .quick],
                instructions: "Fry the chili. Add the rice."),
            recipe(
                "r_tofu_salad", "Tofu salad", time: 15, servings: 1,
                required: [("tofu", 120), ("lime", 20)],
                optional: [("cilantro", 5)], tags: [.vegetarian, .vegetarian, .quick],
                instructions: "Toss the tofu and lime. No cook."),
            recipe(
                "r_baked_rice", "Baked rice", time: 90, servings: 4,
                required: [("rice", 300), ("chicken", 400)],
                tags: [.comfort, .onePot],
                instructions: "Bake the rice and chicken in the oven."),
        ]
        return RecipeCatalog(ingredients: ingredients, recipes: recipes)
    }

    static func engine(config: TasteConfig = .standard) -> TasteEngine {
        TasteEngine(catalog: catalog(), config: config)
    }

    // MARK: Event builders

    static func cooked(
        _ id: String, _ recipe: String, at: Instant, rating: Rating? = nil,
        wouldMakeAgain: Bool? = nil, eater: String? = nil,
        feasible: Int = 6, shown: Int? = nil
    ) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at,
            eater: eater.map { EaterID($0)! },
            exposure: try! ExposureContext(feasibleCandidates: feasible, shownCandidates: shown),
            kind: .cooked(recipe: RecipeID(recipe)!, rating: rating, wouldMakeAgain: wouldMakeAgain))
    }

    static func skipped(_ id: String, _ recipe: String, at: Instant, reason: SkipReason, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .skipped(recipe: RecipeID(recipe)!, reason: reason))
    }

    static func viewed(_ id: String, _ recipe: String, at: Instant, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .viewed(recipe: RecipeID(recipe)!))
    }

    static func saved(_ id: String, _ recipe: String, at: Instant, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .saved(recipe: RecipeID(recipe)!))
    }

    static func opened(_ id: String, _ recipe: String, at: Instant, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .opened(recipe: RecipeID(recipe)!))
    }

    static func substituted(
        _ id: String, _ recipe: String, from: String, to: String?, mode: SubstitutionMode?,
        at: Instant, eater: String? = nil
    ) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .substituted(
                recipe: RecipeID(recipe)!, from: IngredientID(from)!,
                to: to.map { IngredientID($0)! }, mode: mode))
    }

    static func editedServings(_ id: String, _ recipe: String, from: Int, to: Int, at: Instant, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .editedServings(recipe: RecipeID(recipe)!, from: from, to: to))
    }

    static func leChef(_ id: String, _ recipe: String, type: LeChefFeedback.FeedbackType, note: String? = nil, at: Instant, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .leChefFeedback(recipe: RecipeID(recipe)!, feedback: LeChefFeedback(type: type, note: note)))
    }

    static func profileEdit(_ id: String, _ op: ProfileEditOp, at: Instant, eater: String? = nil) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: eater.map { EaterID($0)! }, exposure: nil,
            kind: .profileEdit(op))
    }

    static func correction(_ id: String, amends: String, _ resolution: CorrectionResolution, at: Instant) -> TasteEvent {
        TasteEvent(
            id: EventID(id)!, at: at, eater: nil, exposure: nil,
            kind: .correction(amends: EventID(amends)!, resolution: resolution))
    }

    /// A scenario with enough behavioral events to learn from: eater "sam"
    /// cooks spicy Asian food repeatedly, skips cilantro salads, and states a
    /// preference. Eater "lena" cooks once.
    static func scenarioEvents() -> [TasteEvent] {
        var events: [TasteEvent] = [
            profileEdit(
                "p1", .setRestriction(
                    Restriction(kind: .allergy, target: "peanut_butter", source: "setup")),
                at: instant(0)),
            profileEdit(
                "p2", .setPreference(feature: FeatureKey(namespace: "cuisine", value: "asian"), polarity: .like),
                at: instant(0)),
            profileEdit(
                "p3", .setNeverSuggest(ingredient: IngredientID("peanuts")!), at: instant(0)),
            viewed("v1", "r_rice_bowl", at: instant(1, 8), eater: "sam"),
            opened("o1", "r_rice_bowl", at: instant(1, 8, 5), eater: "sam"),
            cooked("c1", "r_rice_bowl", at: instant(1, 19), rating: Rating(5), wouldMakeAgain: true, eater: "sam", feasible: 6, shown: 6),
            viewed("v2", "r_chili_rice", at: instant(2, 9), eater: "sam"),
            cooked("c2", "r_chili_rice", at: instant(2, 19), rating: Rating(4), wouldMakeAgain: true, eater: "sam", feasible: 3, shown: 2),
            viewed("v3", "r_tofu_salad", at: instant(3, 9), eater: "sam"),
            skipped("s1", "r_tofu_salad", at: instant(3, 9, 10), reason: .outOfTime, eater: "sam"),
            cooked("c3", "r_baked_rice", at: instant(4, 19), rating: Rating(2), wouldMakeAgain: false, eater: "sam", feasible: 6, shown: 1),
            cooked("c4", "r_peanut_noodles", at: instant(5, 19), rating: Rating(4), eater: "sam", feasible: 6, shown: 6),
            leChef("l1", "r_chili_rice", type: .tooSpicy, at: instant(6), eater: "sam"),
            cooked("c5", "r_rice_bowl", at: instant(7, 19), rating: Rating(5), wouldMakeAgain: true, eater: "sam", feasible: 6, shown: 3),
            cooked("c6", "r_cilantro_chicken", at: instant(8, 19), rating: Rating(3), eater: "lena"),
        ]
        events.append(
            correction("x1", amends: "c6", .reattribute(to: EaterID("sam")!), at: instant(9)))
        return events
    }
}
