import FLFeatureLogic
import GRDB
import SwiftUI
import os

// MARK: - View Model

private let logger = Logger(subsystem: "samgu.FridgeLuck", category: "HomeDashboardViewModel")

@MainActor
final class HomeDashboardViewModel: ObservableObject {
  @Published private(set) var snapshot: HomeDashboardSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  private var pendingReload = false

  private let deps: AppDependencies
  private var cookingHistoryObserver: AnyDatabaseCancellable?

  init(deps: AppDependencies) {
    self.deps = deps
    startLiveUpdates()
  }

  func load() async {
    if isLoading {
      pendingReload = true
      return
    }

    isLoading = true
    defer {
      isLoading = false
      if pendingReload {
        pendingReload = false
        Task { await load() }
      }
    }

    do {
      let ingredientCount = try deps.ingredientRepository.count()
      let recipeCount = try deps.recipeRepository.count()
      let hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
      let totalMealsCooked = try deps.userDataRepository.totalMealsCooked()
      let currentStreak = try deps.personalizationService.currentStreak()
      let mealsLast7Days = try deps.userDataRepository.mealsCooked(lastDays: 7)
      let mealsLast14Days = try deps.userDataRepository.mealsByDay(lastDays: 14)
      let weekdayDistribution = try deps.userDataRepository.mealsByWeekday(lastDays: 28)
      let useSoonSuggestions = try deps.spoilageService.useSoonSuggestions(withinDays: 3, limit: 3)

      let profile: HealthProfile? =
        hasOnboarded ? try deps.userDataRepository.fetchHealthProfile() : nil
      let resolvedProfile = profile ?? .default

      let latestEntry = try deps.userDataRepository.cookingJournal(limit: 1).first

      let calGoal = Double(
        resolvedProfile.dailyCalories ?? resolvedProfile.goal.suggestedCalories
      )
      let protPct = resolvedProfile.proteinPct
      let carbPct = resolvedProfile.carbsPct
      let fatPct = resolvedProfile.fatPct

      let proteinGoalGrams = (calGoal * protPct) / 4.0
      let carbsGoalGrams = (calGoal * carbPct) / 4.0
      let fatGoalGrams = (calGoal * fatPct) / 9.0

      let todayMacros = try deps.userDataRepository.todayMacros()

      var primary: HomeRecommendation?
      var fallbacks: [HomeRecommendation] = []
      if hasOnboarded, ingredientCount > 0 {
        let activeItems = try deps.inventoryRepository.fetchAllActiveItems()
        let ingredientIds = Set(activeItems.map(\.ingredientId))
        if !ingredientIds.isEmpty {
          let effectiveIds = RecommendationPolicy.effectiveIngredientIDs(from: ingredientIds)
          let exact = try deps.recipeRepository.findMakeable(
            with: effectiveIds,
            profile: resolvedProfile,
            limit: 5
          )
          let near =
            exact.isEmpty
            ? try deps.recipeRepository.findNearMatch(
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

      snapshot = HomeDashboardSnapshot(
        ingredientCount: ingredientCount,
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
      errorMessage = nil
    } catch {
      logger.error("Failed to load home dashboard: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Live Updates

  private func startLiveUpdates() {
    cookingHistoryObserver = deps.userDataRepository.observeCookingHistoryChanges(
      onError: { error in
        logger.error("Cooking history observer failed: \(error.localizedDescription)")
      },
      onChange: { [weak self] in
        guard let self else { return }
        Task { await self.load() }
      }
    )
  }
}
