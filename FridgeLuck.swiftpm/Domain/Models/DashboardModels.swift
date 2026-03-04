import Foundation

// MARK: - Cooking Journal Entry

/// A single entry in the user's recipe book / cooking journal.
/// Joins cooking_history with the recipe and its computed macros.
struct CookingJournalEntry: Identifiable, Sendable, Hashable {
  let id: Int64  // cooking_history.id
  let recipe: Recipe
  let cookedAt: Date
  let rating: Int?  // 1-5 or nil
  let imagePath: String?
  let servingsConsumed: Int
  let macrosConsumed: MacroTotals  // scaled by servings

  static func == (lhs: CookingJournalEntry, rhs: CookingJournalEntry) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - Daily Macro Point

/// Macro totals for a single calendar day, used for charting.
struct DailyMacroPoint: Identifiable, Sendable {
  let date: Date
  let calories: Double
  let protein: Double  // grams
  let carbs: Double  // grams
  let fat: Double  // grams

  var id: Date { date }
}

// MARK: - Macro Totals

/// Aggregated macro totals (not per-serving — absolute consumed amounts).
struct MacroTotals: Sendable {
  let calories: Double
  let protein: Double  // grams
  let carbs: Double  // grams
  let fat: Double  // grams

  static let zero = MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0)
}

// MARK: - Dashboard Snapshot

/// All data needed to render the Dashboard view, loaded in one pass.
struct DashboardSnapshot: Sendable {
  let healthProfile: HealthProfile
  let todayMacros: MacroTotals
  let weeklyMacros: [DailyMacroPoint]
  let recentJournal: [CookingJournalEntry]
  let totalMealsCooked: Int
  let totalRecipesUsed: Int
  let currentStreak: Int
  let averageRating: Double?
}
