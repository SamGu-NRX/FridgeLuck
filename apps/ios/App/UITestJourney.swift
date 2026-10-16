import Foundation

/// DEBUG-only launch mode for the FridgeLuckUITests main-journey test. Launching the app
/// with `-FLUITestJourney` starts it on a fresh empty database in a temporary directory with
/// tour state cleared. The Home tour still runs, because the journey checks that Skip is
/// reachable; the recipe-results and swap coachmarks are suppressed so the test can drive
/// those screens deterministically. Release builds never read the flag.
enum UITestJourney {
  static let launchArgument = "-FLUITestJourney"

  static var isActive: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(launchArgument)
    #else
      false
    #endif
  }
}
