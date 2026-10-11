import Foundation

/// Routing decisions for the Progress tab's interactions (R3). Kept pure so
/// the end-to-end wiring decisions are testable without UI or persistence.
///
/// Ownership rules this policy encodes:
/// - Journal editing belongs to the journal detail screen
///   (`RecipeJournalDetailView`, the existing owner of entry revisions).
///   Progress never presents its own journal or goal editor.
/// - Goal editing goes through the app's existing goal-editor callback
///   (Settings → profile basics, wired in `ContentView`).
/// - Correction flows are owned elsewhere (e.g. the ingredient-review
///   correction screen). While one is active, Progress hands off to it
///   instead of starting a second, competing correction surface.
enum ProgressFlowPolicy {
  /// Where a tapped recent-meal entry routes: to the existing journal detail
  /// screen, identified by its cooking-history id.
  static func mealRoute(for entry: CookingJournalEntry) -> ProgressMealRoute {
    .journalDetail(entryID: entry.id)
  }

  /// How Progress resolves a correction request for a meal. While a
  /// correction flow is active elsewhere, requests hand off to it; otherwise
  /// they route to the journal detail screen.
  static func correctionDecision(isCorrectionFlowActive: Bool) -> ProgressCorrectionDecision {
    isCorrectionFlowActive
      ? .handOffToActiveCorrectionFlow
      : .routeToJournalDetail
  }

  /// Goal editing is offered through the existing goal-editor callback only
  /// once onboarding is complete; the callback itself guards onboarding.
  static func canOfferGoalEditing(hasOnboarded: Bool) -> Bool {
    hasOnboarded
  }
}

/// Destination for a tapped journal entry.
enum ProgressMealRoute: Equatable, Sendable {
  case journalDetail(entryID: Int64)
}

/// How Progress resolves a correction request.
enum ProgressCorrectionDecision: Equatable, Sendable {
  /// A correction flow is already running elsewhere in the app: hand the
  /// user off to it instead of starting a competing surface.
  case handOffToActiveCorrectionFlow
  /// No correction flow is active: route to the journal detail screen, the
  /// existing owner of entry revisions.
  case routeToJournalDetail
}
