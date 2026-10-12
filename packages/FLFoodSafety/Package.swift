// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FLFoodSafety",
    products: [
        .library(name: "FLFoodSafety", targets: ["FLFoodSafety"]),
        .executable(name: "flfoodsafety-audit", targets: ["flfoodsafety-audit"]),
        .executable(name: "fl-safety-lint", targets: ["fl-safety-lint"]),
    ],
    targets: [
        // Foundation-only so it builds and tests on Linux (SPEC 3.1 reviewed rulebook).
        .target(name: "FLFoodSafety", path: "Sources/FLFoodSafety"),
        // Regenerates data/food-safety/BUNDLED-RECIPE-AUDIT.md from the repo checkout.
        .executableTarget(
            name: "flfoodsafety-audit",
            dependencies: ["FLFoodSafety"],
            path: "Sources/flfoodsafety-audit"
        ),
        // fl-safety-lint — the canon conformance CLI: lints records files and
        // replays data/food-safety/conformance/ as a self-test of the canon.
        // A thin driver over the FLFoodSafety linters (no rules of its own).
        .executableTarget(
            name: "fl-safety-lint",
            dependencies: ["FLFoodSafety"],
            path: "Sources/fl-safety-lint"
        ),
        .testTarget(
            name: "FLFoodSafetyTests",
            dependencies: ["FLFoodSafety"],
            path: "Tests/FLFoodSafetyTests"
        ),
    ]
)
