import Foundation

struct DailyCookingPoint: Identifiable, Sendable, Equatable {
  let date: Date
  let meals: Int

  var id: Date { date }
}

struct WeekdayCookingPoint: Identifiable, Sendable, Equatable {
  let weekdayIndex: Int
  let weekdayLabel: String
  let meals: Int

  var id: Int { weekdayIndex }
}

struct HomeRecommendation: Identifiable, Sendable {
  /// The scored identity the card opens — a catalog ref when the recommendation is a
  /// catalog recipe, the legacy integer id otherwise — so the Results screen
  /// auto-presents this exact result instead of guessing it from list order.
  let preferredID: ScoredRecipeID?
  let recipeName: String
  let explanation: String
  let cookTimeMinutes: Int?
  let matchLabel: String?
  let badgeLabel: String?
  let ingredientIDs: Set<Int64>

  var id: String {
    switch preferredID {
    case .legacy(let legacyID): return "recipe-\(legacyID)"
    case .catalog(let catalogID): return "catalog-\(catalogID)"
    case .unsaved(let title): return "unsaved-\(title)"
    case nil: return recipeName
    }
  }
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
  let latestJournalEntry: CookingJournalEntry?
  let useSoonSuggestions: [InventoryUseSoonSuggestion]

  let todayCalories: Double
  let todayProtein: Double
  let todayCarbs: Double
  let todayFat: Double
  let calorieGoal: Double
  let proteinGoal: Double
  let carbsGoal: Double
  let fatGoal: Double
  let primaryRecommendation: HomeRecommendation?
  let fallbackOptions: [HomeRecommendation]

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
