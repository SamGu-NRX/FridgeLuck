// swift-tools-version:6.0
import PackageDescription

// Linux-safe check package for the bundled-data ownership refresh.
//
// The test target compiles the REAL production persistence sources
// (apps/ios/Platform/Persistence) and the REAL BundledDataRefreshTests.swift
// (apps/ios/Tests) against GRDB on Linux — no Xcode required. Sources are not
// committed here; run Scripts/refresh.sh to copy them in from the repository
// tree before `swift test`:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/bundled-refresh-check
let package = Package(
  name: "bundled-refresh-check",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    // The real Bundle sources import CryptoKit (Apple-only); swift-crypto
    // provides the same SHA256 on Linux, re-exported by the shim module.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
  ],
  targets: [
    // Named after the app module so the real tests' `@testable import
    // FridgeLuck` resolves to the compiled real sources.
    .target(
      name: "FridgeLuck",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .target(name: "CryptoKit"),
      ],
      path: "Sources/FridgeLuck"
    ),
    .target(
      name: "CryptoKit",
      dependencies: [.product(name: "Crypto", package: "swift-crypto")],
      path: "Sources/CryptoKit"
    ),
    .testTarget(
      name: "FridgeLuckCheckTests",
      dependencies: ["FridgeLuck"],
      path: "Tests/FridgeLuckCheckTests",
      resources: [
        .copy("Fixtures/data.json"),
        .copy("Fixtures/LegacyBundles"),
        .copy("Fixtures/usda_ingredient_catalog.sqlite"),
      ]
    ),
  ]
)
