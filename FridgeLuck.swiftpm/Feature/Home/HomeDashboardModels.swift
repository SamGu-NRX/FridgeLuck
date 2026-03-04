import Foundation

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
