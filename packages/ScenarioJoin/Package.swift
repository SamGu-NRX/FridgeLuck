// swift-tools-version: 6.1
// ScenarioJoin — Part 6 of the 2026-10-11 overhaul: the JOIN. A composite
// SwiftPM package that path-depends on every capability sibling so the whole
// composed tree builds and links together on Linux, and hosts the week-long
// household scenario suite asserting the cross-package contracts
// (docs/spec/overhaul-20261011/SPEC.md §3; PLAN.md suites A–G).
//
// Manifest ownership:
// - This manifest is owned by the join task (branch overhaul/scenario-join).
//   It edits no capability package; collisions are resolved by converging on
//   FLDomain types and recorded in the PR Handoff.
// - packages/FridgeLuckCore/** stays untouched (PR #90 awaits re-review):
//   composition-level needs on the foundation are contract requests, not
//   patches.
// - No CI or workflow changes: this package runs in the sandbox; the Proof
//   section of the PR carries exact commands and output.
// - No target imports UIKit, SwiftUI or AppKit. No network, no LLM calls:
//   every scenario is seeded, deterministic and offline.

import PackageDescription

let package = Package(
    name: "ScenarioJoin",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FLScenarioKit", targets: ["FLScenarioKit"]),
    ],
    dependencies: [
        // The five capability packages under composition (PRs #90, #103, #98,
        // #117, #106) — path dependencies so SwiftPM unifies one FridgeLuckCore
        // node for the whole graph.
        .package(path: "../FridgeLuckCore"),
        .package(path: "../FLFlowCore"),
        .package(path: "../FLAssistantCore"),
        .package(path: "../FridgeLuckPantry"),
        .package(path: "../FLCommunityCore"),
        // Declared directly because FridgeLuckCore does not re-export GRDB as
        // a product; SPM resolves one shared version for the graph.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // The join harness: one household database that applies every
        // package's migrations (the phone's single GRDB store), injectable
        // compressed time, deterministic builders, the mapping from pantry
        // truth to flow and assistant inputs, and replayable trace records.
        .target(
            name: "FLScenarioKit",
            dependencies: [
                .product(name: "FLDomain", package: "FridgeLuckCore"),
                .product(name: "FLPersistence", package: "FridgeLuckCore"),
                .product(name: "FLFlowCore", package: "FLFlowCore"),
                .product(name: "FLAssistantCore", package: "FLAssistantCore"),
                .product(name: "FLInventoryCore", package: "FridgeLuckPantry"),
                .product(name: "FLRecipeCore", package: "FridgeLuckPantry"),
                .product(name: "FLCommunityCore", package: "FLCommunityCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // The week-long household scenario suite (scenarios S1–S7 with
        // cross-package invariant assertions).
        .testTarget(
            name: "ScenarioJoinTests",
            dependencies: ["FLScenarioKit"]
        ),
    ]
)
