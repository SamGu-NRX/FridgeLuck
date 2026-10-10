// swift-tools-version:6.1
import PackageDescription

// Portable Linux harness around FridgeLuck's production grocery-OCR recognition
// logic. The FridgeLuck target compiles the production sources directly (symlinked),
// so any behavior change ships through the app code, not a copy. On Apple platforms
// the shim target is replaced by the real CoreGraphics; the harness itself is built
// and run on Linux only.
let package = Package(
  name: "GroceryOCRHarness",
  dependencies: [
    // Vendored GRDB, the same checkout the iOS app links.
    .package(path: "../../../apps/ios/Vendor/GRDB.swift"),
  ],
  targets: [
    .target(name: "CoreGraphics", path: "Sources/CoreGraphicsShim"),
    .target(name: "FLFeatureLogic", path: "Sources/FLFeatureLogic"),
    .target(
      name: "FridgeLuck",
      dependencies: [
        .target(name: "CoreGraphics"),
        .target(name: "FLFeatureLogic"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/FridgeLuck"
    ),
    .executableTarget(
      name: "GroceryOCRHarness",
      dependencies: ["FridgeLuck", "CoreGraphics"],
      path: "Sources/GroceryOCRHarness",
      linkerSettings: [
        // The vendored GRDB calls the SQLite snapshot APIs; the system libsqlite3
        // lacks them, so link the custom 3.50.4 build in /usr/local/lib first.
        .unsafeFlags(["-L/usr/local/lib"]),
        .linkedLibrary("sqlite3"),
      ]
    ),
    .testTarget(
      name: "FridgeLuckTests",
      dependencies: ["FridgeLuck", "CoreGraphics", .product(name: "GRDB", package: "GRDB.swift")],
      path: "Tests/FridgeLuckTests",
      linkerSettings: [
        .unsafeFlags(["-L/usr/local/lib"]),
        .linkedLibrary("sqlite3"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
