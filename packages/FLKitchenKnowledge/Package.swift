// swift-tools-version:6.1
import PackageDescription

// FLKitchenKnowledge — the sourced kitchen-knowledge layer for FridgeLuck's overhaul.
//
// Pure Foundation. Data lives in data/kitchen-knowledge/ (learn-cards, waste, packs)
// and every number it computes must trace to a cited source; anything that cannot
// is refused (MissingSourceError) rather than guessed.
let package = Package(
    name: "FLKitchenKnowledge",
    products: [
        .library(name: "FLKitchenKnowledge", targets: ["FLKitchenKnowledge"])
    ],
    targets: [
        .target(
            name: "FLKitchenKnowledge"
        ),
        .testTarget(
            name: "FLKitchenKnowledgeTests",
            dependencies: ["FLKitchenKnowledge"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
