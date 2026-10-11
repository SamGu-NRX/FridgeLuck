// swift-tools-version:6.0
import PackageDescription

// Linux-safe check package for the operational Home flow (FL4).
//
// The test target compiles the REAL Home flow sources (Feature/Home flow files)
// plus the persistence sources they consume. Those sources are not committed here;
// run Scripts/refresh.sh to copy them in from the repository tree before
// `swift test`:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/home-flow-check
let package = Package(
  name: "home-flow-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "HomeFlowCheck",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/HomeFlowCheck"
    ),
    .testTarget(
      name: "HomeFlowCheckTests",
      dependencies: ["HomeFlowCheck"],
      path: "Tests/HomeFlowCheckTests"
    ),
  ]
)
