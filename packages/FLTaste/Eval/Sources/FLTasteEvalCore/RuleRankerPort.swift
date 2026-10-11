import Foundation
import FLTaste
import FLTasteSim

/// The current rule ranker, ported faithfully from the app as built on
/// `alpha`, scored over the simulator's feasible candidates.
///
/// Ported sources (branch `alpha`):
/// - `apps/ios/Platform/Persistence/Repository/RecipeScoring.swift`
///   `sharedRankingScore` (lines 44-88): `requiredCoverage * 72.0` (line 61),
///   `matchedOptional * 2.5` (line 59), `healthScore.rating * 6.5` (line 57),
///   `personalScore * 8.0` (line 58), time bonus `<= 15` → +6 / `<= 30` → +3
///   (lines 66-69), goal adjustments (lines 73-80), high-protein bonus +4
///   (line 83), missing-required penalty `* 24.0` (line 87).
/// - `apps/ios/Platform/Persistence/Services/HealthScoringService.swift`
///   `computeScore` (lines 40-68): calorie bands 30/20/15/5 (lines 47-50),
///   macro balance `max(5, 40 * (1 - avgDiff * 3))` (line 62), fiber bonus
///   +10 (line 64), sugar +10 (line 65), sodium +10 (line 66), and
///   `rating = min(5, max(1, ceil(points / 20)))` (line 68).
/// - `apps/ios/Platform/Persistence/Services/NutritionService.swift`:
///   per-serving macros sum `(nutrient_per_100g / 100) * grams / servings`
///   over **required** ingredients only (lines 36, 75).
/// - `apps/ios/Domain/Models/HealthProfile.swift` `default` (lines 71-82):
///   goal `.general`, `dailyCalories` 2000, macro split 0.25/0.45/0.30.
/// - `RecipeMacros.macroSplit` (NutritionService.swift lines 17-28):
///   protein/carbs at 4 kcal/g, fat at 9 kcal/g.
///
/// Seam mapping, documented in the suite README:
/// - Simulator candidates are feasible by construction, so
///   `matchedRequired == totalRequired`, `missingRequiredCount == 0` —
///   exactly the inputs the app sees for an "exact match" row.
/// - `matchedOptional` needs per-optional-ingredient pantry state, which the
///   `Candidate` seam does not expose; the port fixes it at 0 for every
///   candidate. This biases the baseline only (all arms face the same seam).
/// - `personalScore` is the app's injected household taste signal. The rule
///   ranker's defining property is that it carries none, so it is 0.
/// - Households in the simulator declare no health profile; the port uses
///   `HealthProfile.default`.
/// - `sugarPerServing`/`sodiumPerServing` bonuses (HealthScoringService
///   lines 65-66) are omitted: FLTaste's `CatalogIngredient` carries no
///   sugar or sodium fields. Documented deviation, identical for all arms.
enum RuleRankerPort {
    /// `HealthProfile.default` macro targets (HealthProfile.swift lines 71-82).
    static let defaultProteinPct = 0.25
    static let defaultCarbsPct = 0.45
    static let defaultFatPct = 0.30
    static let defaultDailyCalories = 2000.0

    /// Per-serving macros from required ingredients only — the
    /// `NutritionService` formula (alpha lines 36, 75) over Part 1's typed
    /// catalog.
    struct Macros {
        let calories: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let fiber: Double

        /// Numeric fixture init for band tests and synthetic checks.
        init(calories: Double, protein: Double, carbs: Double, fat: Double, fiber: Double) {
            self.calories = calories
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.fiber = fiber
        }

        init(recipe: CatalogRecipe, catalog: RecipeCatalog) {
            // Local names avoid shadowing the stored properties (a local
            // `fat` once left the stored `fat` unassigned).
            var cal = 0.0, pro = 0.0, carb = 0.0, fatg = 0.0, fib = 0.0
            for use in recipe.requiredIngredients {
                guard let ingredient = catalog.ingredients[use.id] else { continue }
                let scale = use.grams / 100.0
                cal += ingredient.caloriesPer100g * scale
                pro += ingredient.proteinPer100g * scale
                carb += ingredient.carbsPer100g * scale
                fatg += ingredient.fatPer100g * scale
                fib += ingredient.fiberPer100g * scale
            }
            let servings = Double(max(1, recipe.servings))
            calories = cal / servings
            protein = pro / servings
            carbs = carb / servings
            fat = fatg / servings
            fiber = fib / servings
        }

        /// 4/4/9 kcal per gram (`RecipeMacros.macroSplit`).
        var macroSplit: (protein: Double, carbs: Double, fat: Double) {
            let proteinCal = protein * 4
            let carbsCal = carbs * 4
            let fatCal = fat * 9
            let total = proteinCal + carbsCal + fatCal
            guard total > 0 else { return (0.33, 0.33, 0.33) }
            return (proteinCal / total, carbsCal / total, fatCal / total)
        }
    }

    /// `HealthScoringService.computeScore` (alpha lines 40-68) against
    /// `HealthProfile.default`, minus the sugar/sodium bonuses.
    static func healthRating(macros: Macros) -> Int {
        var points = 0.0
        // Calorie alignment with the 2000 kcal/day default → meal target
        // 2000/3 (lines 43-53; the default profile sets dailyCalories).
        let mealTarget = defaultDailyCalories / 3.0
        let ratio = macros.calories / mealTarget
        switch ratio {
        case 0.7...1.1: points += 30
        case 0.5..<0.7: points += 20
        case 1.1..<1.4: points += 15
        default: points += 5
        }
        // Macro balance against the default split (lines 55-62).
        let split = macros.macroSplit
        let proteinDiff = abs(split.protein - defaultProteinPct)
        let carbsDiff = abs(split.carbs - defaultCarbsPct)
        let fatDiff = abs(split.fat - defaultFatPct)
        let avgDiff = (proteinDiff + carbsDiff + fatDiff) / 3.0
        points += max(5, 40 * (1.0 - avgDiff * 3.0))
        // Line 64; sugar (65) and sodium (66) are not computable here.
        if macros.fiber >= 5 { points += 10 }
        return min(5, max(1, Int(ceil(points / 20.0))))
    }

    /// `sharedRankingScore` (alpha lines 44-88) with the seam mapping above.
    static func rankingScore(recipe: CatalogRecipe, catalog: RecipeCatalog) -> Double {
        let macros = Macros(recipe: recipe, catalog: catalog)
        let requiredCoverage = 1.0  // feasible candidates: all required present
        let matchedOptional = 0.0   // not visible at the Candidate seam
        let health = Double(healthRating(macros: macros))
        let personalScore = 0.0     // the rule ranker has no taste signal

        var score = requiredCoverage * 72.0 + matchedOptional * 2.5 + health * 6.5
            + personalScore * 8.0
        if recipe.timeMinutes <= 15 {
            score += 6.0
        } else if recipe.timeMinutes <= 30 {
            score += 3.0
        }
        // Goal switch (lines 73-80): `.general` adds nothing.
        if recipe.hasTag(.highProtein) || macros.protein >= 24 {
            score += 4.0
        }
        return score  // missingRequiredCount == 0 → no line-87 penalty
    }
}

/// Stateless arm state for the ported rule ranker. Catalog scores are
/// precomputed once — the catalog is static for the whole campaign.
final class RuleRankerState: ArmState, @unchecked Sendable {
    private let scoreByRecipe: [RecipeID: Double]
    private var scores: [RecipeID: Double] = [:]

    init(catalog: RecipeCatalog) {
        var computed: [RecipeID: Double] = [:]
        for (id, recipe) in catalog.recipes {
            computed[id] = RuleRankerPort.rankingScore(recipe: recipe, catalog: catalog)
        }
        self.scoreByRecipe = computed
    }

    func rank(_ candidates: [Candidate], context: RankingContext) -> [RecipeID] {
        scores = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { candidate in
                scoreByRecipe[candidate.recipe.id].map { (candidate.recipe.id, $0) }
            })
        return ArmOrdering.ordered(candidates) { candidate in
            self.scoreByRecipe[candidate.recipe.id] ?? -Double.infinity
        }
    }

    func lastScores() -> [RecipeID: Double] { scores }
}

/// Factory for the `rule-port` arm. The catalog is bound at construction so
/// no arm reaches for global state.
struct RuleRankerArm: ArmFactory {
    let id = "rule-port"
    let rationale =
        "The current rule ranker as built on alpha, ported faithfully — the bar the activation gate names."
    let family = "baseline"
    let isStateless = true
    private let catalog: RecipeCatalog

    init(catalog: RecipeCatalog) {
        self.catalog = catalog
    }

    func make(events: [TasteEvent], householdSeed: UInt64, armSeed: UInt64) -> any ArmState {
        RuleRankerState(catalog: catalog)
    }
}
