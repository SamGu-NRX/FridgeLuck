// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FLSubstitutions",
    products: [
        .library(name: "FLSubstitutions", targets: ["FLSubstitutions"]),
    ],
    dependencies: [
        // Canonical ingredient composition (fix list §3.5): the recheck
        // evaluates against this store instead of the table's class lists.
        .package(path: "../FLIngredientFacts"),
    ],
    targets: [
        .target(
            name: "FLSubstitutions",
            dependencies: [.product(name: "FLIngredientFacts", package: "FLIngredientFacts")]
        ),
        .executableTarget(
            name: "flsub-report",
            dependencies: ["FLSubstitutions"]
        ),
        .testTarget(
            name: "FLSubstitutionsTests",
            dependencies: ["FLSubstitutions"]
        ),
    ]
)
