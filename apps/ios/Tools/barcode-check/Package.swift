// swift-tools-version: 6.0

// Standalone check package for the FLBarcode module: Linux-runnable tests plus the
// offline Open Food Facts evaluation runner. Path-depending on the FridgeLuck package
// keeps FLBarcode in lockstep with the app's copy; only FLBarcode is a dependency of
// these targets, so GRDB is never built here.

import PackageDescription

let package = Package(
  name: "barcode-check",
  platforms: [
    .iOS("26.0")
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .target(
      name: "BarcodeEvalSupport",
      dependencies: [
        .product(name: "FLBarcode", package: "ios")
      ],
      path: "Sources/BarcodeEvalSupport"
    ),
    .executableTarget(
      name: "barcode-eval",
      dependencies: [
        "BarcodeEvalSupport"
      ],
      path: "Sources/barcode-eval"
    ),
    .testTarget(
      name: "BarcodeCheckTests",
      dependencies: [
        .product(name: "FLBarcode", package: "ios"),
        "BarcodeEvalSupport",
      ],
      path: "Tests/BarcodeCheckTests"
    ),
  ]
)
