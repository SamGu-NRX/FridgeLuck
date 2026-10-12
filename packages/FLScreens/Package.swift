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
        .library(name: "FLExplore", targets: ["FLExplore"]),
        .library(name: "FLRecipe", targets: ["FLRecipe"]),
        .library(name: "FLScan", targets: ["FLScan"]),
        .library(name: "FLTasteProfile", targets: ["FLTasteProfile"]),
        .library(name: "FLLeChef", targets: ["FLLeChef"]),
        .library(name: "FLProgress", targets: ["FLProgress"]),
        .library(name: "FLQuests", targets: ["FLQuests"]),
        .library(name: "FLTour", targets: ["FLTour"]),
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
        // Explore: the community feed AND the Table screen (Part 3). Table
        // is not a tab — it lives inside Explore behind its beta flag, its
        // entry row is Explore state, so both screens share one target.
        // Same split as Tonight: state/intents ungated, views gated.
        .target(
            name: "FLExplore",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Recipe: the detail document (Part 3). A shared destination pushed
        // from Tonight, Explore rows and Table cards, so it is its own
        // target rather than any one caller's submodule.
        .target(
            name: "FLRecipe",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Scan: the grocery capture-and-review flow (Part 4). A destination
        // flow — camera capture, recognition, review, commit — wired into
        // the existing shell's search-role tab slot; the camera preview and
        // recognition are host seams.
        .target(
            name: "FLScan",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Taste profile: the on-device taste editor (Part 4). A settings-style
        // ledger document reached from profile/setup contexts. Named
        // FLTasteProfile — FLTaste is the taste-learning domain package, and
        // two modules must not share a name at link time.
        .target(
            name: "FLTasteProfile",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // LeChef: the cook-mode flow (Part 5). Not a tab — a mode the host
        // presents from a recipe or Tonight's pick, so it is a destination
        // library the host wires into a presentation, never shell wiring.
        // The mid-cook and cook-complete surfaces are stages of one session
        // state machine (one proposal queue, one timer lifecycle, one
        // remember surface), so one target carries the flow; the camera
        // look pipeline, assistant link and rescale arithmetic stay host
        // seams. Same split as the other screens: state/intents ungated,
        // views gated.
        .target(
            name: "FLLeChef",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Progress: the Shell S Progress tab and the Profile destination
        // pushed from it (Part 6). One target because they share state
        // vocabulary and Profile is reached only from Progress; the
        // quests CANDIDATE's entry row renders here behind the
        // default-off flag, and the saved-food counter renders through
        // FLSavedFoodLine so it cannot drift from Quests's counter.
        .target(
            name: "FLProgress",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Quests: the weekly quests CANDIDATE (Part 6). Its own target so
        // it can be dropped (delete the target and its tests) or promoted
        // (flip the flag's default, remove the flag) with nothing else
        // entangled. Community-adjacent, privacy-safe: the share payload
        // is an explicit allowlist (SPEC §3.4).
        .target(
            name: "FLQuests",
            dependencies: [
                "FLScreenSupport",
                .product(name: "FLDesignTokens", package: "FLDesignTokens"),
                .product(name: "FLDesignSystem", package: "FLDesignSystem"),
            ]
        ),
        // Tour: the constrained onboarding tour CANDIDATE (Part 6). Its
        // own target for the same drop/promote economics as Quests; the
        // state machine owns the auto-return between steps, capped at
        // five host-supplied promises.
        .target(
            name: "FLTour",
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
        .testTarget(name: "FLExploreTests", dependencies: ["FLExplore", "FLScreenSupport"]),
        .testTarget(name: "FLRecipeTests", dependencies: ["FLRecipe", "FLScreenSupport"]),
        .testTarget(name: "FLScanTests", dependencies: ["FLScan", "FLScreenSupport"]),
        .testTarget(name: "FLTasteProfileTests", dependencies: ["FLTasteProfile", "FLScreenSupport"]),
        .testTarget(name: "FLLeChefTests", dependencies: ["FLLeChef", "FLScreenSupport"]),
        .testTarget(name: "FLProgressTests", dependencies: ["FLProgress", "FLScreenSupport"]),
        .testTarget(name: "FLQuestsTests", dependencies: ["FLQuests", "FLScreenSupport"]),
        .testTarget(name: "FLTourTests", dependencies: ["FLTour", "FLScreenSupport"]),
        // The no-hardcoded-style lint: scans this package's sources for hex
        // colour literals and font names. Needs no module dependency.
        .testTarget(name: "FLScreensLintTests", dependencies: []),
    ]
)
