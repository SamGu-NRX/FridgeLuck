// swift-tools-version: 6.2
// FLDesignSystem — FridgeLuck's SwiftUI component package.
//
// Tools 6.2 is required for `.iOS(.v26)` (PackageDescription 6.2). Supported
// everywhere this package builds: the Linux sandbox runs Swift 6.4, and
// Xcode 26 (the repo's macos-26 CI) ships Swift 6.2+.
//
// Platforms: iOS 26 + macOS 15. macOS 15 is the deployment floor this
// package needs (ImageRenderer macOS 13, .spring(duration:bounce:) macOS 14,
// DynamicTypeSize .accessibility5 macOS 12). Bump macOS to .v26 only when the
// app target standardises on it.
//
// On Linux every source file is guarded `#if canImport(UIKit) ||
// canImport(AppKit)`, so `swift build` succeeds with an intentionally empty
// module; real compilation happens on macOS/iOS in the repo's iOS CI.
import PackageDescription

let package = Package(
    name: "FLDesignSystem",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FLDesignSystem", targets: ["FLDesignSystem"])
    ],
    dependencies: [
        .package(path: "../FLDesignTokens")
    ],
    targets: [
        .target(
            name: "FLDesignSystem",
            dependencies: [
                .product(name: "FLDesignTokens", package: "FLDesignTokens")
            ]
        ),
        .testTarget(
            name: "FLDesignSystemTests",
            dependencies: [
                "FLDesignSystem",
                .product(name: "FLDesignTokens", package: "FLDesignTokens")
            ]
        ),
    ]
)
