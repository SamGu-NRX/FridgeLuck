// swift-tools-version:6.0
import PackageDescription

// Long-lived storage performance harness for FridgeLuck's local GRDB store.
//
// Compiles the REAL production persistence sources (apps/ios/Platform/Persistence)
// against GRDB on Linux — no Xcode required. Those sources are not committed
// here; run Scripts/refresh.sh to copy them in from the repository tree first:
//
//   bash Scripts/refresh.sh
//   swift test --package-path apps/ios/Tools/storage-perf
//   swift run  --package-path apps/ios/Tools/storage-perf StoragePerf --seed 20261010 --out apps/ios/Tools/storage-perf/results
//
// This package NEVER changes production schema or indexes: index/query
// alternatives run only in disposable experiment databases.
let package = Package(
  name: "storage-perf",
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
  ],
  targets: [
    .target(
      name: "StoragePerfCore",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/StoragePerfCore"
    ),
    .executableTarget(
      name: "StoragePerf",
      dependencies: ["StoragePerfCore"],
      path: "Sources/StoragePerf"
    ),
    .testTarget(
      name: "StoragePerfTests",
      dependencies: ["StoragePerfCore"],
      path: "Tests/StoragePerfTests"
    ),
  ]
)
