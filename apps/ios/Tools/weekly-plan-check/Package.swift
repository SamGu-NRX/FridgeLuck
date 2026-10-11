// swift-tools-version: 6.0

// Portable checks for the WeeklyPlan core. The `WeeklyPlanCore` target is a
// symlink to `apps/ios/FeatureLogic/WeeklyPlan`, so these tests and the eval
// harness compile the exact sources the app ships — there is no second copy of
// the planner to drift.

import PackageDescription

let package = Package(
  name: "weekly-plan-check",
  targets: [
    .target(name: "WeeklyPlanCore", path: "WeeklyPlanCore"),
    .executableTarget(
      name: "weekly-plan-check",
      dependencies: ["WeeklyPlanCore"],
      path: "Sources/WeeklyPlanCheck"
    ),
    .testTarget(
      name: "WeeklyPlanCheckTests",
      dependencies: ["WeeklyPlanCore"],
      path: "Tests/WeeklyPlanCheckTests"
    ),
  ]
)
