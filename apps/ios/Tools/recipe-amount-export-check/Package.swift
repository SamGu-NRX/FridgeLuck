// swift-tools-version: 6.0

// Offline Linux check package for the recipe amount-export logic.
// RecipeExportLogic is a committed relative symlink to ../../FeatureLogic/RecipeExport
// so the real FeatureLogic sources compile here unchanged (Foundation only, no GRDB).

import PackageDescription

let package = Package(
  name: "recipe-amount-export-check",
  targets: [
    .target(
      name: "RecipeExportLogic",
      path: "RecipeExportLogic"
    ),
    .testTarget(
      name: "RecipeExportCheckTests",
      dependencies: ["RecipeExportLogic"],
      path: "Tests/RecipeExportCheckTests"
    ),
  ]
)
