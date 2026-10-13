import Foundation

/// What the meal-photo confidence verdict changes for the user.
///
/// Product decision (2026-10-07): logging a photographed meal always takes an explicit tap, and
/// logged amounts follow the dish, servings and portion the user confirms. The verdict only
/// decides how much confirmation the screen asks for:
/// - `exact`: the top dish is preselected, so logging is one tap.
/// - `reviewRequired`: the top dish is preselected, and the screen asks the user to check the
///   dish and portion before logging.
/// - `estimateOnly`: nothing is preselected, and no computed macros appear until the user picks
///   a dish themselves.
///
/// A routing comparison should score this decision: a false `exact` costs a one-tap log of the
/// wrong dish, a needless `reviewRequired` costs a check, and `estimateOnly` costs a manual pick.
public enum MealPhotoConfirmationPolicy {
  public enum Verdict: Sendable, Equatable {
    case exact
    case reviewRequired
    case estimateOnly
  }

  public static func preselectsTopCandidate(for verdict: Verdict) -> Bool {
    verdict != .estimateOnly
  }

  public static func asksToCheckBeforeLogging(for verdict: Verdict) -> Bool {
    verdict != .exact
  }
}
