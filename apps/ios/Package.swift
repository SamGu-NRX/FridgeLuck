// swift-tools-version: 6.0

// Package.swift exists only for lightweight package-based tooling and tests.
// The canonical app project is generated from project.yml into FridgeLuck.xcodeproj.

import PackageDescription

let package = Package(
  name: "FridgeLuck",
  platforms: [
    .iOS("26.0")
  ],
  products: [
    .library(
      name: "FLFeatureLogic",
      targets: ["FLFeatureLogic"]
    ),
    .library(
      name: "FLBarcode",
      targets: ["FLBarcode"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "FLFeatureLogic",
      path: "FeatureLogic",
      exclude: ["Barcode"]
    ),
    .target(
      name: "FLBarcode",
      path: "FeatureLogic/Barcode"
    ),
    .testTarget(
      name: "AppModuleTests",
      dependencies: [
        "FLFeatureLogic",
        "FLBarcode",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests"
    ),
  ]
)
