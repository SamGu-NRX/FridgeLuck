import GRDB
import SwiftUI

@MainActor
final class HomeDashboardViewModel: ObservableObject {
  @Published private(set) var snapshot: HomeDashboardSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  /// Tutorial progress, stored via @AppStorage in the view layer and synced here.
  @Published var tutorialProgress: TutorialProgress = .empty

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

      let latestEntry = try deps.userDataRepository.cookingJournal(limit: 1).first

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
        tutorialProgress: tutorialProgress,
        latestJournalEntry: latestEntry
      )
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Mark a quest completed and refresh the snapshot.
  func completeQuest(_ quest: TutorialQuest) {
    tutorialProgress.markCompleted(quest)
    if var snap = snapshot {
      snap = HomeDashboardSnapshot(
        ingredientCount: snap.ingredientCount,
        recipeCount: snap.recipeCount,
        hasOnboarded: snap.hasOnboarded,
        currentStreak: snap.currentStreak,
        mealsLast7Days: snap.mealsLast7Days,
        mealsLast14Days: snap.mealsLast14Days,
        weekdayDistribution: snap.weekdayDistribution,
        healthProfile: snap.healthProfile,
        totalMealsCooked: snap.totalMealsCooked,
        tutorialProgress: tutorialProgress,
        latestJournalEntry: snap.latestJournalEntry
      )
      snapshot = snap
    }
  }

  /// Sync tutorial progress from external @AppStorage value.
  func syncTutorialProgress(_ progress: TutorialProgress) {
    tutorialProgress = progress
  }
}
