// swift-tools-version: 6.1
// FLFlowCore — the dinner decision and cooking flows of the overhauled app
// (engineering plan E12; SPEC §2 Tonight, §3 contracts, §4 LeChef local core),
// built and tested on Linux. See docs/spec/overhaul-20261011/SPEC.md on branch
// docs/spec-overhaul-20261011.
//
// Manifest ownership: Part 1 (branch overhaul/core-foundation) owns the
// FridgeLuckCore manifest, which is under review — this package therefore
// stands beside it as its own SwiftPM package with a path dependency, so
// packages/FridgeLuckCore/** stays untouched. Join note for Part 6: move
// Sources/FLFlowCore and Tests/FLFlowCoreTests into packages/FridgeLuckCore
// and register the targets there (the directory names already match the
// engineering plan). No target imports UIKit, SwiftUI or AppKit.

import PackageDescription

let package = Package(
    name: "FLFlowCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FLFlowCore", targets: ["FLFlowCore"]),
    ],
    dependencies: [
        .package(path: "../FridgeLuckCore"),
        // Declared directly because FridgeLuckCore does not re-export GRDB
        // as a product; SPM resolves one shared version for the graph.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Dinner decision (Tonight) and cook-session state machines over the
        // FLDomain contracts, with the single-transaction meal-log hand-off
        // through FLPersistence. Foundation and GRDB only.
        .target(
            name: "FLFlowCore",
            dependencies: [
                .product(name: "FLDomain", package: "FridgeLuckCore"),
                .product(name: "FLPersistence", package: "FridgeLuckCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "FLFlowCoreTests", dependencies: ["FLFlowCore"]),
    ]
)
