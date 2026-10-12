// swift-tools-version: 6.2

// FLScreens — FridgeLuck's screen-family packages, Part 2: Tonight + Kitchen.
//
// Screen families are SwiftUI driven by plain view state and typed intents.
// The state models are Foundation-only and Linux-tested; the SwiftUI views
// are Apple-gated (`canImport(UIKit) || canImport(AppKit)`) so Linux compiles
// them empty. Every visual value comes from FLDesignTokens through
// FLDesignSystem — the package carries no colour, type, radius or spacing
// literal of its own (the lint test in FLScreensLintTests enforces this).
//
// Depends on the design-system packages only. Binding to FridgeLuckCore
// (GRDB, services) happens at host integration; nothing here imports it.
//
// Platforms mirror FLDesignSystem: iOS 26 + macOS 15. On Linux every
// SwiftUI file is guarded, so `swift build` succeeds with the state layer
// compiled and the view layer intentionally empty.
import PackageDescription

let package = Package(
    name: "FLScreens",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FLScreenSupport", targets: ["FLScreenSupport"]),
        .library(name: "FLTonight", targets: ["FLTonight"]),
        .library(name: "FLKitchen", targets: ["FLKitchen"]),
    ],
    dependencies: [
        .package(path: "../FLDesignTokens"),
        .package(path: "../FLDesignSystem"),
    ],
    targets: [
        // Shared screen primitives: the photo layout rule, the shell
        // configuration model, and the palette-variant mapping the render
        // matrix uses. Foundation-only plus its gated SwiftUI shell view.
        .target(
            name: "FLScreenSupport",
            dependencies: [
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Tonight: view state, typed intents and the reducer (ungated),
        // the screen's SwiftUI views (gated).
        .target(
            name: "FLTonight",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Kitchen: same split as Tonight.
        .target(
            name: "FLKitchen",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        .testTarget(
            name: "FLScreenSupportTests",
            dependencies: ["FLScreenSupport", .product(name: "FLDesignTokens", package: "FLDesignTokens")]
        ),
        .testTarget(name: "FLTonightTests", dependencies: ["FLTonight"]),
        .testTarget(name: "FLKitchenTests", dependencies: ["FLKitchen"]),
        // The no-hardcoded-style lint: scans this package's sources for hex
        // colour literals and font names. Needs no module dependency.
        .testTarget(name: "FLScreensLintTests", dependencies: []),
    ]
)
