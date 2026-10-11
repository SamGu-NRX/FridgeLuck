// swift-tools-version: 6.0

// cookbook-flow-check: offline validation of the personal cookbook's storage
// contracts. Stages the production sources it exercises (see Scripts/refresh.sh)
// and runs them against real GRDB/SQLite — no UI, no app target, no Xcode.
//
// Run:  ./Scripts/refresh.sh && swift test
// (refresh.sh must run first: Sources/ is staged, not tracked.)

import PackageDescription

let package = Package(
  name: "cookbook-flow-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
    // Provides the `Crypto` module (the Linux stand-in for CryptoKit, shimmed
    // at staging time by Scripts/refresh.sh).
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
  ],
  targets: [
    // Mirror of the app's FeatureLogic slice the cookbook persistence relies on.
    // Staged FeatureLogic/Cookbook sources only, so the check stays pure Foundation.
    .target(
      name: "FLFeatureLogic",
      path: "Sources/FLFeatureLogic"
    ),
    // Staged production sources: domain models, migrations, the bundle refresh
    // stack (for the user-recipe anti-theft proof), and the cookbook
    // store/transaction service.
    .target(
      name: "CookbookFlowCheck",
      dependencies: [
        "FLFeatureLogic",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Sources/CookbookFlowCheck"
    ),
    .testTarget(
      name: "CookbookFlowCheckTests",
      dependencies: [
        "CookbookFlowCheck",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/CookbookFlowCheckTests"
    ),
  ]
)
