// swift-tools-version:5.10
import PackageDescription

// Offline check package for the ingredient facts flow. The logic target is a symlink to
// apps/ios/FeatureLogic/IngredientFacts, so these tests run against the exact Foundation
// source the app's FLFeatureLogic framework compiles — never a transcription.
let package = Package(
  name: "ingredient-facts-check",
  targets: [
    .target(name: "IngredientFactsLogic", path: "Sources/IngredientFactsLogic"),
    .testTarget(
      name: "IngredientFactsCheckTests",
      dependencies: ["IngredientFactsLogic"],
      path: "Tests/IngredientFactsCheckTests"
    ),
  ]
)
