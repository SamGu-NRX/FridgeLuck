// swift-tools-version: 6.1
// FLAssistantCore — the LeChef authority layer (SPEC §4, engineering plan Goal 3
// option A): the phone is authoritative for pantry, cook sessions and logs. The
// backend reads bounded snapshots and proposes typed actions; this package owns
// the context builder, the proposal engine, the approval binding, and the
// receipt store. Built and tested on Linux like FridgeLuckCore.
//
// Manifest ownership (engineering plan, Goal 5 option A): this manifest belongs
// to the assistant-core task (branch overhaul/assistant-core). It depends on the
// FridgeLuckCore package by path and adds no other external dependency than
// swift-crypto for the SHA-256 payload hash. No target imports UIKit, SwiftUI
// or AppKit.

import PackageDescription

let package = Package(
    name: "FLAssistantCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FLAssistantCore", targets: ["FLAssistantCore"]),
    ],
    dependencies: [
        // Part 1's foundation: FLDomain contracts and FLPersistence (GRDB setup).
        .package(path: "../FridgeLuckCore"),
        // Same GRDB requirement FridgeLuckCore declares, so SPM unifies to one
        // resolved version across the graph.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // SHA-256 for the proposal payload hash. On Linux this resolves to
        // swift-crypto; on Apple platforms it wraps CryptoKit. No other
        // external dependency is allowed here.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
    ],
    targets: [
        // The authority layer: bounded context snapshots with monotonic
        // revisions, typed tool-invocation decoding, proposal minting with a
        // canonical payload hash, approval binding (proposalID + payloadHash +
        // snapshotRevision, or refuse), and the durable receipt lifecycle.
        // Foundation, GRDB and FLDomain/FLPersistence only.
        .target(
            name: "FLAssistantCore",
            dependencies: [
                .product(name: "FLDomain", package: "FridgeLuckCore"),
                .product(name: "FLPersistence", package: "FridgeLuckCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "FLAssistantCoreTests", dependencies: ["FLAssistantCore"]),
    ]
)
