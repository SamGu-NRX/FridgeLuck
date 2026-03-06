import Foundation
import GRDB
import Observation

/// ViewModel for the post-onboarding Dashboard.
/// Loads all data needed for macro stats, recipe book preview, and streak display.
@Observable
@MainActor
final class DashboardViewModel {
  // MARK: - Published State

  var snapshot: DashboardSnapshot?
  var isLoading = false
  private var pendingReload = false

  // MARK: - Dependencies

  private let userDataRepository: UserDataRepository
  private let personalizationService: PersonalizationService
  private var cookingHistoryObserver: AnyDatabaseCancellable?

  init(
    userDataRepository: UserDataRepository,
    personalizationService: PersonalizationService
  ) {
    self.userDataRepository = userDataRepository
    self.personalizationService = personalizationService
    startLiveUpdates()
  }

  // MARK: - Loading

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
      let profile = try userDataRepository.fetchHealthProfile()
      let todayMacros = try userDataRepository.todayMacros()
      let weeklyMacros = try userDataRepository.dailyMacroTotals(lastDays: 7)
      let recentJournal = try userDataRepository.cookingJournal(limit: 8)
      let totalMeals = try userDataRepository.totalMealsCooked()
      let totalRecipes = try userDataRepository.totalRecipesUsed()
      let streak = try personalizationService.currentStreak()
      let avgRating = try userDataRepository.averageRating()

      snapshot = DashboardSnapshot(
        healthProfile: profile,
        todayMacros: todayMacros,
        weeklyMacros: weeklyMacros,
        recentJournal: recentJournal,
        totalMealsCooked: totalMeals,
        totalRecipesUsed: totalRecipes,
        currentStreak: streak,
        averageRating: avgRating
      )
    } catch {
      // Non-critical — dashboard will show empty state
    }
  }

  // MARK: - Derived

  var dailyCalorieGoal: Double {
    guard let profile = snapshot?.healthProfile else { return 2000 }
    return Double(profile.dailyCalories ?? profile.goal.suggestedCalories)
  }

  var dailyProteinGoalGrams: Double {
    guard let profile = snapshot?.healthProfile else { return 50 }
    return (dailyCalorieGoal * profile.proteinPct) / 4.0
  }

  var dailyCarbsGoalGrams: Double {
    guard let profile = snapshot?.healthProfile else { return 225 }
    return (dailyCalorieGoal * profile.carbsPct) / 4.0
  }

  var dailyFatGoalGrams: Double {
    guard let profile = snapshot?.healthProfile else { return 67 }
    return (dailyCalorieGoal * profile.fatPct) / 9.0
  }

  var todayCaloriePct: Double {
    guard let snap = snapshot, dailyCalorieGoal > 0 else { return 0 }
    return min(snap.todayMacros.calories / dailyCalorieGoal, 1.0)
  }

  // MARK: - Live Updates

  private func startLiveUpdates() {
    cookingHistoryObserver = userDataRepository.observeCookingHistoryChanges(
      onError: { _ in },
      onChange: { [weak self] in
        guard let self else { return }
        Task { await self.load() }
      }
    )
  }
}
