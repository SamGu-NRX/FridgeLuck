// swift-tools-version: 6.0
// Suite A (pantry-truth) fit probe: compiles the production pure-logic fit
// subset (RecipeRepository + services + domain models) against GRDB on Linux.
import PackageDescription

let package = Package(
  name: "FLFitProbe",
  dependencies: [
    // Same GRDB the app uses; on this host the vendored copy is staged in.
    .package(path: "Vendor/GRDB")
  ],
  targets: [
    .target(
      name: "FLFitProduction",
      dependencies: [.product(name: "GRDB", package: "GRDB")]
    ),
    .executableTarget(
      name: "FLFitProbe",
      dependencies: ["FLFitProduction", "SnapshotStubs", .product(name: "GRDB", package: "GRDB")]
    ),
    .target(name: "SnapshotStubs"),
  ]
)
