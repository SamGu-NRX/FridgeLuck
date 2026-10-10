// swift-tools-version: 6.1

// Standalone Linux-runnable package for household-measure mass conversion.
//
// The canonical app project is generated from apps/ios/project.yml and builds
// for iOS; this package exists so the MassConversionKit API and the FNDDS
// household-measure evidence can be contract-tested on Linux (no Xcode here).
// The pinned data resource is copied from
// scripts/data/reference/household_measures/mass_conversion_table.json; a
// sync test fails if the copy drifts from the pinned file.

import PackageDescription

let package = Package(
  name: "MassConversionCheck",
  targets: [
    .target(
      name: "MassConversionKit",
      path: "Sources/MassConversionKit",
      resources: [
        .copy("Resources/mass_conversion_table.json")
      ]
    ),
    .target(
      name: "EstimatorReplay",
      path: "Sources/EstimatorReplay"
    ),
    .executableTarget(
      name: "estimator-eval",
      dependencies: ["MassConversionKit", "EstimatorReplay"],
      path: "Sources/estimator-eval"
    ),
    .testTarget(
      name: "MassConversionKitTests",
      dependencies: ["MassConversionKit", "EstimatorReplay"],
      path: "Tests/MassConversionKitTests"
    ),
  ]
)
