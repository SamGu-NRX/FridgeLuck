import Foundation
import GRDB
import Observation
import os

@Observable
@MainActor
final class ProgressViewModel {
  private static let logger = Logger(subsystem: "samgu.FridgeLuck", category: "ProgressViewModel")

  // MARK: - State

  var snapshot: ProgressSnapshot?
  var isLoading = false
  var errorMessage: String?
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
      let hasOnboarded = try userDataRepository.hasCompletedOnboarding()
      let profile = hasOnboarded ? try userDataRepository.fetchHealthProfile() : .default
      let recentJournal = try userDataRepository.cookingJournal(limit: 12)
      let totalMeals = try userDataRepository.totalMealsCooked()
      let totalRecipes = try userDataRepository.totalRecipesUsed()
      let streak = try personalizationService.currentStreak()
      let avgRating = try userDataRepository.averageRating()
      let weekActivity = try personalizationService.weekActivity()

      let localTodayMacros = try userDataRepository.todayMacros()
      let localWeeklyMacros = try userDataRepository.dailyMacroTotals(lastDays: 7)
      let nutritionSource = await resolvedNutritionSource(
        localTodayMacros: localTodayMacros,
        localWeeklyMacros: localWeeklyMacros
      )

      let savedWinners = Self.deriveSavedWinners(from: recentJournal)

      snapshot = ProgressSnapshot(
        healthProfile: profile,
        todayMacros: nutritionSource.today,
        weeklyMacros: nutritionSource.weekly,
        recentJournal: recentJournal,
        savedWinners: savedWinners,
        totalMealsCooked: totalMeals,
        totalRecipesUsed: totalRecipes,
        currentStreak: streak,
        averageRating: avgRating,
        weekActivity: weekActivity,
        hasOnboarded: hasOnboarded
      )
      errorMessage = nil
    } catch {
      Self.logger.error("Failed to load progress snapshot: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Derived Goals

  private var goalProfile: HealthProfile {
    snapshot?.healthProfile ?? .default
  }

  var dailyCalorieGoal: Double {
    let profile = goalProfile
    return Double(profile.dailyCalories ?? profile.goal.suggestedCalories)
  }

  var dailyProteinGoalGrams: Double {
    let profile = goalProfile
    return (dailyCalorieGoal * profile.proteinPct) / 4.0
  }

  var dailyCarbsGoalGrams: Double {
    let profile = goalProfile
    return (dailyCalorieGoal * profile.carbsPct) / 4.0
  }

  var dailyFatGoalGrams: Double {
    let profile = goalProfile
    return (dailyCalorieGoal * profile.fatPct) / 9.0
  }

  var todayCaloriePct: Double {
    guard let snap = snapshot, dailyCalorieGoal > 0 else { return 0 }
    return min(snap.todayMacros.calories / dailyCalorieGoal, 1.0)
  }

  var caloriesRemaining: Int {
    guard let snap = snapshot else { return 0 }
    return max(Int((dailyCalorieGoal - snap.todayMacros.calories).rounded()), 0)
  }

  var isOverCalories: Bool {
    guard let snap = snapshot else { return false }
    return snap.todayMacros.calories > dailyCalorieGoal
  }

  var weeklyInsight: String? {
    guard let snap = snapshot, !snap.weeklyMacros.isEmpty else { return nil }
    let avg = snap.weeklyMacros.map(\.calories).reduce(0, +) / Double(snap.weeklyMacros.count)
    let goalDiff = avg - dailyCalorieGoal
    let daysLogged = snap.weeklyMacros.count

    if daysLogged < 3 {
      return "Log a few more meals this week to see your trend."
    } else if abs(goalDiff) < 100 {
      return "Great week! You averaged \(Int(avg.rounded())) cal/day \u{2014} right on target."
    } else if goalDiff > 0 {
      return
        "You averaged \(Int(avg.rounded())) cal/day \u{2014} \(Int(goalDiff.rounded())) over your goal."
    } else {
      return
        "You averaged \(Int(avg.rounded())) cal/day \u{2014} \(Int(abs(goalDiff).rounded())) under your goal."
    }
  }

  // MARK: - Saved Winners Derivation

  private static func deriveSavedWinners(from entries: [CookingJournalEntry]) -> [SavedWinner] {
    let grouped = Dictionary(grouping: entries) { $0.recipe.title }

    return grouped.compactMap { title, group in
      let cookCount = group.count
      let maxRating = group.compactMap(\.rating).max() ?? 0
      let isWinner = maxRating >= 4 || cookCount >= 3

      guard isWinner else { return nil }

      let mostRecent = group.max(by: { $0.cookedAt < $1.cookedAt })!
      let imagePath = group.compactMap(\.imagePath).last ?? mostRecent.imagePath

      return SavedWinner(
        id: "\(title)-\(mostRecent.id)",
        recipeName: title,
        rating: maxRating,
        cookCount: cookCount,
        imagePath: imagePath,
        lastCookedAt: mostRecent.cookedAt
      )
    }
    .sorted { $0.lastCookedAt > $1.lastCookedAt }
  }

  // MARK: - Live Updates

  private func startLiveUpdates() {
    cookingHistoryObserver = userDataRepository.observeCookingHistoryChanges(
      onError: { error in
        Self.logger.error("Cooking history observer failed: \(error.localizedDescription)")
      },
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
      Self.logger.error("Falling back to local nutrition totals: \(error.localizedDescription)")
      return (localTodayMacros, localWeeklyMacros)
    }
  }
}

// MARK: - Snapshot

struct ProgressSnapshot: Sendable {
  let healthProfile: HealthProfile
  let todayMacros: MacroTotals
  let weeklyMacros: [DailyMacroPoint]
  let recentJournal: [CookingJournalEntry]
  let savedWinners: [SavedWinner]
  let totalMealsCooked: Int
  let totalRecipesUsed: Int
  let currentStreak: Int
  let averageRating: Double?
  let weekActivity: [Bool]
  let hasOnboarded: Bool
}
