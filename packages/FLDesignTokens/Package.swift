// swift-tools-version: 6.0

// FLDesignTokens — the portable, Foundation-only token package for FridgeLuck
// Direction F ("a prep list"). Builds and tests on Linux; no SwiftUI, AppKit
// or UIKit imports anywhere in this package.

import PackageDescription

let package = Package(
    name: "FLDesignTokens",
    products: [
        .library(name: "FLDesignTokens", targets: ["FLDesignTokens"])
    ],
    targets: [
        .target(name: "FLDesignTokens"),
        .testTarget(name: "FLDesignTokensTests", dependencies: ["FLDesignTokens"]),
    ]
)
