import SwiftUI

// MARK: - Dashboard Models

struct DailyCookingPoint: Identifiable, Sendable, Equatable {
  let date: Date
  let meals: Int

  var id: Date { date }
}

struct WeekdayCookingPoint: Identifiable, Sendable, Equatable {
  let weekdayIndex: Int  // Monday = 1 ... Sunday = 7
  let weekdayLabel: String
  let meals: Int

  var id: Int { weekdayIndex }
}

struct HomeDashboardSnapshot: Sendable {
  let ingredientCount: Int
  let recipeCount: Int
  let hasOnboarded: Bool
  let currentStreak: Int
  let mealsLast7Days: Int
  let mealsLast14Days: [DailyCookingPoint]
  let weekdayDistribution: [WeekdayCookingPoint]
  let healthProfile: HealthProfile?
  let totalMealsCooked: Int
  let tutorialProgress: TutorialProgress
  let latestJournalEntry: CookingJournalEntry?

  var shouldUseStarterMode: Bool {
    totalMealsCooked < 3
  }
}

struct MacroTargetSlice: Identifiable, Sendable {
  let name: String
  let value: Double
  let color: ColorToken

  enum ColorToken: Sendable {
    case protein
    case carbs
    case fat
  }

  var id: String { name }
}

// MARK: - View Model

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
      let recipeCount = try deps.recipeRepository.count()
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
