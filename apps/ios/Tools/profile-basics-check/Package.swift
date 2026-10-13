// swift-tools-version: 6.0
import PackageDescription

// Offline verification harness for the Profile Basics edit-and-retry flow.
//
// Sources are symlinks into the app's existing Domain / Platform / Feature
// trees, so `swift test` runs the real production state machine, the real
// HealthProfile model, and the real GRDB-backed UserDataRepository adapter —
// on Linux, with no Xcode required.
//
// The SwiftUI view itself is app-target code (macOS/iOS only) and is covered
// by the macOS CI build; runtime UI behavior needs an Apple host and is
// tracked separately in the PR handoff.
let package = Package(
  name: "profile-basics-check",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "ProfileBasicsCheck",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: "Sources/ProfileBasicsCheck"
    ),
    .testTarget(
      name: "ProfileBasicsCheckTests",
      dependencies: [
        .target(name: "ProfileBasicsCheck"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/ProfileBasicsCheckTests"
    ),
  ]
)
