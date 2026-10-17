// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FLIngredientFacts",
    products: [
        .library(name: "FLIngredientFacts", targets: ["FLIngredientFacts"]),
        .executable(name: "flfacts-conformance", targets: ["flfacts-conformance"]),
    ],
    targets: [
        .target(name: "FLIngredientFacts"),
        .executableTarget(
            name: "flfacts-conformance",
            dependencies: ["FLIngredientFacts"]
        ),
        .testTarget(
            name: "FLIngredientFactsTests",
            dependencies: ["FLIngredientFacts"]
        ),
    ]
)
