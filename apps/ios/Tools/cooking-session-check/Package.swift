// swift-tools-version:5.9
import PackageDescription

// Offline cooking-session checkpoint harness.
//
// The CookingSession target is dependency-free (Foundation-only) so it can be
// unit-tested on any host with a Swift toolchain:
//   swift test --package-path apps/ios/Tools/cooking-session-check
// The iOS app compiles the same sources into its own CookingSession target
// (see apps/ios/Package.swift), keeping one implementation for both hosts.
let package = Package(
    name: "cooking-session-check",
    products: [
        .library(name: "CookingSession", targets: ["CookingSession"])
    ],
    targets: [
        .target(
            name: "CookingSession",
            path: "Sources/CookingSession"
        ),
        .testTarget(
            name: "CookingSessionTests",
            dependencies: ["CookingSession"],
            path: "Tests/CookingSessionTests"
        )
    ]
)
