// swift-tools-version: 6.0

// Portable Linux check for the taste event store and its meal-log transaction coupling.
// The canonical app project is generated from project.yml into FridgeLuck.xcodeproj and is
// built by iOS CI on macOS; this package exists so the taste persistence sources compile and
// their tests run in the sandbox too (see Scripts/refresh.sh for the source-mirror contract).

import PackageDescription

let package = Package(
  name: "taste-store-check",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "TasteStoreCheck",
      targets: ["TasteStoreCheck"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "TasteStoreCheck",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/TasteStoreCheck"
    ),
    .testTarget(
      name: "TasteStoreCheckTests",
      dependencies: [
        "TasteStoreCheck",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/TasteStoreCheckTests"
    ),
  ]
)
