// swift-tools-version:5.9
// Linux e2e-walk package for the community slice. `refresh.sh` copies the real production
// sources from apps/ios into this package's executable target (stripping the app-only module
// import) and pins their SHA-256 hashes in Sources/CommunityE2EWalk/HASHES.txt; the walk
// binary verifies them at startup so a stale copy fails loudly instead of passing green.
// Run: ../../../../scripts/community-e2e/run.sh (starts the server, then this walk).
import PackageDescription

let package = Package(
  name: "community-e2e",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
  ],
  targets: [
    .executableTarget(
      name: "CommunityE2EWalk",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
      path: "Sources/CommunityE2EWalk"),
  ]
)
