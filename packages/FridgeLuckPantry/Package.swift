// swift-tools-version: 6.1
// FridgeLuckPantry — Part 2 of the 2026-10-11 overhaul: pantry truth
// (SPEC §3.2 binding contract, PLAN evaluation suite A).
//
// Manifest ownership (engineering plan, Goal 5 option A):
// - packages/FridgeLuckCore is owned by the foundation task (branch
//   overhaul/core-foundation, PR #90 under review) and is frozen for this
//   task, so the two pantry-truth targets live in this sibling package and
//   depend on FLDomain/FLPersistence by path. When PR #90 merges and the
//   freeze lifts, FLRecipeCore and FLInventoryCore graft into
//   packages/FridgeLuckCore and this package retires (recorded in the PR
//   Handoff).
// - FLDomain imports Foundation only; no target here imports UIKit, SwiftUI
//   or AppKit.

import PackageDescription

let package = Package(
    name: "FridgeLuckPantry",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FLInventoryCore", targets: ["FLInventoryCore"]),
        .library(name: "FLRecipeCore", targets: ["FLRecipeCore"]),
    ],
    dependencies: [
        // Part 1: domain contracts and GRDB persistence foundation.
        .package(path: "../FridgeLuckCore"),
        // Canonical composition truth (Review round 2): restriction checks
        // take allergen and diet facts from here, fail closed on unknown.
        .package(path: "../FLIngredientFacts"),
        // Same GRDB requirement as FridgeLuckCore; SwiftPM resolves one copy.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Pantry truth ledger (SPEC 3.2): append-only stock events with
        // quantity evidence, corrections that supersede rather than erase,
        // scans observe / purchases add, idempotent retries. GRDB-backed.
        .target(
            name: "FLInventoryCore",
            dependencies: [
                .product(name: "FLDomain", package: "FridgeLuckCore"),
                .product(name: "FLPersistence", package: "FridgeLuckCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // Recipe catalog and feasibility (SPEC 3.2/3.5). Added with its
        // sources in the second milestone of this task.
        .target(
            name: "FLRecipeCore",
            dependencies: [
                .product(name: "FLDomain", package: "FridgeLuckCore"),
                .product(name: "FLPersistence", package: "FridgeLuckCore"),
                .product(name: "FLIngredientFacts", package: "FLIngredientFacts"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "FLInventoryCore",
            ]
        ),
        .testTarget(name: "FLInventoryCoreTests", dependencies: ["FLInventoryCore"]),
        .testTarget(
            name: "FLRecipeCoreTests",
            dependencies: [
                "FLRecipeCore",
                .product(name: "FLIngredientFacts", package: "FLIngredientFacts"),
            ]
        ),
    ]
)
