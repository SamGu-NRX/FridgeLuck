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
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "FLFeatureLogic",
      path: "FeatureLogic"
    ),
    // Foundation-only slice of the persistence layer (models, migrations, InventoryRepository)
    // so the inventory invariant tests can run under `swift test` on Linux. Sources are listed
    // explicitly because the target's path is the package root. The app's Xcode target graph
    // from project.yml is untouched and keeps compiling the full source tree; Tools/ is not
    // globbed by any Xcode target, so the shim never reaches an Apple build.
    .target(
      name: "FLInventoryCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: ".",
      sources: [
        "Domain/Models/IngredientSwap.swift",
        "Domain/Models/Inventory.swift",
        "Platform/Persistence/Database/Migrations.swift",
        "Platform/Persistence/Repository/InventoryRepository.swift",
        "Tools/InventoryCoreShim.swift",
      ]
    ),
    // Only the package-runnable tests are listed; the remaining files in Tests/ import the app
    // module and run in the Xcode FridgeLuckTests bundle that project.yml assembles.
    .testTarget(
      name: "AppModuleTests",
      dependencies: [
        "FLInventoryCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Tests",
      sources: [
        "InventoryInvariantOperationTests.swift"
      ]
    ),
  ]
)
