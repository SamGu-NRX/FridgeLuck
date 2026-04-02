enum HelpTutorialReplayRoute: Equatable, Sendable {
  case demoMode
  case ingredientReview(DemoScenario)
  case recipeMatch(DemoScenario)
  case liveAssistant(DemoScenario)

  static func route(for quest: TutorialQuest) -> HelpTutorialReplayRoute {
    switch quest {
    case .firstScan:
      return .demoMode
    case .ingredientReview:
      return .ingredientReview(.asianStirFry)
    case .pickRecipeMatch:
      return .recipeMatch(.mediterraneanLunch)
    case .cookWithLeChef:
      return .liveAssistant(.mediterraneanLunch)
    }
  }
}
