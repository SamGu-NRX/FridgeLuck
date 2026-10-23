// swift-tools-version: 6.1
// FridgeLuckCore — the portable logic of the overhauled app (SPEC §3 contracts),
// built and tested on Linux. See docs/spec/overhaul-20261011/SPEC.md on branch
// docs/spec-overhaul-20261011.
//
// Manifest ownership (engineering plan, Goal 5 option A):
// - The foundation task (branch overhaul/core-foundation) owns this manifest.
// - Each later task adds exactly its own target and test target when its part
//   needs it, never as an empty placeholder.
// - FLDomain imports Foundation only. No target imports UIKit, SwiftUI or
//   AppKit; scripts/overhaul-checks/import_rules.py enforces both rules.

import PackageDescription

let package = Package(
    name: "FridgeLuckCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FLDomain", targets: ["FLDomain"]),
        .library(name: "FLPersistence", targets: ["FLPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Domain contracts of SPEC §3: validated value types, identity, quantity
        // and nutrition evidence, restrictions, preference events, cook records
        // and assistant authority types. Foundation only.
        .target(name: "FLDomain"),
        // GRDB-backed persistence: schema registry and single-transaction
        // commands. Depends on FLDomain and GRDB, never on Apple UI frameworks.
        .target(
            name: "FLPersistence",
            dependencies: [
                "FLDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "FLDomainTests", dependencies: ["FLDomain"]),
        .testTarget(name: "FLPersistenceTests", dependencies: ["FLPersistence"]),
    ]
)
