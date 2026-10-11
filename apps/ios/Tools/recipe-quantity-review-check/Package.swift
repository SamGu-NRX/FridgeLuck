// swift-tools-version: 6.0
import PackageDescription

// Offline verification harness for the read-only recipe amount review.
//
// The SwiftPM sources are symlinks into the app's existing Domain / Platform /
// FeatureLogic trees, so `swift test` runs against the real migrations, the real
// repository and nutrition services, and the real FeatureLogic session — on Linux
// CI, with no Xcode required.
//
// The app target itself (SwiftUI views, AppDependencies) stays out of scope here;
// the production reader adapter is mirrored in Tests with real GRDB reads behind it.
let package = Package(
  name: "recipe-quantity-review-check",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "RecipeQuantityReviewCheck",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: "Sources/RecipeQuantityReviewCheck"
    ),
    .testTarget(
      name: "RecipeQuantityReviewCheckTests",
      dependencies: [
        .target(name: "RecipeQuantityReviewCheck"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/RecipeQuantityReviewCheckTests"
    ),
  ]
)
