// swift-tools-version:6.0
import PackageDescription

// Linux-safe check package for historical nutrition snapshots.
//
// The test target compiles the REAL production persistence sources
// (apps/ios/Platform/Persistence) against GRDB on Linux. Those sources are
// not committed here; run Scripts/refresh.sh to copy them in from the
// repository tree before `swift test`:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/historical-nutrition-check
let package = Package(
  name: "historical-nutrition-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "NutritionCheck",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/NutritionCheck"
    ),
    .testTarget(
      name: "NutritionCheckTests",
      dependencies: ["NutritionCheck"],
      path: "Tests/NutritionCheckTests"
    ),
  ]
)
