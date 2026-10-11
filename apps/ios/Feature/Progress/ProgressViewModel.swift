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

  /// Owned trend-range presentation state (selection, in-flight load, the
  /// reading shown). Mutated only through the coordinator; the view model
  /// mirrors it for the view.
  private(set) var rangeState: ProgressRangeState = .idle

  /// Provenance-tagged readings backing the cards.
  private(set) var todayReading: ProgressTodayReading?
  private(set) var weeklyReading: ProgressRangeReading?
  private(set) var goalTarget: ProgressGoalTarget?

  private var pendingReload = false

  // MARK: - Dependencies

  private let userDataRepository: UserDataRepository
  private let readModel: ProgressReadModel
  private let rangeCoordinator: ProgressRangeCoordinator
  private var revisionCancellable: AnyDatabaseCancellable?
  private var appleHealthObserver: NSObjectProtocol?

  init(
    userDataRepository: UserDataRepository,
    personalizationService: PersonalizationService,
    appleHealthService: AppleHealthServicing,
    database: AppDatabase
  ) {
    self.userDataRepository = userDataRepository
    let readModel = ProgressReadModel(
      userDataRepository: userDataRepository,
      personalizationService: personalizationService,
      appleHealthService: appleHealthService)
    self.readModel = readModel
    self.rangeCoordinator = .live(readModel: readModel, queue: database.dbQueue)

    rangeCoordinator.onStateChange = { [weak self] state in
      Task { @MainActor in
        self?.rangeState = state
      }
    }

    // Journal and profile revisions (portion edits, date shifts, goal
    // changes) arrive through the revision token — the shared dashboard
    // observer misses those dimensions, so Progress owns this observation.
    startRevisionObservation(queue: database.dbQueue)
    // Apple Health imports bypass the tracked tables; they surface as a
    // notification and trigger an explicit refresh.
    startHealthImportObserver()
  }

  // MARK: - Loading

  /// Full tab load through the read model: provenance-tagged today/weekly
  /// readings, the resolved goal target, recent journal entries, and stats.
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
      let reading = try await readModel.loadReading()
      let hasOnboarded = reading.stats.hasOnboarded
      let profile = hasOnboarded ? try userDataRepository.fetchHealthProfile() : .default

      todayReading = reading.today
      weeklyReading = reading.weekly
      goalTarget = reading.goal
      snapshot = ProgressSnapshot(
        healthProfile: profile,
        todayMacros: reading.today.totals,
        weeklyMacros: Self.macroPoints(from: reading.weekly),
        recentJournal: reading.recentJournal,
        savedWinners: Self.deriveSavedWinners(from: reading.recentJournal),
        totalMealsCooked: reading.stats.totalMealsCooked,
        totalRecipesUsed: reading.stats.totalRecipesUsed,
        currentStreak: reading.stats.currentStreak,
        averageRating: reading.stats.averageRating,
        weekActivity: reading.stats.weekActivity,
        hasOnboarded: hasOnboarded
      )
      errorMessage = nil
    } catch {
      Self.logger.error("Failed to load progress snapshot: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Range Selection

  /// The user picked a trend range; the coordinator cancels any in-flight
  /// read and keeps the last good reading visible while loading.
  func selectRange(_ range: ChartRange) {
    rangeCoordinator.select(range)
  }

  /// Explicit trend refresh (pull-to-refresh, Health import).
  func refreshTrend() {
    rangeCoordinator.refresh()
  }

  // MARK: - Derived Goals

  private var goalProfile: HealthProfile {
    snapshot?.healthProfile ?? .default
  }

  var dailyCalorieGoal: Double {
    goalTarget?.calories
      ?? Double(goalProfile.dailyCalories ?? goalProfile.goal.suggestedCalories)
  }

  var dailyProteinGoalGrams: Double {
    goalTarget?.proteinGrams ?? (dailyCalorieGoal * goalProfile.proteinPct) / 4.0
  }

  var dailyCarbsGoalGrams: Double {
    goalTarget?.carbsGrams ?? (dailyCalorieGoal * goalProfile.carbsPct) / 4.0
  }

  var dailyFatGoalGrams: Double {
    goalTarget?.fatGrams ?? (dailyCalorieGoal * goalProfile.fatPct) / 9.0
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

  /// Weekly insight computed over days with data only — unknown days never
  /// count as 0-calorie days.
  var weeklyInsight: String? {
    guard let weekly = weeklyReading, let avg = weekly.averageCalories else { return nil }
    let daysLogged = weekly.knownDays.count
    let goalDiff = avg - dailyCalorieGoal

    if daysLogged < 3 {
      return "Log a few more meals this week to see your trend."
    } else if abs(goalDiff) < 100 {
      return "Great week! You averaged \(Int(avg.rounded())) cal/day \u{2014} right on target."
    } else if goalDiff > 0 {
      return
        "You averaged \(Int(avg.rounded())) cal/day \u{2014} \(Int(goalDiff.rounded())) over your target."
    } else {
      return
        "You averaged \(Int(avg.rounded())) cal/day \u{2014} \(Int(abs(goalDiff).rounded())) under your target."
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

  /// Known days only — the chart never plots a missing day as zero.
  private static func macroPoints(from reading: ProgressRangeReading) -> [DailyMacroPoint] {
    reading.days.compactMap { point in
      guard let value = point.value else { return nil }
      return DailyMacroPoint(
        date: point.date,
        calories: value.calories,
        protein: value.protein,
        carbs: value.carbs,
        fat: value.fat
      )
    }
  }

  // MARK: - Live Updates

  /// Revision-token observation: fires on journal writes (including portion
  /// edits and date shifts) and on health-profile changes, then reloads the
  /// tab and refreshes the trend range.
  private func startRevisionObservation(queue: DatabaseQueue) {
    let coordinator = rangeCoordinator
    revisionCancellable = ProgressRevisionToken.observation().start(
      in: queue,
      scheduling: .mainActor,
      onError: { error in
        Self.logger.error("Progress revision observation failed: \(error.localizedDescription)")
      },
      onChange: { _ in
        coordinator.refresh()
        Task { @MainActor [weak self] in
          await self?.load()
        }
      }
    )
  }

  private func startHealthImportObserver() {
    appleHealthObserver = NotificationCenter.default.addObserver(
      forName: .appleHealthDidUpdate,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.load()
        self?.refreshTrend()
      }
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
