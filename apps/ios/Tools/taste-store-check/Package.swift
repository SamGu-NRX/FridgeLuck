// swift-tools-version: 6.0

// Portable Linux check for the taste event store, the taste profile builder/repository,
// and the profile view model. The canonical app project is generated from project.yml
// into FridgeLuck.xcodeproj and is built by iOS CI on macOS; this package exists so the
// taste persistence sources compile and their tests run in the sandbox too (see
// Scripts/refresh.sh for the source-mirror contract).
//
// The FLFeatureLogic target is an alias module carrying the mirrored FeatureLogic
// sources (the statement builder) so the mirrored repository and view model can
// `import FLFeatureLogic` exactly as they do in production.

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
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .target(
      name: "FLFeatureLogic",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      path: "Sources/FLFeatureLogic"
    ),
    .target(
      name: "TasteStoreCheck",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        "FLFeatureLogic",
      ],
      path: "Sources/TasteStoreCheck",
      swiftSettings: [
        // The sandbox's system SQLite lacks the WAL-snapshot APIs GRDB's snapshot
        // types call; GRDB guards those paths behind this flag.
        .define("SQLITE_DISABLE_SNAPSHOT")
      ]
    ),
    .testTarget(
      name: "TasteStoreCheckTests",
      dependencies: [
        "TasteStoreCheck",
        "FLFeatureLogic",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests/TasteStoreCheckTests",
      linkerSettings: [
        // The toolchain's libswiftObservation.so references its own internal fatal
        // hook that no shipped library defines; it is only reached on runtime aborts.
        .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"])
      ]
    ),
  ]
)
