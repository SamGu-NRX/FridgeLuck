// swift-tools-version:6.0
import PackageDescription

// Linux-safe check package for the unified search index.
//
// The test target compiles the REAL production search and persistence
// sources (apps/ios/Platform/Search, apps/ios/Platform/Persistence) against
// GRDB on Linux. Those sources are not committed here; run Scripts/refresh.sh
// to copy them in from the repository tree before `swift test`:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/unified-search-check
//
// The retrieval-quality evaluation lives in the test target
// (SearchEvalTests) over a frozen corpus and a frozen query set
// (Tests/SearchCheckTests/Fixtures/corpus.json); it writes a metrics report
// and per-query top-3 recommendations.

let package = Package(
  name: "unified-search-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "SearchCheck",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/SearchCheck"
    ),
    .testTarget(
      name: "SearchCheckTests",
      dependencies: ["SearchCheck"],
      path: "Tests/SearchCheckTests",
      resources: [.copy("Fixtures")]
    ),
  ]
)
