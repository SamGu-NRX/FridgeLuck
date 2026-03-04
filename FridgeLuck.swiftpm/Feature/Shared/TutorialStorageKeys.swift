import Foundation

enum TutorialStorageKeys {
  static let progress = "tutorialProgressStorage"
  static let hasSeenSpotlightTutorial = "hasSeenSpotlightTutorial"
  static let hasSeenCompletionSpotlight = "hasSeenCompletionSpotlight"
  static let hasSeenReviewSpotlight = "hasSeenReviewSpotlight"
  static let hasSeenSwapTooltip = "hasSeenSwapTooltip"
  static let hasSeenFirstScanNudge = "hasSeenFirstScanNudge"
  static let hasSeenDemoSpotlight = "hasSeenDemoSpotlight"

  static let all: [String] = [
    progress,
    hasSeenSpotlightTutorial,
    hasSeenCompletionSpotlight,
    hasSeenReviewSpotlight,
    hasSeenSwapTooltip,
    hasSeenFirstScanNudge,
    hasSeenDemoSpotlight,
  ]
}

enum LearningStorageKeys {
  static let suggestionsShown = "learning_suggestions_shown"
  static let suggestionsAccepted = "learning_suggestions_accepted"
}
