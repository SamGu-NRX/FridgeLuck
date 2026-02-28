import GRDB
import SwiftUI

@MainActor
final class HomeDashboardViewModel: ObservableObject {
  @Published private(set) var snapshot: HomeDashboardSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }

    do {
      let ingredientCount = try deps.ingredientRepository.count()
      let recipeCount = try await deps.appDatabase.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recipes") ?? 0
      }
      let hasOnboarded = try deps.userDataRepository.hasCompletedOnboarding()
      let totalMealsCooked = try deps.userDataRepository.totalMealsCooked()
      let currentStreak = try deps.personalizationService.currentStreak()
      let mealsLast7Days = try deps.userDataRepository.mealsCooked(lastDays: 7)
      let mealsLast14Days = try deps.userDataRepository.mealsByDay(lastDays: 14)
      let weekdayDistribution = try deps.userDataRepository.mealsByWeekday(lastDays: 28)

      let profile: HealthProfile? =
        hasOnboarded ? try deps.userDataRepository.fetchHealthProfile() : nil

      snapshot = HomeDashboardSnapshot(
        ingredientCount: ingredientCount,
        recipeCount: recipeCount,
        hasOnboarded: hasOnboarded,
        currentStreak: currentStreak,
        mealsLast7Days: mealsLast7Days,
        mealsLast14Days: mealsLast14Days,
        weekdayDistribution: weekdayDistribution,
        healthProfile: profile,
        totalMealsCooked: totalMealsCooked
      )
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
