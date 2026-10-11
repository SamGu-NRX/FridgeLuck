// swift-tools-version: 6.1
// FLCommunityCore — community sharing, challenges and taste-profile editing
// (SPEC §3.3, §3.4, §3.5, §6; overhaul 2026-10-11, part 5).
//
// Manifest ownership:
// - This package is owned by the community task (branch overhaul/community-core).
//   It is a separate package precisely so it never edits the FridgeLuckCore
//   manifest while Part 1 is under review.
// - It depends on FLDomain (validated value types, canonical JSON) through a
//   path dependency on the sibling FridgeLuckCore package. It never imports
//   UIKit, SwiftUI or AppKit; persistence and transport live elsewhere
//   (engineering plan, Goal 5: FLCommunityCore owns publication/license DTOs
//   and visibility policy, never server authentication decisions).
// - Linux-buildable: every check runs with `swift build` / `swift test`.

import PackageDescription

let package = Package(
    name: "FLCommunityCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FLCommunityCore", targets: ["FLCommunityCore"]),
    ],
    dependencies: [
        .package(path: "../FridgeLuckCore"),
    ],
    targets: [
        // Community logic over FLDomain contracts: recipe share payloads with
        // rights declarations, the import policy (unknown rights quarantine,
        // forbidden refuses), the redacted shared-cook payload, cooking
        // challenge state derived from Cook records, and sentence-based taste
        // profile editing recorded as profileEdit PreferenceEvents.
        .target(
            name: "FLCommunityCore",
            dependencies: [
                .product(name: "FLDomain", package: "FridgeLuckCore"),
            ]
        ),
        .testTarget(name: "FLCommunityCoreTests", dependencies: ["FLCommunityCore"]),
    ]
)
