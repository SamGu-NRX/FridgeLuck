// swift-tools-version:6.0
import PackageDescription

// GRDB replay of the production IngredientCatalogResolver over the pinned
// catalog. Unlike the lexicon differential probe (experiments/ingredient-
// recognition/differential/main.swift), this package really links GRDB and
// executes the resolver's SQL against the shipped
// apps/ios/Resources/usda_ingredient_catalog.sqlite — closing the "not
// executed" gap the experiment report documented.
//
// The production source is NEVER modified: Scripts/refresh.sh copies it into
// Sources/CatalogReplayCore/ProductionMirror/ and pins its sha256 in a
// generated manifest; the Python verifier re-checks the copy against the
// repository file. Build (from the repo root):
//
//   bash apps/ios/Tools/catalog-resolver-replay/Scripts/refresh.sh
//   swift test  --package-path apps/ios/Tools/catalog-resolver-replay
//   swift run   --package-path apps/ios/Tools/catalog-resolver-replay \
//     CatalogResolverReplay --db apps/ios/Resources/usda_ingredient_catalog.sqlite \
//     --probes experiments/ingredient-recognition/differential/probes.jsonl \
//     --out experiments/ingredient-recognition/differential/grdb_replay_results.jsonl \
//     --meta experiments/ingredient-recognition/differential/grdb_replay_meta.json
let package = Package(
  name: "catalog-resolver-replay",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "CatalogReplayCore",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/CatalogReplayCore"
    ),
    .executableTarget(
      name: "CatalogResolverReplay",
      dependencies: ["CatalogReplayCore"],
      path: "Sources/CatalogResolverReplay"
    ),
    .testTarget(
      name: "CatalogResolverReplayTests",
      dependencies: ["CatalogReplayCore"],
      path: "Tests/CatalogResolverReplayTests"
    ),
  ]
)
