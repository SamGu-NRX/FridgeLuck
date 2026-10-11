import Foundation
import GRDB

// MARK: - Provenance

/// Where a nutrition reading came from. A reading is never a blend of
/// sources: every number Progress displays carries exactly one source label,
/// so a source switch is always visible.
enum ProgressNutritionSource: String, Equatable, Sendable, CaseIterable {
  /// Aggregates computed by the app's local journal (frozen meal snapshots).
  case localJournal
  /// Aggregates read from Apple Health (HealthKit) totals.
  case appleHealth

  var displayName: String {
    switch self {
    case .localJournal: "Local journal"
    case .appleHealth: "Apple Health"
    }
  }

  var sourceNote: String {
    switch self {
    case .localJournal:
      return "From meals logged in the app. Each meal keeps the nutrition it was logged with."
    case .appleHealth:
      return "From Apple Health nutrition totals on this device."
    }
  }
}

/// Whether the displayed calorie target is the user's own confirmed value or
/// a suggested default derived from the selected goal. A default must never
/// present as user-set.
enum ProgressGoalProvenance: Equatable, Sendable {
  /// The profile row stores a saved calorie target (set through onboarding
  /// or the profile editor).
  case confirmedPersonalTarget
  /// No saved target: the value is the suggestion that ships with the chosen
  /// goal, or the app default while no profile exists yet.
  case suggestedTarget

  var label: String {
    switch self {
    case .confirmedPersonalTarget: "Your target"
    case .suggestedTarget: "Suggested target"
    }
  }
}

/// The daily calorie/macro target Progress displays, with its provenance.
/// Relocates the same macro-split arithmetic the Progress view model has
/// always used (calories x pct / 4 or / 9); no new nutrition math.
struct ProgressGoalTarget: Equatable, Sendable {
  let calories: Double
  let proteinGrams: Double
  let carbsGrams: Double
  let fatGrams: Double
  let provenance: ProgressGoalProvenance
  let goalName: String

  static func resolve(profile: HealthProfile, hasOnboarded: Bool) -> ProgressGoalTarget {
    let calories: Double
    let provenance: ProgressGoalProvenance

    if hasOnboarded, let saved = profile.dailyCalories {
      calories = Double(saved)
      provenance = .confirmedPersonalTarget
    } else {
      calories = Double(profile.dailyCalories ?? profile.goal.suggestedCalories)
      provenance = .suggestedTarget
    }

    return ProgressGoalTarget(
      calories: calories,
      proteinGrams: (calories * profile.proteinPct) / 4.0,
      carbsGrams: (calories * profile.carbsPct) / 4.0,
      fatGrams: (calories * profile.fatPct) / 9.0,
      provenance: provenance,
      goalName: profile.goal.displayName
    )
  }
}

// MARK: - Day points and readings

/// One calendar day in a range. `value == nil` means no data was recorded
/// for that day — Progress renders "no data", never a 0-calorie bar.
struct ProgressDayPoint: Identifiable, Equatable, Sendable {
  let date: Date
  let source: ProgressNutritionSource
  let value: MacroTotals?

  var isKnown: Bool { value != nil }
  var id: Date { date }

  // MacroTotals is a production type without Equatable; compare by fields.
  static func == (lhs: ProgressDayPoint, rhs: ProgressDayPoint) -> Bool {
    guard lhs.date == rhs.date, lhs.source == rhs.source else { return false }
    switch (lhs.value, rhs.value) {
    case (nil, nil): return true
    case (let l?, let r?):
      return l.calories == r.calories && l.protein == r.protein
        && l.carbs == r.carbs && l.fat == r.fat
    default: return false
    }
  }
}

/// The per-day result for one trend range. Fully one source; unknown days
/// are preserved as nil rather than zero-filled.
struct ProgressRangeReading: Equatable, Sendable {
  let lastDays: Int
  let source: ProgressNutritionSource
  let days: [ProgressDayPoint]
  /// Set when the requested source failed and the journal was used instead,
  /// so the UI can surface the fallback instead of hiding it.
  let fallbackReason: String?

  init(
    lastDays: Int,
    source: ProgressNutritionSource,
    days: [ProgressDayPoint],
    fallbackReason: String? = nil
  ) {
    self.lastDays = lastDays
    self.source = source
    self.days = days
    self.fallbackReason = fallbackReason
  }

  var knownDays: [ProgressDayPoint] { days.filter(\.isKnown) }
  var unknownDayCount: Int { days.count - knownDays.count }

  /// Aggregate policy: averages cover days with data only. A day with no
  /// entries never counts as a 0-calorie day. nil when no day has data.
  var averageCalories: Double? {
    let values = knownDays.compactMap { $0.value?.calories }
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  /// e.g. "5 of 7 days with data" for subtitles and notes.
  var coverageSummary: String { "\(knownDays.count) of \(days.count) days with data" }
}

/// Today's reading, source-tagged.
struct ProgressTodayReading: Equatable, Sendable {
  let source: ProgressNutritionSource
  let totals: MacroTotals
  /// Set when the requested source failed and the journal was used instead.
  let fallbackReason: String?

  init(source: ProgressNutritionSource, totals: MacroTotals, fallbackReason: String? = nil) {
    self.source = source
    self.totals = totals
    self.fallbackReason = fallbackReason
  }

  // MacroTotals is a production type without Equatable; compare by fields.
  static func == (lhs: ProgressTodayReading, rhs: ProgressTodayReading) -> Bool {
    lhs.source == rhs.source && lhs.fallbackReason == rhs.fallbackReason
      && lhs.totals.calories == rhs.totals.calories && lhs.totals.protein == rhs.totals.protein
      && lhs.totals.carbs == rhs.totals.carbs && lhs.totals.fat == rhs.totals.fat
  }
}

// MARK: - Aggregation policy

enum ProgressAggregation {
  /// Day key matching the repository's `date(cooked_at, 'localtime')`
  /// bucketing: yyyy-MM-dd in the device calendar.
  static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// Builds the full window of day points from journal-backed data.
  ///
  /// - `journalTotals` comes straight from
  ///   `UserDataRepository.dailyMacroTotals(lastDays:)`, which zero-fills
  ///   missing days. This builder restores the distinction the raw output
  ///   loses: only days listed in `knownDayKeys` (days with at least one
  ///   journal entry, from `mealsByDay(lastDays:)`) carry a value; the rest
  ///   are "no data".
  static func dayPoints(
    journalTotals: [DailyMacroPoint],
    knownDayKeys: Set<String>,
    lastDays: Int,
    calendar: Calendar = .current
  ) -> [ProgressDayPoint] {
    let totalsByKey = Dictionary(
      uniqueKeysWithValues: journalTotals.map {
        (dayKey($0.date, calendar: calendar), $0)
      })

    return windowDates(lastDays: lastDays, calendar: calendar).map { date in
      let key = dayKey(date, calendar: calendar)
      guard knownDayKeys.contains(key) else {
        return ProgressDayPoint(date: date, source: .localJournal, value: nil)
      }
      let totals = totalsByKey[key]
      return ProgressDayPoint(
        date: date,
        source: .localJournal,
        value: totals.map {
          MacroTotals(calories: $0.calories, protein: $0.protein, carbs: $0.carbs, fat: $0.fat)
        })
    }
  }

  /// Builds day points from a HealthKit daily series. The series zero-fills
  /// its window, and a zero total means no samples were recorded, so a day
  /// whose totals are all zero is presented as "no data" rather than a
  /// 0-calorie day.
  static func dayPoints(
    healthDays: [AppleHealthNutritionDay],
    lastDays: Int,
    calendar: Calendar = .current
  ) -> [ProgressDayPoint] {
    let valuesByKey = Dictionary(
      uniqueKeysWithValues: healthDays.map {
        (dayKey($0.date, calendar: calendar), $0.totals)
      })

    return windowDates(lastDays: lastDays, calendar: calendar).map { date in
      let key = dayKey(date, calendar: calendar)
      guard let totals = valuesByKey[key] else {
        return ProgressDayPoint(date: date, source: .appleHealth, value: nil)
      }
      let hasSamples = totals.calories != 0 || totals.proteinGrams != 0
        || totals.carbsGrams != 0 || totals.fatGrams != 0
      return ProgressDayPoint(
        date: date,
        source: .appleHealth,
        value: hasSamples
          ? MacroTotals(
            calories: totals.calories,
            protein: totals.proteinGrams,
            carbs: totals.carbsGrams,
            fat: totals.fatGrams)
          : nil
      )
    }
  }

  /// The range window: `lastDays` calendar days ending today, oldest first —
  /// the same window shape the repository queries use.
  static func windowDates(lastDays: Int, calendar: Calendar = .current) -> [Date] {
    let safeDays = max(1, lastDays)
    let today = calendar.startOfDay(for: Date())
    return (0..<safeDays).reversed().compactMap {
      calendar.date(byAdding: .day, value: -$0, to: today)
    }
  }
}

// MARK: - Stats and the full reading

/// Journal-backed counters Progress displays.
struct ProgressStats: Equatable, Sendable {
  let totalMealsCooked: Int
  let totalRecipesUsed: Int
  let currentStreak: Int
  let averageRating: Double?
  let weekActivity: [Bool]
  let hasOnboarded: Bool
}

/// The typed, provenance-preserving read model output for the Progress tab.
struct ProgressReading: Sendable {
  let today: ProgressTodayReading
  let weekly: ProgressRangeReading
  let goal: ProgressGoalTarget
  let stats: ProgressStats
  let recentJournal: [CookingJournalEntry]
}

// MARK: - Read model

/// Typed, provenance-preserving read model for the Progress feature.
///
/// Reads go through the existing persistence API only (`UserDataRepository`,
/// `PersonalizationService`, `AppleHealthServicing`) — no repository or
/// snapshot arithmetic is re-implemented. What this adds on top of the raw
/// repository outputs:
///
/// - per-number provenance (local journal vs Health; confirmed vs suggested)
/// - unknown-day preservation (the repository zero-fills; this model marks
///   days with no data instead) and averages that exclude those days
/// - a revision token that invalidates on portion edits, date shifts, and
///   profile/goal changes, which the shared dashboard token misses
struct ProgressReadModel: Sendable {
  let userDataRepository: UserDataRepository
  let personalizationService: PersonalizationService
  let appleHealthService: AppleHealthServicing
  var calendar: Calendar = .current

  // MARK: Today

  /// Today's intake. Prefers Apple Health when authorized and reachable;
  /// otherwise (or on failure) reads the local journal — and labels which
  /// one produced the numbers. Sources are never blended.
  func loadToday() async throws -> ProgressTodayReading {
    let local = try userDataRepository.todayMacros()

    func localReading(fallbackReason: String? = nil) -> ProgressTodayReading {
      ProgressTodayReading(source: .localJournal, totals: local, fallbackReason: fallbackReason)
    }

    guard appleHealthService.authorizationStatus() == .authorized else {
      return localReading()
    }

    let start = calendar.startOfDay(for: Date())
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
      return localReading()
    }

    do {
      guard
        let healthTotals = try await appleHealthService.fetchNutritionTotals(
          in: DateInterval(start: start, end: end))
      else {
        return localReading()
      }
      return ProgressTodayReading(
        source: .appleHealth,
        totals: MacroTotals(
          calories: healthTotals.calories,
          protein: healthTotals.proteinGrams,
          carbs: healthTotals.carbsGrams,
          fat: healthTotals.fatGrams))
    } catch {
      return localReading(fallbackReason: "Apple Health read failed: \(error.localizedDescription)")
    }
  }

  // MARK: Ranges

  /// Per-day readings for a range. The journal path distinguishes "no data"
  /// days via `mealsByDay`; the Health path treats all-zero sample days as
  /// "no data". Sources are never blended: a failed Health read falls back
  /// to the journal and labels the reading local.
  func loadRange(lastDays: Int) async throws -> ProgressRangeReading {
    let safeDays = max(1, lastDays)
    let journalTotals = try userDataRepository.dailyMacroTotals(lastDays: safeDays)
    let knownDayKeys = Set(
      try userDataRepository.mealsByDay(lastDays: safeDays)
        .filter { $0.meals > 0 }
        .map { ProgressAggregation.dayKey($0.date, calendar: calendar) })

    func localReading(fallbackReason: String? = nil) -> ProgressRangeReading {
      ProgressRangeReading(
        lastDays: safeDays,
        source: .localJournal,
        days: ProgressAggregation.dayPoints(
          journalTotals: journalTotals,
          knownDayKeys: knownDayKeys,
          lastDays: safeDays,
          calendar: calendar),
        fallbackReason: fallbackReason)
    }

    guard appleHealthService.authorizationStatus() == .authorized else {
      return localReading()
    }

    do {
      let healthDays = try await appleHealthService.fetchDailyNutritionTotals(
        lastDays: safeDays,
        endingOn: Date())
      return ProgressRangeReading(
        lastDays: safeDays,
        source: .appleHealth,
        days: ProgressAggregation.dayPoints(
          healthDays: healthDays,
          lastDays: safeDays,
          calendar: calendar))
    } catch {
      return localReading(fallbackReason: "Apple Health read failed: \(error.localizedDescription)")
    }
  }

  // MARK: Full reading

  /// The complete typed reading for the Progress tab. Saved winners are
  /// derived by the view model from `recentJournal` (existing logic, left in
  /// place); everything else comes from here with provenance attached.
  func loadReading() async throws -> ProgressReading {
    let hasOnboarded = try userDataRepository.hasCompletedOnboarding()
    let profile = hasOnboarded ? try userDataRepository.fetchHealthProfile() : .default
    let today = try await loadToday()
    let weekly = try await loadRange(lastDays: ChartRange.week.rawValue)
    let stats = ProgressStats(
      totalMealsCooked: try userDataRepository.totalMealsCooked(),
      totalRecipesUsed: try userDataRepository.totalRecipesUsed(),
      currentStreak: try personalizationService.currentStreak(),
      averageRating: try userDataRepository.averageRating(),
      weekActivity: try personalizationService.weekActivity(),
      hasOnboarded: hasOnboarded)

    return ProgressReading(
      today: today,
      weekly: weekly,
      goal: ProgressGoalTarget.resolve(profile: profile, hasOnboarded: hasOnboarded),
      stats: stats,
      recentJournal: try userDataRepository.cookingJournal(limit: 12))
  }
}

// MARK: - Revision token

/// Digest of the health-profile fields Progress displays, so goal and target
/// changes invalidate goal-dependent outputs.
struct ProgressProfileDigest: Equatable, Sendable {
  let goalRaw: String
  let dailyCalories: Int?
  let proteinPct: Double
  let carbsPct: Double
  let fatPct: Double
  let updatedAtEpoch: Double?
}

/// Invalidation token for Progress reads, tracked over the shared database.
///
/// The shared dashboard observer
/// (`UserDataRepository.observeCookingHistoryChanges`) tracks row count,
/// max id, a rating checksum, and a servings checksum. A portion edit
/// (`portion_multiplier`) or a cooked-at (date) revision changes aggregates
/// but can leave all four of those fields untouched, and a profile/goal
/// change is invisible to it — Progress cards would go silently stale. This
/// token adds the missing dimensions so Progress invalidates on all three.
struct ProgressRevisionToken: Equatable, Sendable {
  let mealCount: Int
  let maxHistoryID: Int64
  let ratingChecksum: Int
  let servingsChecksum: Int
  /// Sum of cooked_at epochs — moves when any entry is re-dated.
  let cookedAtChecksum: Int
  /// Max cooked_at epoch — catches re-dating even when a sum would cancel out.
  let maxCookedAtEpoch: Int
  /// Sum of portion multipliers (milli-units) — moves on a portion edit.
  let portionChecksum: Int
  /// Health-profile digest; nil while no profile row exists.
  let profile: ProgressProfileDigest?

  static func read(in db: Database) throws -> ProgressRevisionToken {
    let historyRow = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COUNT(*) AS total_count,
          COALESCE(MAX(id), 0) AS latest_id,
          COALESCE(SUM(COALESCE(rating, 0)), 0) AS rating_checksum,
          COALESCE(SUM(COALESCE(servings_consumed, 0)), 0) AS servings_checksum,
          COALESCE(SUM(CAST(COALESCE(strftime('%s', cooked_at), '0') AS INTEGER)), 0)
            AS cooked_at_checksum,
          COALESCE(MAX(CAST(COALESCE(strftime('%s', cooked_at), 0) AS INTEGER)), 0) AS max_cooked_at,
          COALESCE(SUM(CAST(ROUND(portion_multiplier * 1000) AS INTEGER)), 0)
            AS portion_checksum
        FROM cooking_history
        """)
    let profileRow = try Row.fetchOne(
      db,
      sql: """
        SELECT goal, daily_calories, protein_pct, carbs_pct, fat_pct, updated_at
        FROM health_profile WHERE id = 1
        """)

    let profile: ProgressProfileDigest?
    if let profileRow {
      let updatedAt: Date? = profileRow["updated_at"]
      let goalRaw: String = profileRow["goal"] ?? ""
      let dailyCalories: Int? = profileRow["daily_calories"]
      let proteinPct: Double = profileRow["protein_pct"] ?? 0
      let carbsPct: Double = profileRow["carbs_pct"] ?? 0
      let fatPct: Double = profileRow["fat_pct"] ?? 0
      profile = ProgressProfileDigest(
        goalRaw: goalRaw,
        dailyCalories: dailyCalories,
        proteinPct: proteinPct,
        carbsPct: carbsPct,
        fatPct: fatPct,
        updatedAtEpoch: updatedAt?.timeIntervalSince1970)
    } else {
      profile = nil
    }

    // GRDB typed reads: on Linux, `row[...] as? Int` silently fails, so
    // every value is decoded through the generic subscript instead.
    let mealCount: Int = historyRow?["total_count"] ?? 0
    let maxHistoryID: Int64 = historyRow?["latest_id"] ?? 0
    let ratingChecksum: Int = historyRow?["rating_checksum"] ?? 0
    let servingsChecksum: Int = historyRow?["servings_checksum"] ?? 0
    let cookedAtChecksum: Int = historyRow?["cooked_at_checksum"] ?? 0
    let maxCookedAtEpoch: Int = historyRow?["max_cooked_at"] ?? 0
    let portionChecksum: Int = historyRow?["portion_checksum"] ?? 0

    return ProgressRevisionToken(
      mealCount: mealCount,
      maxHistoryID: maxHistoryID,
      ratingChecksum: ratingChecksum,
      servingsChecksum: servingsChecksum,
      cookedAtChecksum: cookedAtChecksum,
      maxCookedAtEpoch: maxCookedAtEpoch,
      portionChecksum: portionChecksum,
      profile: profile)
  }

  /// ValueObservation over `cooking_history` and `health_profile`.
  /// Fires whenever any tracked dimension moves; callers dedupe by comparing
  /// the token (every consumer already compares tokens before acting).
  /// Callers pick the scheduling (`.mainActor` in the app; tests may use a
  /// queue-based schedule).
  static func observation() -> ValueObservation<ValueReducers.Fetch<ProgressRevisionToken>> {
    ValueObservation.tracking { db in
      try ProgressRevisionToken.read(in: db)
    }
  }
}
