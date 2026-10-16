import Foundation

/// DEBUG-only launch mode for the FridgeLuckUITests main-journey test. Launching the app
/// with `-FLUITestJourney` starts it on a fresh empty database in a temporary directory
/// and suppresses the first-run tutorial and spotlight overlays so the test can drive the
/// real screens deterministically. Release builds never read the flag.
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
