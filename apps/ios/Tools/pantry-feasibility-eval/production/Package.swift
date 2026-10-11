// swift-tools-version:6.1
import PackageDescription

// Live production replay for the pantry-feasibility evaluation.
//
// Compiles the REAL production persistence sources (RecipeRepository and its
// service dependencies, plus the real schema migrations) against the repo's
// vendored GRDB on Linux — no Xcode required. Those sources are not committed
// here; run Scripts/refresh.sh to copy them in from the repository tree first:
//
//   bash Scripts/refresh.sh
//   swift run PantryFeasibilityProduction --corpus-dir ../runs --output ../../runs/production_replay.jsonl
//
// The replay creates one real migrated in-memory database per corpus state,
// inserts the catalog and pantry rows, and runs the actual
// RecipeRepository.findMakeable / findNearMatch — no transcription involved.
let package = Package(
    name: "PantryFeasibilityProduction",
    dependencies: [
        .package(path: "../../../Vendor/GRDB.swift")
    ],
    targets: [
        .executableTarget(
            name: "PantryFeasibilityProduction",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/PantryFeasibilityProduction"
        )
    ]
)
