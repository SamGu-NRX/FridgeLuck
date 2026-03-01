import SwiftUI

// MARK: - Quest Definitions

/// Each quest represents a guided step that teaches a core feature.
enum TutorialQuest: Int, CaseIterable, Identifiable, Codable, Sendable {
  case setupProfile = 0
  case firstScan = 1
  case cookAndRate = 2
  case exploreMore = 3

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .setupProfile: return "Set Up Your Kitchen"
    case .firstScan: return "Your First Scan"
    case .cookAndRate: return "Cook & Rate"
    case .exploreMore: return "Explore More"
    }
  }

  var subtitle: String {
    switch self {
    case .setupProfile:
      return "Share your nutrition goals and dietary needs."
    case .firstScan:
      return "Try a demo fridge to see how it works."
    case .cookAndRate:
      return "Cook a demo recipe and rate it so I can learn your taste."
    case .exploreMore:
      return "Try new cuisines or snap a photo for nutrition info."
    }
  }

  var icon: String {
    switch self {
    case .setupProfile: return "person.crop.circle.badge.checkmark"
    case .firstScan: return "camera.viewfinder"
    case .cookAndRate: return "fork.knife.circle"
    case .exploreMore: return "sparkle.magnifyingglass"
    }
  }

  var accentColor: Color {
    switch self {
    case .setupProfile: return AppTheme.sage
    case .firstScan: return AppTheme.accent
    case .cookAndRate: return AppTheme.oat
    case .exploreMore: return AppTheme.dustyRose
    }
  }

  var ctaTitle: String {
    switch self {
    case .setupProfile: return "Set Up Profile"
    case .firstScan: return "Try Demo Mode"
    case .cookAndRate: return "Cook a Recipe"
    case .exploreMore: return "Explore"
    }
  }

  var ctaIcon: String {
    switch self {
    case .setupProfile: return "arrow.right"
    case .firstScan: return "camera.fill"
    case .cookAndRate: return "fork.knife"
    case .exploreMore: return "sparkles"
    }
  }

  /// Stagger index for entrance animation.
  var staggerIndex: Int { rawValue }
}

// MARK: - Tutorial Progress

/// Tracks which quests have been completed. Persisted via @AppStorage as a comma-separated string.
struct TutorialProgress: Equatable, Sendable {
  var completedQuestRawValues: Set<Int>

  static let empty = TutorialProgress(completedQuestRawValues: [])

  var completedQuests: Set<TutorialQuest> {
    Set(completedQuestRawValues.compactMap { TutorialQuest(rawValue: $0) })
  }

  var completedCount: Int {
    completedQuests.count
  }

  var totalCount: Int {
    TutorialQuest.allCases.count
  }

  var progressFraction: Double {
    guard totalCount > 0 else { return 0 }
    return Double(completedCount) / Double(totalCount)
  }

  var isComplete: Bool {
    completedCount >= totalCount
  }

  /// The next quest the user should work on, or nil if all complete.
  var currentQuest: TutorialQuest? {
    TutorialQuest.allCases.first { !completedQuests.contains($0) }
  }

  /// Quests that are completed, in order.
  var completedQuestsOrdered: [TutorialQuest] {
    TutorialQuest.allCases.filter { completedQuests.contains($0) }
  }

  /// Quests that are not yet completed and not the current quest, in order.
  var upcomingQuests: [TutorialQuest] {
    guard let current = currentQuest else { return [] }
    return TutorialQuest.allCases.filter { $0 != current && !completedQuests.contains($0) }
  }

  func isCompleted(_ quest: TutorialQuest) -> Bool {
    completedQuests.contains(quest)
  }

  mutating func markCompleted(_ quest: TutorialQuest) {
    completedQuestRawValues.insert(quest.rawValue)
  }

  /// Encode to a storable string for @AppStorage.
  var storageString: String {
    completedQuestRawValues.sorted().map(String.init).joined(separator: ",")
  }

  /// Decode from a stored string.
  init(storageString: String) {
    if storageString.isEmpty {
      self.completedQuestRawValues = []
    } else {
      self.completedQuestRawValues = Set(
        storageString.split(separator: ",").compactMap { Int(String($0)) }
      )
    }
  }

  init(completedQuestRawValues: Set<Int>) {
    self.completedQuestRawValues = completedQuestRawValues
  }
}

// MARK: - Demo Scenario

/// Themed demo scenarios for the scan feature, each with different ingredient sets.
/// The judge can pick a cuisine to explore, seeing different recipe results each time.
enum DemoScenario: String, CaseIterable, Identifiable, Sendable {
  case quickBreakfast = "quick_breakfast"
  case asianStirFry = "asian_stir_fry"
  case mediterraneanLunch = "mediterranean_lunch"
  case tacoNight = "taco_night"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .quickBreakfast: return "Quick Breakfast"
    case .asianStirFry: return "Asian Stir-Fry"
    case .mediterraneanLunch: return "Mediterranean Lunch"
    case .tacoNight: return "Taco Night"
    }
  }

  /// Richer description for the DemoModeView cards.
  var description: String {
    switch self {
    case .quickBreakfast:
      return
        "A sunny morning spread \u{2014} crack some eggs, toast some bread, and see what FridgeLuck can whip up."
    case .asianStirFry:
      return "A well-stocked wok station with aromatic staples ready for a sizzling stir-fry."
    case .mediterraneanLunch:
      return
        "Sun-drenched ingredients from the Mediterranean pantry \u{2014} crisp vegetables and creamy chickpeas."
    case .tacoNight:
      return
        "Everything for a quick taco night \u{2014} pile on the beans, mash the avocado, squeeze the lime."
    }
  }

  /// Hint about what recipes might appear.
  var recipeHint: String {
    switch self {
    case .quickBreakfast: return "French Toast, Pancakes"
    case .asianStirFry: return "Fried Rice, Stir-Fry"
    case .mediterraneanLunch: return "Chickpea Salad, Caprese"
    case .tacoNight: return "Black Bean Tacos"
    }
  }

  var subtitle: String {
    switch self {
    case .quickBreakfast: return "Eggs, bread, banana, oats, and milk"
    case .asianStirFry: return "Rice, egg, soy sauce, chicken, and more"
    case .mediterraneanLunch: return "Chickpea, tomato, cucumber, olive oil"
    case .tacoNight: return "Black beans, tortilla, avocado, lime"
    }
  }

  var icon: String {
    switch self {
    case .quickBreakfast: return "sun.horizon.fill"
    case .asianStirFry: return "flame"
    case .mediterraneanLunch: return "leaf.fill"
    case .tacoNight: return "moon.stars.fill"
    }
  }

  var accentColor: Color {
    switch self {
    case .quickBreakfast: return AppTheme.oat
    case .asianStirFry: return AppTheme.accent
    case .mediterraneanLunch: return AppTheme.sage
    case .tacoNight: return AppTheme.dustyRose
    }
  }

  var gradientColors: [Color] {
    switch self {
    case .quickBreakfast: return [AppTheme.oat, AppTheme.oat.opacity(0.70)]
    case .asianStirFry: return [AppTheme.accent, AppTheme.accent.opacity(0.75)]
    case .mediterraneanLunch: return [AppTheme.sage, AppTheme.sage.opacity(0.70)]
    case .tacoNight: return [AppTheme.dustyRose, AppTheme.dustyRose.opacity(0.70)]
    }
  }

  /// The fixture JSON filename (without extension) in the Resources bundle.
  var fixtureFileName: String {
    switch self {
    case .quickBreakfast: return "demo_breakfast"
    case .asianStirFry: return "demo_detections"
    case .mediterraneanLunch: return "demo_mediterranean"
    case .tacoNight: return "demo_tacos"
    }
  }

  /// Scenario photo filename (without extension) in Resources/demo.
  var scenarioImageName: String {
    switch self {
    case .quickBreakfast: return "quick_breakfast_scenario"
    case .asianStirFry: return "asian_stirfry_scenario"
    case .mediterraneanLunch: return "mediterranean_scenario"
    case .tacoNight: return "taco_night_scenario"
    }
  }

  /// Ingredient IDs included in this scenario, for preview display.
  var previewIngredientIds: [Int64] {
    switch self {
    case .quickBreakfast: return [1, 15, 20, 13, 14, 31]
    case .asianStirFry: return [1, 2, 3, 4, 5, 6, 8, 21]
    case .mediterraneanLunch: return [7, 25, 35, 16, 5, 17, 12]
    case .tacoNight: return [27, 28, 26, 29, 7, 12]
    }
  }

  /// Short ingredient name list for display.
  var ingredientNames: [String] {
    previewIngredientIds.map { IngredientLexicon.displayName(for: $0) }
  }

  /// Slight rotation for a collage-style layout.
  var cardRotation: Double {
    switch self {
    case .quickBreakfast: return -0.8
    case .asianStirFry: return 1.0
    case .mediterraneanLunch: return 0.6
    case .tacoNight: return -1.2
    }
  }
}
