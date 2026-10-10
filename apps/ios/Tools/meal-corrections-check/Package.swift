// swift-tools-version: 6.1
import PackageDescription

// Offline check harness for the meal-corrections stream. It compiles the real app's
// portable domain and persistence sources (symlinked into Sources/FridgeLuck by
// bootstrap.sh — SwiftPM requires sources under the package root) against the same GRDB
// release the app pins, and exercises the accepted-plan, correction and Health-sync
// logic on any host with a Swift toolchain — no Xcode needed. SwiftUI, UIKit, HealthKit
// and os-dependent files are excluded; see README.md for the exact list.

let package = Package(
  name: "meal-corrections-check",
  dependencies: [
    // Same pin as apps/ios/Package.resolved.
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
  ],
  targets: [
    .target(
      name: "FridgeLuck",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
    ),
    .testTarget(
      name: "MealPlanAgreementTests",
      dependencies: ["FridgeLuck"]
    ),
  ]
)
