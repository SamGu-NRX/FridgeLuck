// swift-tools-version:6.0
import PackageDescription

// Linux-safe check package for the Progress flow (typed provenance read
// model, range-state semantics, flow policies).
//
// The test target compiles the REAL production persistence and Progress
// sources (apps/ios/Platform/Persistence, apps/ios/Feature/Progress) against
// GRDB on Linux. Those sources are not committed here; run Scripts/refresh.sh
// to copy them in from the repository tree before `swift test`:
//
//   bash Scripts/refresh.sh
//   TZ=UTC swift test --package-path apps/ios/Tools/progress-flow-check
let package = Package(
  name: "progress-flow-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "ProgressFlowCheck",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/ProgressFlowCheck"
    ),
    .testTarget(
      name: "ProgressFlowCheckTests",
      dependencies: ["ProgressFlowCheck"],
      path: "Tests/ProgressFlowCheckTests"
    ),
  ]
)
