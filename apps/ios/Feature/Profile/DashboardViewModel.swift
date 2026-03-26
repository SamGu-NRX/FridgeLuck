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
  private let appleHealthService: AppleHealthServicing
  private var cookingHistoryObserver: AnyDatabaseCancellable?
  private var appleHealthObserver: NSObjectProtocol?

  init(
    userDataRepository: UserDataRepository,
    personalizationService: PersonalizationService,
    appleHealthService: AppleHealthServicing
  ) {
    self.userDataRepository = userDataRepository
    self.personalizationService = personalizationService
    self.appleHealthService = appleHealthService
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
      let recentJournal = try userDataRepository.cookingJournal(limit: 8)
      let totalMeals = try userDataRepository.totalMealsCooked()
      let totalRecipes = try userDataRepository.totalRecipesUsed()
      let streak = try personalizationService.currentStreak()
      let avgRating = try userDataRepository.averageRating()
      let localTodayMacros = try userDataRepository.todayMacros()
      let localWeeklyMacros = try userDataRepository.dailyMacroTotals(lastDays: 7)
      let nutritionSource = await resolvedNutritionSource(
        localTodayMacros: localTodayMacros,
        localWeeklyMacros: localWeeklyMacros
      )

      snapshot = DashboardSnapshot(
        healthProfile: profile,
        todayMacros: nutritionSource.today,
        weeklyMacros: nutritionSource.weekly,
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

    appleHealthObserver = NotificationCenter.default.addObserver(
      forName: .appleHealthDidUpdate,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.load() }
    }
  }

  private func resolvedNutritionSource(
    localTodayMacros: MacroTotals,
    localWeeklyMacros: [DailyMacroPoint]
  ) async -> (today: MacroTotals, weekly: [DailyMacroPoint]) {
    guard appleHealthService.authorizationStatus() == .authorized else {
      return (localTodayMacros, localWeeklyMacros)
    }

    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
      return (localTodayMacros, localWeeklyMacros)
    }

    do {
      async let todayTotals = appleHealthService.fetchNutritionTotals(
        in: DateInterval(start: startOfToday, end: startOfTomorrow)
      )
      async let weeklyTotals = appleHealthService.fetchDailyNutritionTotals(
        lastDays: 7,
        endingOn: Date()
      )

      let resolvedTodayTotals = try await todayTotals
      let resolvedWeeklyTotals = try await weeklyTotals

      guard let resolvedTodayTotals else {
        return (localTodayMacros, localWeeklyMacros)
      }

      let todayMacros = MacroTotals(
        calories: resolvedTodayTotals.calories,
        protein: resolvedTodayTotals.proteinGrams,
        carbs: resolvedTodayTotals.carbsGrams,
        fat: resolvedTodayTotals.fatGrams
      )
      let weeklyMacros = resolvedWeeklyTotals.map {
        DailyMacroPoint(
          date: $0.date,
          calories: $0.totals.calories,
          protein: $0.totals.proteinGrams,
          carbs: $0.totals.carbsGrams,
          fat: $0.totals.fatGrams
        )
      }

      return (todayMacros, weeklyMacros)
    } catch {
      return (localTodayMacros, localWeeklyMacros)
    }
  }
}
