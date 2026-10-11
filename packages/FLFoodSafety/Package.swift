// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FLFoodSafety",
    products: [
        .library(name: "FLFoodSafety", targets: ["FLFoodSafety"]),
        .executable(name: "flfoodsafety-audit", targets: ["flfoodsafety-audit"]),
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
        .testTarget(
            name: "FLFoodSafetyTests",
            dependencies: ["FLFoodSafety"],
            path: "Tests/FLFoodSafetyTests"
        ),
    ]
)
