import Foundation

enum TutorialStorageKeys {
  static let progress = "tutorialProgressStorage"
  static let hasSeenSpotlightTutorial = "hasSeenSpotlightTutorial"
  static let hasSeenCompletionSpotlight = "hasSeenCompletionSpotlight"
  static let hasSeenReviewSpotlight = "hasSeenReviewSpotlight"
  static let hasSeenSwapTooltip = "hasSeenSwapTooltip"
  static let hasSeenDemoSpotlight = "hasSeenDemoSpotlight"
  static let hasSeenLiveAssistantLesson = "hasSeenLiveAssistantLesson"
  static let lastAdvanceSpotlightQuestShown = "lastAdvanceSpotlightQuestShown"

  static let all: [String] = [
    progress,
    hasSeenSpotlightTutorial,
    hasSeenCompletionSpotlight,
    hasSeenReviewSpotlight,
    hasSeenSwapTooltip,
    hasSeenDemoSpotlight,
    hasSeenLiveAssistantLesson,
    lastAdvanceSpotlightQuestShown,
  ]
}

enum LearningStorageKeys {
  static let suggestionsShown = "learning_suggestions_shown"
  static let suggestionsAccepted = "learning_suggestions_accepted"
}
