// swift-tools-version:5.9
import PackageDescription

// Replay harness for scan-correction drift evaluation.
// AppSources/ is generated from production sources by Scripts/sync_sources.py
// (verbatim copies + Linux platform shims); run that script before building.
let package = Package(
  name: "SwiftReplay",
  dependencies: [
    // Pinned exactly (7.10.0..<7.10.1 contains only 7.10.0): replay results
    // must not drift with GRDB releases.
    .package(url: "https://github.com/groue/GRDB.swift.git", "7.10.0"..<"7.10.1"),
  ],
  targets: [
    .target(
      name: "AppSources",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/AppSources"
    ),
    .testTarget(
      name: "ReplayTests",
      dependencies: ["AppSources", .product(name: "GRDB", package: "GRDB.swift")],
      path: "Tests/ReplayTests"
    ),
  ]
)
