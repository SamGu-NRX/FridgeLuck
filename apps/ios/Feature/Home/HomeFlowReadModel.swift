import Foundation
#if canImport(FLFeatureLogic)
import FLFeatureLogic
#endif

// The Home flow read layer (FL4).
//
// `HomeFlowReadModel` reads the same public repository APIs, in the same order,
// Home's dashboard load has always used, and produces both shapes the flow needs in
// one pass: `HomeFlowInputs` for the state map and `HomeDashboardSnapshot` for the
// existing dashboard sections.
//
// This file is SwiftUI- and Combine-free so the `home-flow-check` package can
// compile and test it on Linux against the real repositories (see
// Tools/home-flow-check). The observable state holder lives in
// HomeFlowViewModel.swift — a thin shell over the pure guard below — and the view
// supplies the one non-repository signal, the Live Assistant coordinator's matched
// recipe context surfaced as a `HomeCookContext` value. The read layer never
// touches the coordinator and never reads tutorial progress.

// MARK: - Read result

/// One pass, one result: the state-map inputs and the presentation snapshot, built
/// from the same reads so the gate and the sections can never disagree.
struct HomeFlowReadResult: Sendable {
  let inputs: HomeFlowInputs
  let snapshot: HomeDashboardSnapshot
}

// MARK: - Reader contract

/// The load source the view model consumes. `HomeFlowReadModel` is the real
/// implementation; tests supply a stub to interleave loads deterministically.
@MainActor
protocol HomeFlowReading {
  func load() async throws -> HomeFlowReadResult
}

// MARK: - Generation guard

/// The staleness guard for asynchronous loads: each request takes a generation
/// number, and a completed load applies only if its generation is still current.
///
/// Extracted as a pure value so the guard is testable on Linux; the view model uses
/// exactly this type. The failure it prevents: a slow first load (triggered before
/// the repositories had data) resolving after a fast second load and clobbering the
/// newer result with older inputs.
struct HomeLoadGeneration: Sendable, Equatable {
  private var current = 0

  /// Starts a load and returns the generation it must check itself against.
  mutating func begin() -> Int {
    current += 1
    return current
  }

  /// True only for the most recently begun load.
  func isCurrent(_ generation: Int) -> Bool {
    generation == current
  }
}

// MARK: - Read model

/// Reads the public repository outputs the Home flow consumes, in one pass.
///
/// Narrow dependency injection at the boundary (the established ProgressViewModel
/// pattern): repositories are passed in, so no `AppDependencies` change is needed and
/// the whole layer compiles on Linux in the check package. Recommendation assembly
/// reuses the existing policy chain — `RecommendationPolicy.effectiveIngredientIDs(from:)`
/// → `findMakeable` → `findNearMatch` — exactly as the dashboard did.
@MainActor
struct HomeFlowReadModel: HomeFlowReading {
  let inventory: InventoryRepository
  let userData: UserDataRepository
  let personalization: PersonalizationService
  let spoilage: SpoilageService
  let recipes: RecipeRepository
  let ingredients: IngredientRepository

  init(
    inventory: InventoryRepository,
    userData: UserDataRepository,
    personalization: PersonalizationService,
    spoilage: SpoilageService,
    recipes: RecipeRepository,
    ingredients: IngredientRepository
  ) {
    self.inventory = inventory
    self.userData = userData
    self.personalization = personalization
    self.spoilage = spoilage
    self.recipes = recipes
    self.ingredients = ingredients
  }

  /// The single load pass. Synchronous repository reads, MainActor-bound, identical
  /// in behavior to the load this layer succeeded.
  func load() async throws -> HomeFlowReadResult {
    // `ingredients` stays injected for the composition work pending the canonical
    // FLIngredientFacts package; the catalog count no longer feeds this pass.
    let recipeCount = try recipes.count()
    let hasOnboarded = try userData.hasCompletedOnboarding()
    let totalMealsCooked = try userData.totalMealsCooked()
    let currentStreak = try personalization.currentStreak()
    let mealsLast7Days = try userData.mealsCooked(lastDays: 7)
    let mealsLast14Days = try userData.mealsByDay(lastDays: 14)
    let weekdayDistribution = try userData.mealsByWeekday(lastDays: 28)
    let useSoonSuggestions = try spoilage.useSoonSuggestions(withinDays: 3, limit: 3)

    let profile: HealthProfile? =
      hasOnboarded ? try userData.fetchHealthProfile() : nil
    let resolvedProfile = profile ?? .default

    let latestEntry = try userData.cookingJournal(limit: 1).first

    let calGoal = Double(
      resolvedProfile.dailyCalories ?? resolvedProfile.goal.suggestedCalories
    )
    let protPct = resolvedProfile.proteinPct
    let carbPct = resolvedProfile.carbsPct
    let fatPct = resolvedProfile.fatPct

    let proteinGoalGrams = (calGoal * protPct) / 4.0
    let carbsGoalGrams = (calGoal * carbPct) / 4.0
    let fatGoalGrams = (calGoal * fatPct) / 9.0

    let todayMacros = try userData.todayMacros()

    // Fetched once for both the recommendation assembly and the state-map inputs.
    // Stock evidence comes from inventory lots, never the recipe catalog: fetch
    // active items whenever onboarding is complete, regardless of catalog size. A
    // populated catalog with an empty pantry must stay an empty-new kitchen.
    let activeItems: [InventoryActiveItem] =
      hasOnboarded
      ? try inventory.fetchAllActiveItems()
      : []
    // Quantity evidence: distinct ingredients with remaining grams > 0. This — not
    // IngredientRepository.count() — is what Home treats as "stocked".
    let stockedIngredientCount = Set(
      activeItems
        .filter { $0.totalRemainingGrams > 0 }
        .map(\.ingredientId)
    ).count

    var primary: HomeRecommendation?
    var fallbacks: [HomeRecommendation] = []
    if hasOnboarded, stockedIngredientCount > 0 {
      let ingredientIds = Set(activeItems.map(\.ingredientId))
      if !ingredientIds.isEmpty {
        let effectiveIds = RecommendationPolicy.effectiveIngredientIDs(from: ingredientIds)
        let exact = try recipes.findMakeable(
          with: effectiveIds,
          profile: resolvedProfile,
          limit: 5
        )
        let near =
          exact.isEmpty
          ? try recipes.findNearMatch(
            with: effectiveIds,
            profile: resolvedProfile,
            maxMissingRequired: 1,
            limit: 5
          )
          : []

        let all = exact + near
        if let top = all.first {
          primary = HomeRecommendation(
            recipeID: top.recipe.id,
            recipeName: top.recipe.title,
            explanation: top.rankingReasons.prefix(3).joined(separator: ". ") + ".",
            cookTimeMinutes: top.recipe.timeMinutes,
            matchLabel: top.matchTier == RecipeMatchTier.exact ? "Perfect match" : "Almost there",
            badgeLabel: top.matchTier == RecipeMatchTier.exact ? "Perfect match" : nil,
            ingredientIDs: ingredientIds
          )
        }
        fallbacks = Array(all.dropFirst().prefix(3)).map { scored in
          HomeRecommendation(
            recipeID: scored.recipe.id,
            recipeName: scored.recipe.title,
            explanation: scored.rankingReasons.prefix(2).joined(separator: ". "),
            cookTimeMinutes: scored.recipe.timeMinutes,
            matchLabel: nil,
            badgeLabel: scored.rankingReasons.first,
            ingredientIDs: ingredientIds
          )
        }
      }
    }

    let snapshot = HomeDashboardSnapshot(
      stockedIngredientCount: stockedIngredientCount,
      recipeCount: recipeCount,
      hasOnboarded: hasOnboarded,
      currentStreak: currentStreak,
      mealsLast7Days: mealsLast7Days,
      mealsLast14Days: mealsLast14Days,
      weekdayDistribution: weekdayDistribution,
      healthProfile: profile,
      totalMealsCooked: totalMealsCooked,
      latestJournalEntry: latestEntry,
      useSoonSuggestions: useSoonSuggestions,
      todayCalories: todayMacros.calories,
      todayProtein: todayMacros.protein,
      todayCarbs: todayMacros.carbs,
      todayFat: todayMacros.fat,
      calorieGoal: calGoal,
      proteinGoal: proteinGoalGrams,
      carbsGoal: carbsGoalGrams,
      fatGoal: fatGoalGrams,
      primaryRecommendation: primary,
      fallbackOptions: fallbacks
    )

    let inputs = HomeFlowInputs(
      hasCompletedOnboarding: hasOnboarded,
      inventoryItems: activeItems,
      useSoon: useSoonSuggestions,
      totalMealsCooked: totalMealsCooked,
      mealsCookedLast7Days: mealsLast7Days,
      latestJournalEntry: latestEntry,
      todayMacros: todayMacros,
      currentStreak: currentStreak,
      weekActivity: try personalization.weekActivity(),
      healthProfile: profile,
      primaryRecommendation: primary,
      fallbackOptions: fallbacks
    )

    return HomeFlowReadResult(inputs: inputs, snapshot: snapshot)
  }
}
